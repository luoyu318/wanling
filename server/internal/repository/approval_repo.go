package repository

import (
	"database/sql"
	"errors"
	"time"

	"github.com/wanling/server/internal/model"
)

// ApprovalRepo 审批数据访问层。
type ApprovalRepo struct {
	db *sql.DB
}

func NewApprovalRepo(db *sql.DB) *ApprovalRepo {
	return &ApprovalRepo{db: db}
}

const approvalSelectCols = `id, message_id, conversation_id, agent_id, user_id,
	card_type, state, actions, decided_action, decided_by, decided_reason, decided_at,
	expires_at, session_key, allow_pattern, created_at`

func scanApproval(s interface{ Scan(...any) error }) (*model.Approval, error) {
	a := &model.Approval{}
	var (
		actionsRaw    []byte
		decidedAction sql.NullString
		decidedBy     sql.NullString
		decidedReason sql.NullString
		decidedAt     sql.NullTime
		allowPattern  sql.NullString
	)
	err := s.Scan(
		&a.ID, &a.MessageID, &a.ConversationID, &a.AgentID, &a.UserID,
		&a.CardType, &a.State, &actionsRaw, &decidedAction, &decidedBy, &decidedReason, &decidedAt,
		&a.ExpiresAt, &a.SessionKey, &allowPattern, &a.CreatedAt,
	)
	if err != nil {
		return nil, err
	}
	a.Actions, err = model.UnmarshalActions(actionsRaw)
	if err != nil {
		return nil, err
	}
	if decidedAction.Valid {
		a.DecidedAction = &decidedAction.String
	}
	if decidedBy.Valid {
		a.DecidedBy = &decidedBy.String
	}
	if decidedReason.Valid {
		a.DecidedReason = &decidedReason.String
	}
	if decidedAt.Valid {
		a.DecidedAt = &decidedAt.Time
	}
	if allowPattern.Valid {
		a.AllowPattern = &allowPattern.String
	}
	return a, nil
}

// nullableString *string → any（NULL 或字符串），供 SQL 参数用。
func nullableString(p *string) any {
	if p == nil {
		return nil
	}
	return *p
}

// Create 插入一条 pending 审批。返回完整记录（含生成的 id 和默认 state）。
func (r *ApprovalRepo) Create(a model.Approval) (*model.Approval, error) {
	actionsRaw, err := model.MarshalActions(a.Actions)
	if err != nil {
		return nil, err
	}
	row := r.db.QueryRow(
		`INSERT INTO approvals
		 (message_id, conversation_id, agent_id, user_id, card_type, state, actions,
		  expires_at, session_key, allow_pattern)
		 VALUES ($1, $2, $3, $4, $5, 'pending', $6, $7, $8, $9)
		 RETURNING `+approvalSelectCols,
		a.MessageID, a.ConversationID, a.AgentID, a.UserID, a.CardType, actionsRaw,
		a.ExpiresAt, a.SessionKey, nullableString(a.AllowPattern),
	)
	return scanApproval(row)
}

// GetByID 查单条。不存在返回 (nil, nil)。
func (r *ApprovalRepo) GetByID(id string) (*model.Approval, error) {
	row := r.db.QueryRow(`SELECT `+approvalSelectCols+` FROM approvals WHERE id = $1`, id)
	a, err := scanApproval(row)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return a, nil
}

// GetByMessageID 通过关联消息查。不存在返回 (nil, nil)。
func (r *ApprovalRepo) GetByMessageID(msgID string) (*model.Approval, error) {
	row := r.db.QueryRow(`SELECT `+approvalSelectCols+` FROM approvals WHERE message_id = $1`, msgID)
	a, err := scanApproval(row)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	return a, nil
}

// FindExpired 查所有 pending 且 expires_at < now 的记录，供 cleanup goroutine 用。
func (r *ApprovalRepo) FindExpired(now time.Time) ([]*model.Approval, error) {
	rows, err := r.db.Query(
		`SELECT `+approvalSelectCols+` FROM approvals
		 WHERE state = 'pending' AND expires_at < $1`,
		now,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []*model.Approval
	for rows.Next() {
		a, err := scanApproval(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, rows.Err()
}
