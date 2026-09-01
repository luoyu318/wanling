package repository

import (
	"context"
	"database/sql"
	"fmt"

	"github.com/wanling/server/internal/model"
)

// MiniProgramRepo 小程序注册表数据访问层(两层模型:private/published/disabled)。
type MiniProgramRepo struct {
	queryExecutor
}

func NewMiniProgramRepo(db *sql.DB) *MiniProgramRepo {
	return &MiniProgramRepo{queryExecutor: queryExecutor{db: db}}
}

const mpColumns = `id, appid, owner_id, name, version, manifest, package_file_id, sha256, size, status, signature`

func scanMiniProgram(row *sql.Row) (*model.MiniProgram, error) {
	var e model.MiniProgram
	// signature NULL=未签,经 NullString 中转为空串
	var sig sql.NullString
	if err := row.Scan(&e.ID, &e.Appid, &e.OwnerID, &e.Name, &e.Version,
		&e.ManifestJSON, &e.PackageFileID, &e.SHA256, &e.Size, &e.Status, &sig); err != nil {
		return nil, err
	}
	e.Signature = sig.String
	return &e, nil
}

// Create 新建私有小程序记录(appid 冲突由 handler 先查 GetByAppid 决定走向)。
func (r *MiniProgramRepo) Create(ctx context.Context, mp *model.MiniProgram) error {
	const q = `INSERT INTO mini_programs
		(id, appid, owner_id, name, version, manifest, package_file_id, sha256, size, status)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,'private')`
	if _, err := r.exec(ctx, q, mp.ID, mp.Appid, mp.OwnerID, mp.Name, mp.Version,
		mp.ManifestJSON, mp.PackageFileID, mp.SHA256, mp.Size); err != nil {
		return fmt.Errorf("mini_program create: %w", err)
	}
	return nil
}

// GetByID 按 ID 查;未找到返 nil,nil。
func (r *MiniProgramRepo) GetByID(ctx context.Context, id string) (*model.MiniProgram, error) {
	const q = `SELECT ` + mpColumns + ` FROM mini_programs WHERE id = $1`
	e, err := scanMiniProgram(r.queryRow(ctx, q, id))
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("mini_program get: %w", err)
	}
	return e, nil
}

// GetByAppid 按 appid 查;未找到返 nil,nil。上传时判定新建/换版本/拒绝。
func (r *MiniProgramRepo) GetByAppid(ctx context.Context, appid string) (*model.MiniProgram, error) {
	const q = `SELECT ` + mpColumns + ` FROM mini_programs WHERE appid = $1`
	e, err := scanMiniProgram(r.queryRow(ctx, q, appid))
	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("mini_program get_by_appid: %w", err)
	}
	return e, nil
}

// ListVisibleTo 用户可见集:published 全量 + 自己的(含 disabled)。
func (r *MiniProgramRepo) ListVisibleTo(ctx context.Context, userID string) ([]*model.MiniProgram, error) {
	const q = `SELECT ` + mpColumns + ` FROM mini_programs
		WHERE status = 'published' OR owner_id = $1
		ORDER BY updated_at DESC LIMIT 256`
	rows, err := r.query(ctx, q, userID)
	if err != nil {
		return nil, fmt.Errorf("mini_program list: %w", err)
	}
	defer rows.Close()
	result := []*model.MiniProgram{}
	for rows.Next() {
		var e model.MiniProgram
		var sig sql.NullString
		if err := rows.Scan(&e.ID, &e.Appid, &e.OwnerID, &e.Name, &e.Version,
			&e.ManifestJSON, &e.PackageFileID, &e.SHA256, &e.Size, &e.Status, &sig); err != nil {
			return nil, fmt.Errorf("mini_program scan: %w", err)
		}
		e.Signature = sig.String
		result = append(result, &e)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("mini_program rows: %w", err)
	}
	return result, nil
}

// ReplaceVersionParams 同 appid 换版本的更新集。
type ReplaceVersionParams struct {
	Name          string
	Version       int
	ManifestJSON  []byte
	PackageFileID string
	SHA256        string
	Size          int64
}

// ReplaceVersion 同 owner 重传:覆盖版本信息并重置回 private(重新走 publish)。
// 包字节已变,旧签名作废,清空 signature 待重新签。
func (r *MiniProgramRepo) ReplaceVersion(ctx context.Context, id string, p ReplaceVersionParams) error {
	const q = `UPDATE mini_programs SET name=$2, version=$3, manifest=$4,
		package_file_id=$5, sha256=$6, size=$7, status='private', signature=NULL, updated_at=now()
		WHERE id=$1`
	if _, err := r.exec(ctx, q, id, p.Name, p.Version, p.ManifestJSON,
		p.PackageFileID, p.SHA256, p.Size); err != nil {
		return fmt.Errorf("mini_program replace: %w", err)
	}
	return nil
}

// UpdateStatus 状态流转(private→published⇄disabled),流转合法性由 handler 校验。
func (r *MiniProgramRepo) UpdateStatus(ctx context.Context, id, status string) error {
	const q = `UPDATE mini_programs SET status=$2, updated_at=now() WHERE id=$1`
	if _, err := r.exec(ctx, q, id, status); err != nil {
		return fmt.Errorf("mini_program status: %w", err)
	}
	return nil
}

// UpdateSignature 写入包签名 hex(M3 publish 流程调用)。
// Create INSERT 不含该列;ReplaceVersion 置 NULL 作废旧签。
func (r *MiniProgramRepo) UpdateSignature(ctx context.Context, id, sigHex string) error {
	const q = `UPDATE mini_programs SET signature=$2, updated_at=now() WHERE id=$1`
	if _, err := r.exec(ctx, q, id, sigHex); err != nil {
		return fmt.Errorf("mini_program update_signature: %w", err)
	}
	return nil
}

// ListPublishedMissingSignature 列出待签名的 published 包(signature IS NULL),
// 供发布流程/存量补签遍历。
func (r *MiniProgramRepo) ListPublishedMissingSignature(ctx context.Context) ([]*model.MiniProgram, error) {
	const q = `SELECT ` + mpColumns + ` FROM mini_programs
		WHERE status = 'published' AND signature IS NULL
		ORDER BY updated_at DESC LIMIT 256`
	rows, err := r.query(ctx, q)
	if err != nil {
		return nil, fmt.Errorf("mini_program list_missing_signature: %w", err)
	}
	defer rows.Close()
	result := []*model.MiniProgram{}
	for rows.Next() {
		var e model.MiniProgram
		var sig sql.NullString
		if err := rows.Scan(&e.ID, &e.Appid, &e.OwnerID, &e.Name, &e.Version,
			&e.ManifestJSON, &e.PackageFileID, &e.SHA256, &e.Size, &e.Status, &sig); err != nil {
			return nil, fmt.Errorf("mini_program scan: %w", err)
		}
		e.Signature = sig.String
		result = append(result, &e)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("mini_program rows: %w", err)
	}
	return result, nil
}

// DeletePrivate 仅删 owner 自己的 private 记录,返回删除行数(0=条件不满足)。
func (r *MiniProgramRepo) DeletePrivate(ctx context.Context, id, ownerID string) (int64, error) {
	const q = `DELETE FROM mini_programs WHERE id=$1 AND owner_id=$2 AND status='private'`
	res, err := r.exec(ctx, q, id, ownerID)
	if err != nil {
		return 0, fmt.Errorf("mini_program delete: %w", err)
	}
	n, err := res.RowsAffected()
	if err != nil {
		return 0, fmt.Errorf("mini_program delete rows: %w", err)
	}
	return n, nil
}
