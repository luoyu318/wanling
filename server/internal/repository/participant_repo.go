package repository

import (
	"context"
	"database/sql"
	"errors"
	"time"

	"github.com/lib/pq"
	"github.com/wanling/server/internal/model"
)

// ParticipantRepo 操作 conversation_participants 表(N 方参与者通用模型)。
// 接管原 conversations.user_id/agent_id/unread_count/hidden_at/pinned_at 的全部读写,
// 把"会话-成员关系 + 个人维度状态"统一沉到本表。
type ParticipantRepo struct {
	queryExecutor
}

func NewParticipantRepo(db *sql.DB) *ParticipantRepo {
	return &ParticipantRepo{queryExecutor: queryExecutor{db: db}}
}

// ParticipantInput 是 AddParticipantsTx 的入参(创建会话 / 邀请成员用)。
type ParticipantInput struct {
	MemberID   string
	MemberType string // user / agent
	Role       string // owner / admin / member
}

// AddParticipantsTx 批量加参与者(创建会话 / 邀请成员用)。
// 用 ON CONFLICT DO NOTHING 保证幂等:同 member 重复加不报错(邀请已存在成员 / 重发)。
// 调用方必须在外层事务里调,失败时整批回滚。
//
// 用 unnest 批量(对齐 HideForUsers / DeliveryRepo.CreateBatchTx 范式),
// N participant = 1 次 SQL 往返。
//
// ctx 用于让 tx 内 query 也响应 cancel(tx.ExecContext 会消费此 ctx)。
func (r *ParticipantRepo) AddParticipantsTx(ctx context.Context, tx *sql.Tx, convID string, participants []ParticipantInput) error {
	if len(participants) == 0 {
		return nil
	}
	ids := make([]string, len(participants))
	types := make([]string, len(participants))
	roles := make([]string, len(participants))
	for i, p := range participants {
		ids[i] = p.MemberID
		types[i] = p.MemberType
		roles[i] = p.Role
	}
	_, err := tx.ExecContext(ctx, `
		INSERT INTO conversation_participants (conv_id, member_id, member_type, role)
		SELECT $1, u.id, u.typ, u.role
		FROM unnest($2::uuid[], $3::text[], $4::text[]) AS u(id, typ, role)
		ON CONFLICT (conv_id, member_id, member_type) DO NOTHING
	`, convID, pq.Array(ids), pq.Array(types), pq.Array(roles))
	return err
}

// rowsQueryer 抽象 *sql.DB 和 *sql.Tx 共有的 QueryContext 方法,
// 让 ListByConversation / ListByConversationTx 共享同一份 SQL 实现。
type rowsQueryer interface {
	QueryContext(ctx context.Context, query string, args ...any) (*sql.Rows, error)
}

