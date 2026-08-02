package repository

import (
	"context"
	"database/sql"
	"errors"

	"github.com/lib/pq"
	"github.com/wanling/server/internal/model"
)

// DeliveryRepo 操作 message_deliveries 表(per-recipient 投递状态)。
// 接管原 messages.is_read 单字段的全部读写语义:
//   - read_at IS NULL ⇔ 未读(原 is_read=FALSE)
//   - read_at NOT NULL ⇔ 已读(原 is_read=TRUE)
//
// unread_count 维护已下沉到 conversation_participants 行(ParticipantRepo 负责),
// 本 repo 只读不写 unread_count。
type DeliveryRepo struct {
	queryExecutor
}

func NewDeliveryRepo(db *sql.DB) *DeliveryRepo {
	return &DeliveryRepo{queryExecutor: queryExecutor{db: db}}
}

// CreateBatchTx 发消息时批量插 deliveries(每 non-sender participant 一行,read_at=NULL)。
// ON CONFLICT DO NOTHING 保证幂等(理论上同 message+recipient 不会重复,但防御性)。
//
// 用 unnest 批量(对齐 HideForUsers 范式),N recipient = 1 次 SQL 往返,而非 N 次。
//
// 事务所有权归调用方:本方法只接收 tx,不做 BeginTx/Commit/Rollback。
// 调用方(MessageProcessor)负责 Commit(成功路径)或 Rollback(err 路径)。
// 入参 recipients 已经过滤掉 sender(由 MessageProcessor 用 ListByConversationTx
// 拿全量后排除 sender),本方法不做 sender 过滤。
//
// ctx 用于让 tx 内 query 也响应 cancel(tx.ExecContext 会消费此 ctx)。
func (r *DeliveryRepo) CreateBatchTx(ctx context.Context, tx *sql.Tx, messageID string, recipients []model.ConversationParticipant) error {
	if len(recipients) == 0 {
		return nil
	}
	ids := make([]string, len(recipients))
	types := make([]string, len(recipients))
	for i, rc := range recipients {
		ids[i] = rc.MemberID
		types[i] = rc.MemberType
	}
	_, err := tx.ExecContext(ctx, `
		INSERT INTO message_deliveries (message_id, recipient_id, recipient_type, read_at)
		SELECT $1, u.id, u.typ, NULL
		FROM unnest($2::uuid[], $3::text[]) AS u(id, typ)
		ON CONFLICT (message_id, recipient_id, recipient_type) DO NOTHING
	`, messageID, pq.Array(ids), pq.Array(types))
	return err
}

// CreateBatchReadTx 发消息时批量插 deliveries 并直接标 read_at=NOW()(已读态)。
// 用于子 agent 事件(is_main_stream=false 的过程消息):主列表不展示这类消息,
// 不应产生未读角标,但保留 delivery 记录供审计/追溯(避免孤儿未读累积)。
// 其余语义与 CreateBatchTx 一致(unnest 批量 + ON CONFLICT DO NOTHING 幂等)。
func (r *DeliveryRepo) CreateBatchReadTx(ctx context.Context, tx *sql.Tx, messageID string, recipients []model.ConversationParticipant) error {
	if len(recipients) == 0 {
		return nil
	}
	ids := make([]string, len(recipients))
	types := make([]string, len(recipients))
	for i, rc := range recipients {
		ids[i] = rc.MemberID
		types[i] = rc.MemberType
	}
	_, err := tx.ExecContext(ctx, `
		INSERT INTO message_deliveries (message_id, recipient_id, recipient_type, read_at)
		SELECT $1, u.id, u.typ, NOW()
		FROM unnest($2::uuid[], $3::text[]) AS u(id, typ)
		ON CONFLICT (message_id, recipient_id, recipient_type) DO NOTHING
	`, messageID, pq.Array(ids), pq.Array(types))
	return err
}

