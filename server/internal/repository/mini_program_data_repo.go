// 从 templates/go-repo.go.tmpl 复制骨架改写:
// queryExecutor 封装(H4)/ rows.Err(M14)/ LIMIT 兜底(L12)/ 事务 ctx 显式消费。
package repository

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/wanling/server/internal/model"
)

// 哨兵错误,handler errors.Is 映射 409/413
var (
	ErrVersionConflict = errors.New("version conflict")
	ErrQuotaExceeded   = errors.New("quota exceeded")
)

// MiniProgramDataRepo 小程序云数据 KV 数据访问层:
// appid 双层配额(总帽 + 单用户子帽) + version 乐观锁。
type MiniProgramDataRepo struct {
	queryExecutor
}

func NewMiniProgramDataRepo(db *sql.DB) *MiniProgramDataRepo {
	return &MiniProgramDataRepo{queryExecutor: queryExecutor{db: db}}
}

// QuotaLimits 写入校验用的配额约束(handler 层组装,repo 只判不猜默认值)。
type QuotaLimits struct {
	AppBytes      int64
	AppEntries    int64
	MyBytes       int64
	MyEntries     int64
	MaxValueBytes int64
}

// QuotaStats Stats 视图:appid 总量 + 指定用户子量。
type QuotaStats struct {
	AppBytes   int64
	MyBytes    int64
	AppEntries int64
	MyEntries  int64
}

const mpDataColumns = `id, appid, owner_id, coll, key, value, size_bytes, version, created_at, updated_at`

// scanMiniProgramData 接 Row/Rows 通用的 Scan 方法值,统一行扫描。
func scanMiniProgramData(scan func(dest ...any) error) (*model.MiniProgramData, error) {
	var e model.MiniProgramData
	if err := scan(&e.ID, &e.Appid, &e.OwnerID, &e.Coll, &e.Key, &e.Value,
		&e.SizeBytes, &e.Version, &e.CreatedAt, &e.UpdatedAt); err != nil {
		return nil, err
	}
	return &e, nil
}

