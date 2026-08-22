package repository

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/wanling/server/internal/model"
)

// ApprovalRepo 审批数据访问层。
type ApprovalRepo struct {
	queryExecutor
}

func NewApprovalRepo(db *sql.DB) *ApprovalRepo {
	return &ApprovalRepo{queryExecutor: queryExecutor{db: db}}
}

// DecisionContext service 决策所需的上下文（一次 JOIN 查询拿全）。
type DecisionContext struct {
	ApprovalID     string
	MessageID      string
	ConversationID string
	InitiatorType  string
	InitiatorID    string
	SessionKey     string
	ConfirmID      string // slash_confirm 用（空表示 exec_approval）
	AllowPattern   *string
	CardContent    model.CardContent
}

const approvalSelectCols = `id, message_id, conversation_id, initiator_type, initiator_id,
	decider_type, decider_id,
	card_type, state, actions, decided_action, decided_by, decided_reason, decided_at,
	expires_at, session_key, allow_pattern, confirm_id, created_at`

func scanApproval(s interface{ Scan(...any) error }) (*model.Approval, error) {
	a := &model.Approval{}
	var (
		actionsRaw    []byte
		deciderType   sql.NullString
		deciderID     sql.NullString
		decidedAction sql.NullString
		decidedBy     sql.NullString
		decidedReason sql.NullString
		decidedAt     sql.NullTime
		allowPattern  sql.NullString
		confirmID     sql.NullString
	)
	err := s.Scan(
		&a.ID, &a.MessageID, &a.ConversationID, &a.InitiatorType, &a.InitiatorID,
		&deciderType, &deciderID,
		&a.CardType, &a.State, &actionsRaw, &decidedAction, &decidedBy, &decidedReason, &decidedAt,
		&a.ExpiresAt, &a.SessionKey, &allowPattern, &confirmID, &a.CreatedAt,
	)
	if err != nil {
		return nil, err
	}
	a.Actions, err = model.UnmarshalActions(actionsRaw)
	if err != nil {
		return nil, err
	}
	if deciderType.Valid {
		a.DeciderType = &deciderType.String
	}
	if deciderID.Valid {
		a.DeciderID = &deciderID.String
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
	if confirmID.Valid {
		a.ConfirmID = &confirmID.String
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

// Create 插入一条 pending 审批。
// 调用方传 ID 时用它（必须与 message content 里 CardContent.ApprovalID 一致，
// 否则 APP 点按钮按 content 的 id 决策会找不到记录）；不传时走 DB default。
//
// decider 字段不在 INSERT 范围(pending 状态无决策人,MarkDecided 时回填)。
func (r *ApprovalRepo) Create(ctx context.Context, a model.Approval) (*model.Approval, error) {
	actionsRaw, err := model.MarshalActions(a.Actions)
	if err != nil {
		return nil, err
	}
	row := r.queryRow(ctx,
		`INSERT INTO approvals
		 (id, message_id, conversation_id, initiator_type, initiator_id, card_type, state, actions,
		  expires_at, session_key, allow_pattern, confirm_id)
		 VALUES (COALESCE(NULLIF($1, '')::uuid, gen_random_uuid()), $2, $3, $4, $5, $6, 'pending', $7, $8, $9, $10, $11)
		 RETURNING `+approvalSelectCols,
		a.ID, a.MessageID, a.ConversationID, a.InitiatorType, a.InitiatorID, a.CardType, actionsRaw,
		a.ExpiresAt, a.SessionKey, nullableString(a.AllowPattern), nullableString(a.ConfirmID),
	)
	return scanApproval(row)
}

// GetByID 查单条。不存在返回 (nil, nil)。
func (r *ApprovalRepo) GetByID(ctx context.Context, id string) (*model.Approval, error) {
	row := r.queryRow(ctx, `SELECT `+approvalSelectCols+` FROM approvals WHERE id = $1`, id)
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
func (r *ApprovalRepo) GetByMessageID(ctx context.Context, msgID string) (*model.Approval, error) {
	row := r.queryRow(ctx, `SELECT `+approvalSelectCols+` FROM approvals WHERE message_id = $1`, msgID)
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
func (r *ApprovalRepo) FindExpired(ctx context.Context, now time.Time) ([]*model.Approval, error) {
	rows, err := r.query(ctx,
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
// reason 仅 deny 时有意义。allowPattern 语义：NULLIF 空串清列——allow_always 传原 pattern（保留），
// 其余动作由 service 传空串（显式清掉 Create 时存的 pattern，防白名单污染）。
// answers 仅 question 决策有值，落 decided_answers JSONB。
// 同时回填 decider_type/decider_id(决策方信息,particpants 模型下随决策落库)。
// 已是终态时返回 ErrApprovalNotPending（用 WHERE state='pending' 做乐观锁）。
func (r *ApprovalRepo) MarkDecided(ctx context.Context, id, actionID, deciderType, deciderID, reason string, allowPattern *string, answers []string) error {
	state := model.ApprovalStateApproved
	// 对齐 service 层语义：deny（exec_approval）与 cancel（slash_confirm）都映射 denied。
	if actionID == "deny" || actionID == "cancel" {
		state = model.ApprovalStateDenied
	}
	var answersRaw any // nil → NULL（非 question 决策不落 decided_answers）
	if len(answers) > 0 {
		b, err := json.Marshal(answers)
		if err != nil {
			return err
		}
		answersRaw = b
	}
	res, err := r.exec(ctx,
		`UPDATE approvals
		 SET state = $1, decided_action = $2, decided_by = $3,
		     decided_reason = NULLIF($4, ''), decided_at = now(),
		     allow_pattern = NULLIF($5, ''),
		     decider_type = $6, decider_id = NULLIF($7, '')::uuid,
		     decided_answers = $8
		 WHERE id = $9 AND state = 'pending'`,
		state, actionID, deciderID, reason, nullableString(allowPattern), deciderType, deciderID, answersRaw, id,
	)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("RowsAffected 失败: %w", err)
	}
	if n == 0 {
		return ErrApprovalNotPending
	}
	return nil
}

// MarkExpired 推进到 expired 终态。
func (r *ApprovalRepo) MarkExpired(ctx context.Context, id string) error {
	res, err := r.exec(ctx,
		`UPDATE approvals SET state = 'expired'
		 WHERE id = $1 AND state = 'pending'`,
		id,
	)
	if err != nil {
		return err
	}
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("RowsAffected 失败: %w", err)
	}
	if n == 0 {
		return ErrApprovalNotPending
	}
	return nil
}

// MatchAllowPattern 查会话+initiator(agent) 是否有已 approved 且 allow_pattern 匹配 command 的记录。
// 匹配规则：allow_pattern 中 * → %, ? → _，大小写敏感（与 Linux shell 行为一致）。
// decided_action='allow_always' 双保险：只有「始终」决策才进白名单（配合 MarkDecided 的清列）。
func (r *ApprovalRepo) MatchAllowPattern(ctx context.Context, convID, initiatorID, command string) (bool, error) {
	var matched bool
	err := r.queryRow(ctx,
		`SELECT EXISTS(
		   SELECT 1 FROM approvals
		   WHERE conversation_id = $1
		     AND initiator_id = $2
		     AND initiator_type = 'agent'
		     AND state = 'approved'
		     AND allow_pattern IS NOT NULL
		     AND decided_action = 'allow_always'
		     AND $3 LIKE replace(replace(replace(replace(replace(allow_pattern, '\', '\\'), '%', '\%'), '_', '\_'), '*', '%'), '?', '_') ESCAPE '\'
		   LIMIT 1
		)`,
		convID, initiatorID, command,
	).Scan(&matched)
	if err != nil {
		return false, err
	}
	return matched, nil
}

// GetForDecision 一次 JOIN messages 查询决策所需的所有字段。
// 不存在返回 (nil, nil)，由调用方判断。
func (r *ApprovalRepo) GetForDecision(ctx context.Context, id string) (*DecisionContext, error) {
	row := r.queryRow(ctx,
		`SELECT a.id, a.message_id, a.conversation_id, a.initiator_type, a.initiator_id,
		        a.session_key, a.confirm_id, a.allow_pattern, a.actions, m.content
		 FROM approvals a JOIN messages m ON m.id = a.message_id
		 WHERE a.id = $1`,
		id,
	)
	var (
		ctxObj     DecisionContext
		actionsRaw []byte
		contentRaw []byte
		allowPat   sql.NullString
		confirmID  sql.NullString
	)
	err := row.Scan(
		&ctxObj.ApprovalID, &ctxObj.MessageID, &ctxObj.ConversationID, &ctxObj.InitiatorType, &ctxObj.InitiatorID,
		&ctxObj.SessionKey, &confirmID, &allowPat, &actionsRaw, &contentRaw,
	)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return nil, err
	}
	if allowPat.Valid {
		ctxObj.AllowPattern = &allowPat.String
	}
	ctxObj.ConfirmID = confirmID.String
	var wrapper struct {
		Data model.CardContent `json:"data"`
	}
	if err := json.Unmarshal(contentRaw, &wrapper); err != nil {
		return nil, err
	}
	ctxObj.CardContent = wrapper.Data
	// actions 单独存表，覆盖 content 里可能不一致的副本（以表为准）
	ctxObj.CardContent.Actions, _ = model.UnmarshalActions(actionsRaw)
	return &ctxObj, nil
}

// UpdateMessageContent 更新 messages.content（service 双写 state 用）。
func (r *ApprovalRepo) UpdateMessageContent(ctx context.Context, messageID string, content []byte) error {
	_, err := r.exec(ctx, `UPDATE messages SET content = $1 WHERE id = $2`, content, messageID)
	return err
}