// MarkReadBatchTx 批量标 deliveries 已读,返回影响行数。
// 只标 recipient 拥有的 deliveries(WHERE recipient_id + recipient_type 自然过滤,
// 防越权标别人的 delivery)。read_at IS NULL 守卫避免重复刷时间戳。
//
// 事务所有权归调用方:本方法只接收 tx,不做 BeginTx/Commit/Rollback。
// 返回的 RowsAffected 让上层判断是否真的标了(0 可能表示这些消息已被标过或 recipient 不持有)。
//
// ctx 用于让 tx 内 query 也响应 cancel(tx.ExecContext 会消费此 ctx)。
func (r *DeliveryRepo) MarkReadBatchTx(ctx context.Context, tx *sql.Tx, messageIDs []string, recipientID, recipientType string) (int64, error) {
	if len(messageIDs) == 0 {
		return 0, nil
	}
	res, err := tx.ExecContext(ctx, `
		UPDATE message_deliveries SET read_at = NOW()
		WHERE recipient_id = $1 AND recipient_type = $2
		  AND message_id = ANY($3::uuid[])
		  AND read_at IS NULL
	`, recipientID, recipientType, pq.Array(messageIDs))
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// ListUnreadMessageIDsByConv 返回某 recipient 在某 conv 的所有未读 message_id。
// 用于整会话标已读(MarkRead)前取目标集合,再交给 MarkReadBatchTx 批量更新。
// 过滤软删消息(配 messages.deleted_at IS NULL)。
// 事务所有权归调用方:本方法只接收 tx,不做 BeginTx/Commit/Rollback。
// ctx 用于让 tx 内 query 也响应 cancel(tx.QueryContext 会消费此 ctx)。
func (r *DeliveryRepo) ListUnreadMessageIDsByConv(ctx context.Context, tx *sql.Tx, convID, recipientID, recipientType string) ([]string, error) {
	rows, err := tx.QueryContext(ctx, `
		SELECT d.message_id FROM message_deliveries d
		JOIN messages m ON m.id = d.message_id
		WHERE d.recipient_id = $1 AND d.recipient_type = $2 AND d.read_at IS NULL
		  AND m.conversation_id = $3 AND m.deleted_at IS NULL
	`, recipientID, recipientType, convID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return ids, nil
}

// rowQueryer 抽象 *sql.DB 和 *sql.Tx 共有的 QueryRowContext 方法,
// 让 firstUnreadQuery 共享实现(为未来再加 Tx 版本预留)。
// 与 participant_repo.go 的 rowsQueryer(抽 QueryContext 返回 *sql.Rows)互补,两者都在本包可见。
type rowQueryer interface {
	QueryRowContext(ctx context.Context, query string, args ...any) *sql.Row
}

// FirstUnread 返回某 recipient 在某 conv 的首条未读 message(无未读返 nil)。
// 走 partial index idx_deliveries_unread(过滤 read_at IS NULL)+ JOIN messages 排序。
// JOIN 加 m.deleted_at IS NULL 过滤软删消息 + LEFT JOIN message_hidden 过滤该 recipient 隐藏过的消息。
// 与 ListBefore/ListAfter 一致,过滤子 agent 事件(m.is_main_stream),避免子事件成为未读锚点
// 而 List 系列却过滤它导致空锚点不一致。审批卡豁免 is_main_stream(migration 008),可作未读锚点。
//
// silent 消息(content->>'silent' = 'true')不计入 unread_count(processor IncrUnreadTx 跳过),
// 也不应作为未读锚点:client 端 _filterDisplayable 会过滤 step_finish,若 FirstUnread
// 返回 step_finish 会让 client 的 messages 列表为空,定位 + markRead 都无法触发,
// 导致徽章残留(2026-07 修复的 silent→残留 bug)。
//
// 失败语义:无未读返 (nil, nil),DB 错误返 (nil, err),让调用方用 nil 判断分支。
func (r *DeliveryRepo) FirstUnread(ctx context.Context, convID, recipientID, recipientType string) (*model.Message, error) {
	return firstUnreadQuery(ctx, r.queryExecutor.db, convID, recipientID, recipientType)
}

// firstUnreadQuery 是 FirstUnread 的实现(支持 *sql.DB / *sql.Tx 通过 rowQueryer 抽象)。
func firstUnreadQuery(ctx context.Context, q rowQueryer, convID, recipientID, recipientType string) (*model.Message, error) {
	m := &model.Message{}
	err := q.QueryRowContext(ctx, `
		SELECT m.id, m.conversation_id, m.sender_type, m.sender_id, m.content, m.parent_msg_id, m.root_msg_id, m.created_at
		FROM message_deliveries d
		JOIN messages m ON m.id = d.message_id
		WHERE d.recipient_id = $1 AND d.recipient_type = $2 AND d.read_at IS NULL
		  AND m.conversation_id = $3 AND m.deleted_at IS NULL
		  AND m.is_main_stream
		  AND m.content->>'silent' IS DISTINCT FROM 'true'
		  AND NOT EXISTS (
		    SELECT 1 FROM message_hidden h
		    WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = $2
		  )
		ORDER BY m.created_at ASC
		LIMIT 1
	`, recipientID, recipientType, convID).Scan(
		&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.ParentMsgID, &m.RootMsgID, &m.CreatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return m, nil
}