// UpsertEntry 写入(upsert)。expectedVersion nil=无条件写(last-write-wins);
// 非 nil 时与现值不等 → ErrVersionConflict。配额超 → ErrQuotaExceeded。
// 返回落库后的行(含新 version)。
//
// 全程单事务:FOR UPDATE 锁当前行 → version CAS 校验 → 单值上限 → 两级 SUM
// 配额(替换语义计增量 = newSize-oldSize) → ON CONFLICT DO UPDATE version+1。
// 配额校验在事务内,与行锁共同防并发超卖。
func (r *MiniProgramDataRepo) UpsertEntry(ctx context.Context, appid, ownerID, coll, key string, value []byte, expectedVersion *int64, q QuotaLimits) (*model.MiniProgramData, error) {
	tx, err := r.beginTx(ctx)
	if err != nil {
		return nil, fmt.Errorf("mp_data begin: %w", err)
	}
	// defer Rollback: Commit 成功后为 noop,出错 return 时保证回滚
	defer tx.Rollback()

	newSize := int64(len(value))

	// 锁当前行(存在时),后续 CAS 校验与增量计算基于锁内快照
	const lockQ = `SELECT version, size_bytes FROM mini_program_data
		WHERE appid=$1 AND owner_id=$2 AND coll=$3 AND key=$4 FOR UPDATE`
	var curVersion, oldSize int64
	exists := true
	switch err := tx.QueryRowContext(ctx, lockQ, appid, ownerID, coll, key).Scan(&curVersion, &oldSize); {
	case errors.Is(err, sql.ErrNoRows):
		exists = false
		// 调用方带 expectedVersion 说明预期行已存在,行缺失即冲突
		if expectedVersion != nil {
			return nil, fmt.Errorf("%w: entry missing, expected version %d", ErrVersionConflict, *expectedVersion)
		}
	case err != nil:
		return nil, fmt.Errorf("mp_data lock: %w", err)
	default:
		if expectedVersion != nil && *expectedVersion != curVersion {
			return nil, fmt.Errorf("%w: expected %d, current %d", ErrVersionConflict, *expectedVersion, curVersion)
		}
	}

	// 单值上限
	if newSize > q.MaxValueBytes {
		return nil, fmt.Errorf("%w: value too large (%d > %d)", ErrQuotaExceeded, newSize, q.MaxValueBytes)
	}

	// 两级配额:一条 SUM 同时取 appid 总量与当前用户子量
	const quotaQ = `SELECT
		COALESCE(SUM(size_bytes), 0), COUNT(*),
		COALESCE(SUM(size_bytes) FILTER (WHERE owner_id = $2), 0),
		COUNT(*) FILTER (WHERE owner_id = $2)
		FROM mini_program_data WHERE appid = $1`
	var appBytes, appEntries, myBytes, myEntries int64
	if err := tx.QueryRowContext(ctx, quotaQ, appid, ownerID).
		Scan(&appBytes, &appEntries, &myBytes, &myEntries); err != nil {
		return nil, fmt.Errorf("mp_data quota sum: %w", err)
	}
	if exists {
		// 替换:SUM 已含旧值,按增量校验;条目数不变无需校验 entries
		if appBytes-oldSize+newSize > q.AppBytes || myBytes-oldSize+newSize > q.MyBytes {
			return nil, fmt.Errorf("%w: bytes quota (app %d-%d+%d, my %d-%d+%d)",
				ErrQuotaExceeded, appBytes, oldSize, newSize, myBytes, oldSize, newSize)
		}
	} else {
		if appBytes+newSize > q.AppBytes || appEntries+1 > q.AppEntries ||
			myBytes+newSize > q.MyBytes || myEntries+1 > q.MyEntries {
			return nil, fmt.Errorf("%w: quota (app %dB/%d entries, my %dB/%d entries)",
				ErrQuotaExceeded, appBytes, appEntries, myBytes, myEntries)
		}
	}

	const upQ = `INSERT INTO mini_program_data (appid, owner_id, coll, key, value, size_bytes)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (appid, owner_id, coll, key) DO UPDATE SET
			value = EXCLUDED.value,
			size_bytes = EXCLUDED.size_bytes,
			version = mini_program_data.version + 1,
			updated_at = now()
		RETURNING ` + mpDataColumns
	e, err := scanMiniProgramData(tx.QueryRowContext(ctx, upQ, appid, ownerID, coll, key, value, newSize).Scan)
	if err != nil {
		return nil, fmt.Errorf("mp_data upsert: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("mp_data commit: %w", err)
	}
	return e, nil
}

// GetEntry 单键读取;未找到返 nil,nil。
func (r *MiniProgramDataRepo) GetEntry(ctx context.Context, appid, ownerID, coll, key string) (*model.MiniProgramData, error) {
	const q = `SELECT ` + mpDataColumns + ` FROM mini_program_data
		WHERE appid=$1 AND owner_id=$2 AND coll=$3 AND key=$4`
	e, err := scanMiniProgramData(r.queryRow(ctx, q, appid, ownerID, coll, key).Scan)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("mp_data get: %w", err)
	}
	return e, nil
}

