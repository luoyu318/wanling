package repository

import (
	"database/sql"
	"encoding/json"
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

// DecisionContext service 决策所需的上下文（一次 JOIN 查询拿全）。
type DecisionContext struct {
	ApprovalID   string
	MessageID    string
	ConversationID string
	AgentID      string
	UserID       string
	SessionKey   string
	AllowPattern *string
	CardContent  model.CardContent
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

// Create 插入一条 pending 审批。id 由调用方预生成（必须与 message content 里
// 的 CardContent.ApprovalID 一致，否则 APP 点按钮时按 content 的 id 来决策会
// 找不到记录）。返回完整记录。
func (r *ApprovalRepo) Create(a model.Approval) (*model.Approval, error) {
	actionsRaw, err := model.MarshalActions(a.Actions)
	if err != nil {
		return nil, err
	}
	row := r.db.QueryRow(
		`INSERT INTO approvals
		 (id, message_id, conversation_id, agent_id, user_id, card_type, state, actions,
		  expires_at, session_key, allow_pattern)
		 VALUES ($1, $2, $3, $4, $5, $6, 'pending', $7, $8, $9, $10)
		 RETURNING `+approvalSelectCols,
		a.ID, a.MessageID, a.ConversationID, a.AgentID, a.UserID, a.CardType, actionsRaw,
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

// ErrApprovalNotPending 试图对非 pending 状态推进。
var ErrApprovalNotPending = errors.New("approval not pending")

// MarkDecided 推进到 approved/denied 终态。actionID 必须是 actions 列表内的合法 id（由调用方校验）。
// reason 仅 deny 时有意义。allowPattern 非 nil 时同时写入 allow_pattern（用于「始终」白名单）。
// 已是终态时返回 ErrApprovalNotPending（用 WHERE state='pending' 做乐观锁）。
func (r *ApprovalRepo) MarkDecided(id, actionID, userID, reason string, allowPattern *string) error {
	state := model.ApprovalStateApproved
	if actionID == "deny" {
		state = model.ApprovalStateDenied
	}
	res, err := r.db.Exec(
		`UPDATE approvals
		 SET state = $1, decided_action = $2, decided_by = $3,
		     decided_reason = NULLIF($4, ''), decided_at = now(),
		     allow_pattern = COALESCE($5, allow_pattern)
		 WHERE id = $6 AND state = 'pending'`,
		state, actionID, userID, reason, nullableString(allowPattern), id,
	)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrApprovalNotPending
	}
	return nil
}

// MarkExpired 推进到 expired 终态。
func (r *ApprovalRepo) MarkExpired(id string) error {
	res, err := r.db.Exec(
		`UPDATE approvals SET state = 'expired'
		 WHERE id = $1 AND state = 'pending'`,
		id,
	)
	if err != nil {
		return err
	}
	n, _ := res.RowsAffected()
	if n == 0 {
		return ErrApprovalNotPending
	}
	return nil
}

// MatchAllowPattern 查会话+agent 是否有已 approved 且 allow_pattern 匹配 command 的记录。
// 匹配规则：allow_pattern 中 * → %, ? → _，大小写敏感（与 Linux shell 行为一致）。
func (r *ApprovalRepo) MatchAllowPattern(convID, agentID, command string) (bool, error) {
	var matched bool
	err := r.db.QueryRow(
		`SELECT EXISTS(
		   SELECT 1 FROM approvals
		   WHERE conversation_id = $1
		     AND agent_id = $2
		     AND state = 'approved'
		     AND allow_pattern IS NOT NULL
		     AND $3 LIKE replace(replace(allow_pattern, '*', '%'), '?', '_')
		   LIMIT 1
		)`,
		convID, agentID, command,
	).Scan(&matched)
	if err != nil {
		return false, err
	}
	return matched, nil
}

// GetForDecision 一次 JOIN messages 查询决策所需的所有字段。
// 不存在返回 (nil, nil)，由调用方判断。
func (r *ApprovalRepo) GetForDecision(id string) (*DecisionContext, error) {
	row := r.db.QueryRow(
		`SELECT a.id, a.message_id, a.conversation_id, a.agent_id, a.user_id,
		        a.session_key, a.allow_pattern, a.actions, m.content
		 FROM approvals a JOIN messages m ON m.id = a.message_id
		 WHERE a.id = $1`,
		id,
	)
	var (
		ctx        DecisionContext
		actionsRaw []byte
		contentRaw []byte
		allowPat   sql.NullString
	)
	err := row.Scan(
		&ctx.ApprovalID, &ctx.MessageID, &ctx.ConversationID, &ctx.AgentID, &ctx.UserID,
		&ctx.SessionKey, &allowPat, &actionsRaw, &contentRaw,
	)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	if allowPat.Valid {
		ctx.AllowPattern = &allowPat.String
	}
	var wrapper struct {
		Data model.CardContent `json:"data"`
	}
	if err := json.Unmarshal(contentRaw, &wrapper); err != nil {
		return nil, err
	}
	ctx.CardContent = wrapper.Data
	// actions 单独存表，覆盖 content 里可能不一致的副本（以表为准）
	ctx.CardContent.Actions, _ = model.UnmarshalActions(actionsRaw)
	return &ctx, nil
}

// UpdateMessageContent 更新 messages.content（service 双写 state 用）。
func (r *ApprovalRepo) UpdateMessageContent(messageID string, content []byte) error {
	_, err := r.db.Exec(`UPDATE messages SET content = $1 WHERE id = $2`, content, messageID)
	return err
}
