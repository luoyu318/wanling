package repository

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/wanling/server/internal/model"
)

// PairingRepo 配对票据数据访问层。仅握手用，非业务表。
type PairingRepo struct {
	queryExecutor
}

func NewPairingRepo(db *sql.DB) *PairingRepo {
	return &PairingRepo{queryExecutor: queryExecutor{db: db}}
}

// scanTicket 公共扫描逻辑，所有查询复用。NULL 字段用 sql.Null* 接收。
func scanTicket(s interface{ Scan(...any) error }) (*model.PairingTicket, error) {
	t := &model.PairingTicket{}
	var userID, agentID, secretKey sql.NullString
	var scannedAt, completedAt sql.NullTime
	err := s.Scan(
		&t.ID, &t.Status, &userID, &agentID, &secretKey, &t.Type, &t.Action,
		&t.CreatedAt, &scannedAt, &completedAt,
	)
	if err != nil {
		return nil, err
	}
	if userID.Valid {
		t.UserID = &userID.String
	}
	if agentID.Valid {
		t.AgentID = &agentID.String
	}
	if secretKey.Valid {
		t.SecretKey = &secretKey.String
	}
	if scannedAt.Valid {
		t.ScannedAt = &scannedAt.Time
	}
	if completedAt.Valid {
		t.CompletedAt = &completedAt.Time
	}
	return t, nil
}

const ticketSelectCols = `id, status, user_id, agent_id, secret_key, type, action, created_at, scanned_at, completed_at`

// Create 插入一张 pending 票据。agentType 是 hermes 声明的 agent 类型标签
// (默认空串=普通 agent,opencode=OpenCode agent),CompleteTicket 读它建 agent。
func (r *PairingRepo) Create(ctx context.Context, id, agentType string) (*model.PairingTicket, error) {
	row := r.queryRow(ctx,
		`INSERT INTO pairing_tickets (id, status, type) VALUES ($1, 'pending', $2)
		 RETURNING `+ticketSelectCols,
		id, agentType,
	)
	return scanTicket(row)
}

// GetByID 查询。不存在返回 (nil, nil)。
func (r *PairingRepo) GetByID(ctx context.Context, id string) (*model.PairingTicket, error) {
	row := r.queryRow(ctx,
		`SELECT `+ticketSelectCols+` FROM pairing_tickets WHERE id = $1`,
		id,
	)
	t, err := scanTicket(row)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return t, nil
}

// MarkScanned 标记已扫码。同时写入 user_id + scanned_at。
func (r *PairingRepo) MarkScanned(ctx context.Context, id, userID string) error {
	_, err := r.exec(ctx,
		`UPDATE pairing_tickets SET status = 'scanned', user_id = $1, scanned_at = NOW() WHERE id = $2`,
		userID, id,
	)
	return err
}

// MarkCompleted 标记完成。写入 agent_id + secret_key + action + completed_at。
// action 是完成动作：bind=接管(重置主密钥) / authorize=授权(发子密钥)。
func (r *PairingRepo) MarkCompleted(ctx context.Context, id, agentID, secretKey, action string) error {
	_, err := r.exec(ctx,
		`UPDATE pairing_tickets SET status = 'completed', agent_id = $1, secret_key = $2, action = $3, completed_at = NOW() WHERE id = $4`,
		agentID, secretKey, action, id,
	)
	return err
}

// ClearSecretKey 领完即焚：清空 secret_key 字段。状态保持 completed（供审计）。
func (r *PairingRepo) ClearSecretKey(ctx context.Context, id string) error {
	_, err := r.exec(ctx,
		`UPDATE pairing_tickets SET secret_key = NULL WHERE id = $1`,
		id,
	)
	return err
}

// ConsumeSecretKey 原子消费 secret_key：事务内 SELECT FOR UPDATE + UPDATE SET NULL。
// 用行锁保证读+清原子，消除"读→返回→清空"三步竞态窗口
// （消费者崩溃或响应丢失不会再导致券永久不可用或凭据泄露）。
// 消费成功返回凭据；已消费（secret_key 已 NULL）或 ticket 不存在返回空值。
func (r *PairingRepo) ConsumeSecretKey(ctx context.Context, id string) (secretKey, agentID, userID string, err error) {
	tx, err := r.beginTx(ctx)
	if err != nil {
		return "", "", "", err
	}
	// defer Rollback: Commit 成功后为 noop（sql.ErrTCDone），出错 return 时保证回滚
	defer tx.Rollback()

	var sk, aid, uid sql.NullString
	err = tx.QueryRowContext(ctx,
		`SELECT secret_key, agent_id, user_id FROM pairing_tickets
		 WHERE id = $1 AND secret_key IS NOT NULL FOR UPDATE`,
		id,
	).Scan(&sk, &aid, &uid)
	if errors.Is(err, sql.ErrNoRows) {
		return "", "", "", nil
	}
	if err != nil {
		return "", "", "", err
	}

	if _, err = tx.ExecContext(ctx,
		`UPDATE pairing_tickets SET secret_key = NULL WHERE id = $1`,
		id,
	); err != nil {
		return "", "", "", err
	}

	if err := tx.Commit(); err != nil {
		return "", "", "", err
	}

	if sk.Valid {
		secretKey = sk.String
	}
	if aid.Valid {
		agentID = aid.String
	}
	if uid.Valid {
		userID = uid.String
	}
	return
}

// DeleteExpired 删除超过 maxAge 的票据，返回删除行数。
// 用于后台 goroutine 定期清理，避免表无限增长。
func (r *PairingRepo) DeleteExpired(ctx context.Context, maxAge time.Duration) (int64, error) {
	cutoff := time.Now().Add(-maxAge)
	res, err := r.exec(ctx,
		`DELETE FROM pairing_tickets WHERE created_at < $1`,
		cutoff,
	)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// DBForTest 暴露内部 *sql.DB，仅测试用（handler 测试需要直接插入老记录构造过期场景）。
// 生产代码不应调用。
func (r *PairingRepo) DBForTest() *sql.DB { return r.queryExecutor.db }