// DeleteEntry 删除单键,返回被删行;未找到 nil,nil;expectedVersion 非 nil 且
// 与现值不符 → ErrVersionConflict。先读后原子删:DELETE WHERE version 兜住
// 读取与删除之间的并发变更(0 行 → 冲突而非误删)。
func (r *MiniProgramDataRepo) DeleteEntry(ctx context.Context, appid, ownerID, coll, key string, expectedVersion *int64) (*model.MiniProgramData, error) {
	cur, err := r.GetEntry(ctx, appid, ownerID, coll, key)
	if err != nil || cur == nil {
		return nil, err
	}
	if expectedVersion != nil && *expectedVersion != cur.Version {
		return nil, fmt.Errorf("%w: delete expected %d, current %d", ErrVersionConflict, *expectedVersion, cur.Version)
	}
	const q = `DELETE FROM mini_program_data
		WHERE appid=$1 AND owner_id=$2 AND coll=$3 AND key=$4 AND version=$5
		RETURNING ` + mpDataColumns
	e, err := scanMiniProgramData(r.queryRow(ctx, q, appid, ownerID, coll, key, cur.Version).Scan)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, fmt.Errorf("%w: concurrent modification", ErrVersionConflict)
	}
	if err != nil {
		return nil, fmt.Errorf("mp_data delete: %w", err)
	}
	return e, nil
}

// ListEntries key 升序分页列表。prefix 非空按前缀过滤;cursor 非空取 key > cursor
// (升序偏移,不加密);多取一条探测 nextCursor,末页返回空串。
func (r *MiniProgramDataRepo) ListEntries(ctx context.Context, appid, ownerID, coll, prefix string, cursor string, limit int) ([]*model.MiniProgramData, string, error) {
	if limit <= 0 || limit > 1000 {
		limit = 100 // LIMIT 兜底(审计 L12)
	}
	q := `SELECT ` + mpDataColumns + ` FROM mini_program_data
		WHERE appid=$1 AND owner_id=$2 AND coll=$3`
	args := []any{appid, ownerID, coll}
	if prefix != "" {
		args = append(args, prefix+"%")
		q += fmt.Sprintf(" AND key LIKE $%d", len(args))
	}
	if cursor != "" {
		args = append(args, cursor)
		q += fmt.Sprintf(" AND key > $%d", len(args))
	}
	args = append(args, limit+1)
	q += fmt.Sprintf(" ORDER BY key LIMIT $%d", len(args))

	rows, err := r.query(ctx, q, args...)
	if err != nil {
		return nil, "", fmt.Errorf("mp_data list: %w", err)
	}
	defer rows.Close()

	result := []*model.MiniProgramData{}
	for rows.Next() {
		e, err := scanMiniProgramData(rows.Scan)
		if err != nil {
			return nil, "", fmt.Errorf("mp_data scan: %w", err)
		}
		result = append(result, e)
	}
	if err := rows.Err(); err != nil {
		return nil, "", fmt.Errorf("mp_data rows: %w", err)
	}

	next := ""
	if len(result) > limit {
		next = result[limit-1].Key
		result = result[:limit]
	}
	return result, next, nil
}

// Stats 双层用量聚合:appid 总量(AppBytes/AppEntries) + 指定用户子量(MyBytes/MyEntries)。
func (r *MiniProgramDataRepo) Stats(ctx context.Context, appid string, userID string) (QuotaStats, error) {
	const q = `SELECT
		COALESCE(SUM(size_bytes), 0), COUNT(*),
		COALESCE(SUM(size_bytes) FILTER (WHERE owner_id = $2), 0),
		COUNT(*) FILTER (WHERE owner_id = $2)
		FROM mini_program_data WHERE appid = $1`
	var s QuotaStats
	if err := r.queryRow(ctx, q, appid, userID).
		Scan(&s.AppBytes, &s.AppEntries, &s.MyBytes, &s.MyEntries); err != nil {
		return QuotaStats{}, fmt.Errorf("mp_data stats: %w", err)
	}
	return s, nil
}

// DeleteAllForApp 清空 appid 全部云数据(admin 下架清理/删除小程序级联),返回删除行数。
func (r *MiniProgramDataRepo) DeleteAllForApp(ctx context.Context, appid string) (int64, error) {
	const q = `DELETE FROM mini_program_data WHERE appid=$1`
	res, err := r.exec(ctx, q, appid)
	if err != nil {
		return 0, fmt.Errorf("mp_data delete_all: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("mp_data delete_all rows: %w", err)
	}
	return n, nil
}
