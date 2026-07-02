package repository

import (
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
// unread_count 由 ParticipantRepo.MarkMessagesReadTx 调用 GetUnreadCountTx 重算,
// 不在本 repo 维护(因为 unread_count 是 participant 行的字段,语义归属参与者模型)。
//
// 设计见 docs/superpowers/specs/2026-07-02-participants-model-refactor-design.md §3.2。
type DeliveryRepo struct {
	db *sql.DB
}

func NewDeliveryRepo(db *sql.DB) *DeliveryRepo {
	return &DeliveryRepo{db: db}
}

// CreateBatchTx 发消息时批量插 deliveries(每 non-sender participant 一行,read_at=NULL)。
// ON CONFLICT DO NOTHING 保证幂等(理论上同 message+recipient 不会重复,但防御性)。
//
// 事务所有权归调用方:本方法只接收 tx,不做 BeginTx/Commit/Rollback。
// 调用方(MessageProcessor)负责 Commit(成功路径)或 Rollback(err 路径)。
// 入参 recipients 已经过滤掉 sender(由 MessageProcessor 用 ListByConversationTx
// 拿全量后排除 sender),本方法不做 sender 过滤。
func (r *DeliveryRepo) CreateBatchTx(tx *sql.Tx, messageID string, recipients []model.ConversationParticipant) error {
	if len(recipients) == 0 {
		return nil
	}
	stmt, err := tx.Prepare(`
		INSERT INTO message_deliveries (message_id, recipient_id, recipient_type, read_at)
		VALUES ($1, $2, $3, NULL)
		ON CONFLICT (message_id, recipient_id, recipient_type) DO NOTHING
	`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for _, rc := range recipients {
		if _, err := stmt.Exec(messageID, rc.MemberID, rc.MemberType); err != nil {
			return err
		}
	}
	return nil
}

// MarkReadBatchTx 批量标 deliveries 已读,返回影响行数。
// 只标 recipient 拥有的 deliveries(WHERE recipient_id + recipient_type 自然过滤,
// 防越权标别人的 delivery)。read_at IS NULL 守卫避免重复刷时间戳。
//
// 事务所有权归调用方:本方法只接收 tx,不做 BeginTx/Commit/Rollback。
// 返回的 RowsAffected 让上层判断是否真的标了(0 可能表示这些消息已被标过或 recipient 不持有)。
func (r *DeliveryRepo) MarkReadBatchTx(tx *sql.Tx, messageIDs []string, recipientID, recipientType string) (int64, error) {
	if len(messageIDs) == 0 {
		return 0, nil
	}
	res, err := tx.Exec(`
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

// rowQueryer 抽象 *sql.DB 和 *sql.Tx 共有的 QueryRow 方法,
// 让 FirstUnread / GetUnreadCount 的 Tx / 非 Tx 版本共享同一份 SQL 实现。
// 与 participant_repo.go 的 rowsQueryer(抽 Query 返回 *sql.Rows)互补,两者都在本包可见。
type rowQueryer interface {
	QueryRow(query string, args ...any) *sql.Row
}

// FirstUnread 返回某 recipient 在某 conv 的首条未读 message(无未读返 nil)。
// 走 partial index idx_deliveries_unread(过滤 read_at IS NULL)+ JOIN messages 排序。
// JOIN 加 m.deleted_at IS NULL 过滤软删消息 + LEFT JOIN message_hidden 过滤该 recipient 隐藏过的消息。
//
// 失败语义:无未读返 (nil, nil),DB 错误返 (nil, err),让调用方用 nil 判断分支。
func (r *DeliveryRepo) FirstUnread(convID, recipientID, recipientType string) (*model.Message, error) {
	return firstUnreadQuery(r.db, convID, recipientID, recipientType)
}

// FirstUnreadTx 事务版本(MessageProcessor 同事务查首条未读用,避免与并发写冲突脏读)。
func (r *DeliveryRepo) FirstUnreadTx(tx *sql.Tx, convID, recipientID, recipientType string) (*model.Message, error) {
	return firstUnreadQuery(tx, convID, recipientID, recipientType)
}

// firstUnreadQuery 是 FirstUnread / FirstUnreadTx 的共享实现。
func firstUnreadQuery(q rowQueryer, convID, recipientID, recipientType string) (*model.Message, error) {
	m := &model.Message{}
	err := q.QueryRow(`
		SELECT m.id, m.conversation_id, m.sender_type, m.sender_id, m.content, m.created_at
		FROM message_deliveries d
		JOIN messages m ON m.id = d.message_id
		WHERE d.recipient_id = $1 AND d.recipient_type = $2 AND d.read_at IS NULL
		  AND m.conversation_id = $3 AND m.deleted_at IS NULL
		  AND NOT EXISTS (
		    SELECT 1 FROM message_hidden h
		    WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = $2
		  )
		ORDER BY m.created_at ASC
		LIMIT 1
	`, recipientID, recipientType, convID).Scan(
		&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.CreatedAt,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return m, nil
}

// GetUnreadCount 非事务版本(GET /api/conversations/:id/unread 用,handler 直接调)。
// JOIN messages 过滤软删消息 + LEFT JOIN message_hidden 过滤该 recipient 隐藏过的消息,
// 避免已删/已隐藏消息的 delivery 残留污染未读计数。
func (r *DeliveryRepo) GetUnreadCount(convID, recipientID, recipientType string) (int, error) {
	return getUnreadCountQuery(r.db, convID, recipientID, recipientType)
}

// GetUnreadCountTx 事务版本(ParticipantRepo.MarkMessagesReadTx 重算 unread_count 用)。
// 同事务读避免与并发标已读 / 软删冲突脏读。
func (r *DeliveryRepo) GetUnreadCountTx(tx *sql.Tx, convID, recipientID, recipientType string) (int, error) {
	return getUnreadCountQuery(tx, convID, recipientID, recipientType)
}

// getUnreadCountQuery 是 GetUnreadCount / GetUnreadCountTx 的共享实现。
func getUnreadCountQuery(q rowQueryer, convID, recipientID, recipientType string) (int, error) {
	var count int
	err := q.QueryRow(`
		SELECT COUNT(*) FROM message_deliveries d
		JOIN messages m ON m.id = d.message_id
		WHERE d.recipient_id = $1 AND d.recipient_type = $2 AND d.read_at IS NULL
		  AND m.conversation_id = $3 AND m.deleted_at IS NULL
		  AND NOT EXISTS (
		    SELECT 1 FROM message_hidden h
		    WHERE h.message_id = m.id AND h.member_id = $1 AND h.member_type = $2
		  )
	`, recipientID, recipientType, convID).Scan(&count)
	return count, err
}