// listParticipantsByConv 是 ListByConversation / ListByConversationTx 的共享实现。
// 同事务读避免并发写消息时的脏读(读到旧 participants 漏算新成员未读)。
// LIMIT 兜底防群聊参与者膨胀拖垮内存(IM APP 群上限 1000 足够覆盖 99% 场景)。
func listParticipantsByConv(ctx context.Context, q rowsQueryer, convID string) ([]model.ConversationParticipant, error) {
	rows, err := q.QueryContext(ctx, `
		SELECT conv_id, member_id, member_type, role, unread_count, last_read_message_id, joined_at, hidden_at, pinned_at
		FROM conversation_participants WHERE conv_id = $1
		LIMIT 1000
	`, convID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	return scanParticipants(rows)
}

// ListByConversation 返回会话所有参与者(发消息 / 推送 / 详情页用)。
func (r *ParticipantRepo) ListByConversation(ctx context.Context, convID string) ([]model.ConversationParticipant, error) {
	return listParticipantsByConv(ctx, r.queryExecutor.db, convID)
}

// ListByConversationTx 事务版本(MessageProcessor 同事务查 participants 用)。
// ctx 用于让 tx 内 query 也响应 cancel(tx.QueryContext 会消费此 ctx)。
// 之前的版本误以为 BeginTx 的 ctx 自动透传到 tx 内 query,实际 driver 行为是非 Context 变体
// 内部用 context.Background()(Go 标准库事实),必须显式用 *Context 变体才生效。
func (r *ParticipantRepo) ListByConversationTx(ctx context.Context, tx *sql.Tx, convID string) ([]model.ConversationParticipant, error) {
	return listParticipantsByConv(ctx, tx, convID)
}

// Exists 校验某 member 是否在某会话(权限中间件用)。
// 命中走 INDEX (conv_id, member_id, member_type) PRIMARY KEY,纯存在性查询比 Get 轻量。
func (r *ParticipantRepo) Exists(ctx context.Context, convID, memberID, memberType string) (bool, error) {
	var exists bool
	err := r.queryRow(ctx, `
		SELECT EXISTS(SELECT 1 FROM conversation_participants
		               WHERE conv_id = $1 AND member_id = $2 AND member_type = $3)
	`, convID, memberID, memberType).Scan(&exists)
	return exists, err
}

// Get 单查(权限 / 状态校验用)。不存在返 (nil, nil),不返 error,让调用方用 nil 判断分支。
func (r *ParticipantRepo) Get(ctx context.Context, convID, memberID, memberType string) (*model.ConversationParticipant, error) {
	p := &model.ConversationParticipant{}
	var lastReadID *string
	var hiddenAt, pinnedAt *time.Time
	err := r.queryRow(ctx, `
		SELECT conv_id, member_id, member_type, role, unread_count, last_read_message_id, joined_at, hidden_at, pinned_at
		FROM conversation_participants WHERE conv_id = $1 AND member_id = $2 AND member_type = $3
	`, convID, memberID, memberType).Scan(
		&p.ConvID, &p.MemberID, &p.MemberType, &p.Role, &p.UnreadCount,
		&lastReadID, &p.JoinedAt, &hiddenAt, &pinnedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	p.LastReadMessageID = lastReadID
	p.HiddenAt = hiddenAt
	p.PinnedAt = pinnedAt
	return p, nil
}

// IncrUnreadTx 发消息时给非 sender 全员 +1 unread_count。
// exceptMember 是 (sender_id, sender_type) 元组。
// 调用方必须在外层事务里调,确保 unread_count 自增与消息落库原子性。
//
// 调用方责任:必须先校验 sender 是该会话 participant(用 Exists 方法),
// 否则 UPDATE 会给该会话所有成员 +1 unread(包括 sender 不在的"幽灵消息"场景),
// 这是 fail-open 行为,MessageProcessor 在消息落库前需加 Exists 守卫。
//
// ctx 用于让 tx 内 query 也响应 cancel(tx.ExecContext 会消费此 ctx)。
func (r *ParticipantRepo) IncrUnreadTx(ctx context.Context, tx *sql.Tx, convID, exceptMemberID, exceptMemberType string) error {
	_, err := tx.ExecContext(ctx, `
		UPDATE conversation_participants
		SET unread_count = unread_count + 1
		WHERE conv_id = $1
		  AND NOT (member_id = $2 AND member_type = $3)
	`, convID, exceptMemberID, exceptMemberType)
	return err
}

// RecomputeUnreadForConvTx 按 conv 维度重算所有 participants 的 unread_count。
//
// 用途:撤回(message_handler Delete scope=recall)时,被撤回的消息应从未读计数里剔除。
// 软删(deleted_at = NOW())后调本方法对齐 DB 状态。
//
// 口径跟 MarkMessagesReadTx 的重算完全一致:
//   - deleted_at IS NULL(排除已撤回)
//   - NOT EXISTS message_hidden(排除该 member 隐藏过的)
//   - deliveries.read_at IS NULL(排除已读)
//   - content->>'silent' IS DISTINCT FROM 'true'(排除 silent 过程消息,
//     与 processor.IncrUnreadTx 的自增口径对齐 — 否则重算会把 silent 的未读
//     delivery 计入,导致 markRead 后 unread_count 不归零,会话列表徽章残留)
//
// 一次性 UPDATE 该 conv 所有 participants 行(用相关子查询算每人的新值),
// 单 SQL 不需要 N+1 查询。事务所有权归调用方(撤回 handler 包外层事务)。
//
// ctx 用于让 tx 内 query 也响应 cancel(tx.ExecContext 会消费此 ctx)。
func (r *ParticipantRepo) RecomputeUnreadForConvTx(ctx context.Context, tx *sql.Tx, convID string) error {
	_, err := tx.ExecContext(ctx, `
		UPDATE conversation_participants p
		SET unread_count = COALESCE((
		    SELECT COUNT(*) FROM message_deliveries d
		    JOIN messages m ON m.id = d.message_id
		    WHERE d.recipient_id = p.member_id AND d.recipient_type = p.member_type
		      AND d.read_at IS NULL
		      AND m.conversation_id = p.conv_id AND m.deleted_at IS NULL
		      AND m.content->>'silent' IS DISTINCT FROM 'true'
		      AND NOT EXISTS (
		        SELECT 1 FROM message_hidden h
		        WHERE h.message_id = m.id AND h.member_id = p.member_id AND h.member_type = p.member_type
		      )
		), 0)
		WHERE p.conv_id = $1`,
		convID)
	return err
}

// MarkMessagesReadTx 批量标已读:UPDATE deliveries + 重算 unread_count + 更新 last_read_message_id。
// 返回新的 unread_count(供 WS 推送 / IM 列表 refresh 用)。
//
// 事务所有权归调用方:本方法只接收 tx,不做 BeginTx/Commit/Rollback。
// 调用方负责 Commit(成功路径)或 Rollback(err 路径)。
// 不存在该 (conv, member) 时返 sql.ErrNoRows,调用方据此转 404。
//
// unread_count 必须按 conv 维度重算(不能按 member 全局),因为同一 member 可能参与多个会话,
// 只把"本会话内未读 delivery"计入。
//
// last_read_message_id 取已读 deliveries 中最大 created_at 对应的 message_id,
// 用于 APP 端"已读分隔条"定位。
//
// ctx 用于让 tx 内 query 也响应 cancel(tx.ExecContext/QueryRowContext 会消费此 ctx)。
func (r *ParticipantRepo) MarkMessagesReadTx(ctx context.Context, tx *sql.Tx, convID, memberID, memberType string, messageIDs []string) (int, error) {
	// 1. 标 deliveries 已读(只更新未读的,避免重复刷 read_at 时间戳)
	if len(messageIDs) > 0 {
		_, err := tx.ExecContext(ctx, `
			UPDATE message_deliveries SET read_at = NOW()
			WHERE recipient_id = $1 AND recipient_type = $2
			  AND message_id = ANY($3::uuid[])
			  AND read_at IS NULL
		`, memberID, memberType, pq.Array(messageIDs))
		if err != nil {
			return 0, err
		}
	}

	// 2. 重算 unread_count(只算该 conv 内的未读,不是全局)
	//    过滤软删 + 该 member 隐藏过的消息(hidden 消息不计未读,徽章数字才准)
	//    + silent 过程消息(与 processor.IncrUnreadTx 自增口径对齐,silent 不计数)
	var newUnread int
	err := tx.QueryRowContext(ctx, `
		SELECT COUNT(*) FROM message_deliveries d
		JOIN messages m ON m.id = d.message_id
		WHERE d.recipient_id = $1 AND d.recipient_type = $2 AND d.read_at IS NULL
		  AND m.conversation_id = $3 AND m.deleted_at IS NULL
		  AND m.content->>'silent' IS DISTINCT FROM 'true'
		  AND NOT EXISTS (
		    SELECT 1 FROM message_hidden h
		    WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = $2
		  )
	`, memberID, memberType, convID).Scan(&newUnread)
	if err != nil {
		return 0, err
	}

	// 3. 更新 unread_count + last_read_message_id
	//    WHERE 必须加 conv_id 限定,避免 member 参与多个 conv 时一次性改所有行的 unread_count。
	//    last_read_message_id 取该 conv 内已读 deliveries 中最新消息(m.created_at DESC LIMIT 1)
	//    子查询若返 NULL(无已读 delivery)不影响 unread_count 更新。
	//    hidden 消息不参与 last_read(已隐藏的不应作"已读进度"锚点)。
	//    RowsAffected=0 表示该 member 不在此 conv(越权 / 未邀请),返 sentinel 让 handler 转 404。
	res, err := tx.ExecContext(ctx, `
		UPDATE conversation_participants p
		SET unread_count = $3,
		    last_read_message_id = (
		      SELECT d.message_id FROM message_deliveries d
		      JOIN messages m ON m.id = d.message_id
		      WHERE d.recipient_id = $1 AND d.recipient_type = $2 AND d.read_at IS NOT NULL
		        AND m.conversation_id = $4 AND m.deleted_at IS NULL
		        AND NOT EXISTS (
		          SELECT 1 FROM message_hidden h
		          WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = $2
		        )
		      ORDER BY m.created_at DESC LIMIT 1
		    )
		WHERE p.conv_id = $4 AND p.member_id = $1 AND p.member_type = $2
	`, memberID, memberType, newUnread, convID)
	if err != nil {
		return 0, err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return 0, err
	}
	if rows == 0 {
		return 0, sql.ErrNoRows // 越权 / 该 member 不在此 conv
	}
	return newUnread, nil
}

// SetPinned 个人维度置顶(true=置顶 / false=取消)。
// 与原 conversations.pinned_at 不同,本字段在 participant 行上,每个 member 各自独立。
func (r *ParticipantRepo) SetPinned(ctx context.Context, convID, memberID, memberType string, pinned bool) error {
	var t *time.Time
	if pinned {
		now := time.Now()
		t = &now
	}
	_, err := r.exec(ctx, `
		UPDATE conversation_participants SET pinned_at = $4
		WHERE conv_id = $1 AND member_id = $2 AND member_type = $3
	`, convID, memberID, memberType, t)
	return err
}

// SetHidden 个人维度隐藏(true=隐藏 / false=取消)。
// 与原 conversations.hidden_at 不同,本字段在 participant 行上,每个 member 各自独立。
// 上层业务规则(发消息自动取消隐藏)由调用方实现,本方法只做字段更新。
func (r *ParticipantRepo) SetHidden(ctx context.Context, convID, memberID, memberType string, hidden bool) error {
	var t *time.Time
	if hidden {
		now := time.Now()
		t = &now
	}
	_, err := r.exec(ctx, `
		UPDATE conversation_participants SET hidden_at = $4
		WHERE conv_id = $1 AND member_id = $2 AND member_type = $3
	`, convID, memberID, memberType, t)
	return err
}

// UnhideTx 事务版:清空整个会话所有 participants 的 hidden_at。
//
// 用于 MessageProcessor.PersistAndDispatch — 任何新消息触发时,清掉会话内
// 所有 participant 各自的 hidden_at(含 sender + 全部 recipients)。
//
// 对齐 migration 004 承诺的「新消息来时置空(自动恢复显示)」语义。N 方模型下
// 精确为「会话有新消息,每个 participant 的隐藏状态都自动恢复」—— 主流 IM 行为
// 是删除会话后对方再发消息会话会重新出现,而非仅 sender 自己恢复。
//
// 调用方必须在外层事务里调,与 message 创建 + unread 计数原子提交。
//
// ctx 用于让 tx 内 query 也响应 cancel(tx.ExecContext 会消费此 ctx)。
func (r *ParticipantRepo) UnhideTx(ctx context.Context, tx *sql.Tx, convID string) error {
	_, err := tx.ExecContext(ctx, `
		UPDATE conversation_participants SET hidden_at = NULL
		WHERE conv_id = $1
	`, convID)
	return err
}

// Unhide 非事务版:清空整个会话所有 participants 的 hidden_at。
//
// 用于消息持久化事务 commit 之后的 best-effort 清理(原 UnhideTx 在事务内与
// IncrUnreadTx 对同一批 participant 行交叉锁,多 agent 并发发消息触发 PG deadlock
// 40P01,整条消息事务回滚丢失)。Unhide 语义幂等(SET NULL),不要求与消息创建原子
// —— 消息已 commit 即必然可见,列表恢复显示即使延迟几十毫秒也不影响 IM 体验。
//
// 失败由调用方决定吞掉(只 log)还是上抛:PersistAndDispatch 选择只 log,不让
// 幂等清理的失败把已成功的消息投递变成失败返回。
func (r *ParticipantRepo) Unhide(ctx context.Context, convID string) error {
	_, err := r.exec(ctx, `
		UPDATE conversation_participants SET hidden_at = NULL
		WHERE conv_id = $1
	`, convID)
	return err
}

// RemoveParticipantTx 删除单个 participant(踢人 / 普通成员退群)。
// 不级联删会话(只删 member 行)。owner 退群用 DestroyConversationTx。
// 调用方必须在外层事务里调,确保与权限校验原子性。
//
// ctx 用于让 tx 内 query 也响应 cancel(tx.ExecContext 会消费此 ctx)。
func (r *ParticipantRepo) RemoveParticipantTx(ctx context.Context, tx *sql.Tx, convID, memberID, memberType string) error {
	_, err := tx.ExecContext(ctx, `
		DELETE FROM conversation_participants
		WHERE conv_id = $1 AND member_id = $2 AND member_type = $3
	`, convID, memberID, memberType)
	return err
}

// DestroyConversationTx owner 退群 → 删整个会话(走 conversations ON DELETE CASCADE 级联删 participants + messages + deliveries)。
//
// 安全约束:本方法不做 owner 身份校验,调用方必须在 handler 层先校验
// caller 是该会话 owner(spec §6.2),否则任何 member 都能销群。
// 调用方(Leave / Disband handler)必须查 participant.role='owner' 才调本方法。
//
// ctx 用于让 tx 内 query 也响应 cancel(tx.ExecContext 会消费此 ctx)。
func (r *ParticipantRepo) DestroyConversationTx(ctx context.Context, tx *sql.Tx, convID string) error {
	_, err := tx.ExecContext(ctx, `DELETE FROM conversations WHERE id = $1`, convID)
	return err
}

// scanParticipants 把 *sql.Rows 扫成 ConversationParticipant 切片。
// ListByConversation / ListByConversationTx / ListByMember 共用。
// last_read_message_id / hidden_at / pinned_at 都是可空字段,扫到 *string / *time.Time。
func scanParticipants(rows *sql.Rows) ([]model.ConversationParticipant, error) {
	var result []model.ConversationParticipant
	for rows.Next() {
		var p model.ConversationParticipant
		var lastReadID *string
		var hiddenAt, pinnedAt *time.Time
		if err := rows.Scan(
			&p.ConvID, &p.MemberID, &p.MemberType, &p.Role, &p.UnreadCount,
			&lastReadID, &p.JoinedAt, &hiddenAt, &pinnedAt,
		); err != nil {
			return nil, err
		}
		p.LastReadMessageID = lastReadID
		p.HiddenAt = hiddenAt
		p.PinnedAt = pinnedAt
		result = append(result, p)
	}
	return result, rows.Err()
}
