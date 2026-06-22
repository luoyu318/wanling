package repository

import (
	"database/sql"
	"errors"
	"time"

	"github.com/wanling/server/internal/model"
)

// PairingRepo 配对票据数据访问层。仅握手用，非业务表。
type PairingRepo struct {
	db *sql.DB
}

func NewPairingRepo(db *sql.DB) *PairingRepo {
	return &PairingRepo{db: db}
}

// scanTicket 公共扫描逻辑，所有查询复用。NULL 字段用 sql.Null* 接收。
func scanTicket(s interface{ Scan(...any) error }) (*model.PairingTicket, error) {
	t := &model.PairingTicket{}
	var userID, agentID, secretKey sql.NullString
	var scannedAt, completedAt sql.NullTime
	err := s.Scan(
		&t.ID, &t.Status, &userID, &agentID, &secretKey,
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

const ticketSelectCols = `id, status, user_id, agent_id, secret_key, created_at, scanned_at, completed_at`

// Create 插入一张 pending 票据。
func (r *PairingRepo) Create(id string) (*model.PairingTicket, error) {
	row := r.db.QueryRow(
		`INSERT INTO pairing_tickets (id, status) VALUES ($1, 'pending')
		 RETURNING `+ticketSelectCols,
		id,
	)
	return scanTicket(row)
}

// GetByID 查询。不存在返回 (nil, nil)。
func (r *PairingRepo) GetByID(id string) (*model.PairingTicket, error) {
	row := r.db.QueryRow(
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
func (r *PairingRepo) MarkScanned(id, userID string) error {
	_, err := r.db.Exec(
		`UPDATE pairing_tickets SET status = 'scanned', user_id = $1, scanned_at = NOW() WHERE id = $2`,
		userID, id,
	)
	return err
}

// MarkCompleted 标记完成。写入 agent_id + secret_key + completed_at。
func (r *PairingRepo) MarkCompleted(id, agentID, secretKey string) error {
	_, err := r.db.Exec(
		`UPDATE pairing_tickets SET status = 'completed', agent_id = $1, secret_key = $2, completed_at = NOW() WHERE id = $3`,
		agentID, secretKey, id,
	)
	return err
}

// ClearSecretKey 领完即焚：清空 secret_key 字段。状态保持 completed（供审计）。
func (r *PairingRepo) ClearSecretKey(id string) error {
	_, err := r.db.Exec(
		`UPDATE pairing_tickets SET secret_key = NULL WHERE id = $1`,
		id,
	)
	return err
}

// DeleteExpired 删除超过 maxAge 的票据，返回删除行数。
// 用于后台 goroutine 定期清理，避免表无限增长。
func (r *PairingRepo) DeleteExpired(maxAge time.Duration) (int64, error) {
	cutoff := time.Now().Add(-maxAge)
	res, err := r.db.Exec(
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
func (r *PairingRepo) DBForTest() *sql.DB { return r.db }
