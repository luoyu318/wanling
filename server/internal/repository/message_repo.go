// MessageRepo 操作 messages 表。
//
// participants 模型重构后,本 repo 职责瘦身:
//   - createMessage 不再写 is_read 字段(该字段已 DROP)
//   - per-recipient 投递状态(read_at)由 DeliveryRepo 管,本 repo 只关心消息本身
//   - 删除 FirstUnread(下沉 DeliveryRepo.FirstUnread / FirstUnreadTx)
//
// 设计见 docs/superpowers/specs/2026-07-02-participants-model-refactor-design.md §3.3。
package repository

import (
	"database/sql"
	"encoding/json"
	"errors"
	"time"

	"github.com/lib/pq"
	"github.com/wanling/server/internal/model"
)

type MessageRepo struct {
	db *sql.DB
}

func NewMessageRepo(db *sql.DB) *MessageRepo {
	return &MessageRepo{db: db}
}

func (r *MessageRepo) Create(convID, senderType, senderID string, content json.RawMessage) (*model.Message, error) {
	return r.createMessage(r.db.QueryRow, convID, senderType, senderID, content)
}

// CreateTx 在外部事务中创建消息,供 MessageProcessor 与缓存更新原子化提交使用。
// 调用方负责 Begin/Commit/Rollback;本方法只 INSERT + RETURNING。
func (r *MessageRepo) CreateTx(tx *sql.Tx, convID, senderType, senderID string, content json.RawMessage) (*model.Message, error) {
	return r.createMessage(tx.QueryRow, convID, senderType, senderID, content)
}

// createMessage 是 Create / CreateTx 的公共实现,用闭包接收 QueryRow 能力。
// *sql.DB 和 *sql.Tx 的 QueryRow 方法签名相同,闭包方案比 interface 更轻量。
//
// participants 模型重构后,本方法只 INSERT messages 本身,不写任何 per-recipient 状态。
// deliveries(read_at)由 MessageProcessor 协调 DeliveryRepo.CreateBatchTx 写,
// 未读计数由 ParticipantRepo.IncrUnreadTx 维护。
func (r *MessageRepo) createMessage(
	queryRow func(query string, args ...interface{}) *sql.Row,
	convID, senderType, senderID string, content json.RawMessage,
) (*model.Message, error) {
	m := &model.Message{}
	err := queryRow(
		`INSERT INTO messages (conversation_id, sender_type, sender_id, content)
		 VALUES ($1, $2, $3, $4)
		 RETURNING id, conversation_id, sender_type, sender_id, content, created_at, deleted_at`,
		convID, senderType, senderID, content,
	).Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.CreatedAt, &m.DeletedAt)
	return m, err
}

// ListByConversation 返回会话消息分页列表(newest first)。
// 撤回的消息(deleted_at IS NOT NULL)也返,靠 SanitizeForClient 在 handler 出口
// 把 content 改写为占位,客户端据此渲染"该消息已被撤回"占位卡片。
// 仅过滤该 member 主动隐藏过的消息(per-participant 隐藏,与全局撤回语义区分)。
func (r *MessageRepo) ListByConversation(convID, memberID, memberType string, limit, offset int) ([]model.Message, error) {
	rows, err := r.db.Query(
		`SELECT m.id, m.conversation_id, m.sender_type, m.sender_id, m.content, m.created_at, m.deleted_at
		 FROM messages m
		 WHERE m.conversation_id = $1
		   AND NOT EXISTS (
		     SELECT 1 FROM message_hidden h
		     WHERE h.message_id = m.id AND h.member_id = $2 AND h.member_type = $3
		   )
		 ORDER BY m.created_at DESC LIMIT $4 OFFSET $5`,
		convID, memberID, memberType, limit, offset,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var msgs []model.Message
	for rows.Next() {
		var m model.Message
		if err := rows.Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.CreatedAt, &m.DeletedAt); err != nil {
			return nil, err
		}
		msgs = append(msgs, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return msgs, nil
}

// Get 按 id 查单条消息(不过滤 deleted_at,权限校验需要知道消息是否存在)。
// 不存在返回 (nil, nil)。
func (r *MessageRepo) Get(id string) (*model.Message, error) {
	m := &model.Message{}
	err := r.db.QueryRow(
		`SELECT id, conversation_id, sender_type, sender_id, content, created_at, deleted_at
		 FROM messages WHERE id = $1`,
		id,
	).Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.CreatedAt, &m.DeletedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return m, nil
}

// GetByIDs 批量查询消息(不过滤 deleted_at)。供 BatchDelete 权限校验用。
func (r *MessageRepo) GetByIDs(ids []string) ([]model.Message, error) {
	rows, err := r.db.Query(
		`SELECT id, conversation_id, sender_type, sender_id, content, created_at, deleted_at
		 FROM messages WHERE id = ANY($1)`,
		pq.Array(ids),
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var msgs []model.Message
	for rows.Next() {
		var m model.Message
		if err := rows.Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.CreatedAt, &m.DeletedAt); err != nil {
			return nil, err
		}
		msgs = append(msgs, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return msgs, nil
}

// SoftDelete 软删单条:deleted_at = NOW()。
// 语义见 016 migration 注释:deleted_at 表示"撤回(全局软删)",双向不可见。
// 单向"对自己隐藏"用 HideForUser。
func (r *MessageRepo) SoftDelete(id string) error {
	_, err := r.db.Exec(
		`UPDATE messages SET deleted_at = NOW() WHERE id = $1`,
		id,
	)
	return err
}

// SoftDeleteTx 事务版本:撤回 handler 把 SoftDelete + RecomputeUnreadForConvTx
// 绑同一事务,确保 deleted_at 与 unread_count 原子一致性。
// 调用方负责 Commit/Rollback。
func (r *MessageRepo) SoftDeleteTx(tx *sql.Tx, id string) error {
	_, err := tx.Exec(
		`UPDATE messages SET deleted_at = NOW() WHERE id = $1`,
		id,
	)
	return err
}

// SoftDeleteByIDs 批量软删,返回受影响行数。
func (r *MessageRepo) SoftDeleteByIDs(ids []string) (int64, error) {
	res, err := r.db.Exec(
		`UPDATE messages SET deleted_at = NOW() WHERE id = ANY($1) AND deleted_at IS NULL`,
		pq.Array(ids),
	)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// HideForUser 把单条消息对某 participant 隐藏(per-participant 维度)。
// 重复 hide 幂等(ON CONFLICT DO NOTHING)。语义见 016 migration 注释。
func (r *MessageRepo) HideForUser(messageID, memberID, memberType string) error {
	_, err := r.db.Exec(`
		INSERT INTO message_hidden (message_id, member_id, member_type)
		VALUES ($1, $2, $3)
		ON CONFLICT (message_id, member_id, member_type) DO NOTHING
	`, messageID, memberID, memberType)
	return err
}

// HideForUsers 批量隐藏,返回受影响行数(新增插入数,已隐藏的不计)。
// 用于 batch-delete 的 scope=hide 路径。
func (r *MessageRepo) HideForUsers(messageIDs []string, memberID, memberType string) (int64, error) {
	if len(messageIDs) == 0 {
		return 0, nil
	}
	res, err := r.db.Exec(`
		INSERT INTO message_hidden (message_id, member_id, member_type)
		SELECT unnest($1::uuid[]), $2, $3
		ON CONFLICT (message_id, member_id, member_type) DO NOTHING
	`, pq.Array(messageIDs), memberID, memberType)
	if err != nil {
		return 0, err
	}
	return res.RowsAffected()
}

// LastNonDeleted 返回会话最新一条未删消息。会话已无未删消息时返回 (nil, nil)。
// 供删除后重算 conversations.last_message_content 缓存用。
func (r *MessageRepo) LastNonDeleted(convID string) (*model.Message, error) {
	m := &model.Message{}
	err := r.db.QueryRow(
		`SELECT id, conversation_id, sender_type, sender_id, content, created_at, deleted_at
		 FROM messages WHERE conversation_id = $1 AND deleted_at IS NULL
		 ORDER BY created_at DESC LIMIT 1`,
		convID,
	).Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.CreatedAt, &m.DeletedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return m, nil
}

// ListBefore 返回 created_at < before 的消息(游标分页),newest first。
// before 为零值时返回最新 limit 条(等价 ListByConversation 第一页)。
// 用于消息导航的游标分页加载历史("更老方向",上滑加载)。
// 撤回的消息(deleted_at IS NOT NULL)也返,client 端 SanitizeForClient 渲染占位。
// 仅过滤该 member 主动隐藏过的消息。
//
// 为什么用 created_at 作 cursor:messages.id 是 UUID v4(随机无序),不能作 cursor
// (id < $2 比较无意义),created_at 是本项目唯一可用的时间序字段。同 created_at
// 边界的消息(生产环境同毫秒概率极低)用 `<` 严格小于规避。
func (r *MessageRepo) ListBefore(convID, memberID, memberType string, before time.Time, limit int) ([]model.Message, error) {
	var rows *sql.Rows
	var err error
	if before.IsZero() {
		rows, err = r.db.Query(
			`SELECT m.id, m.conversation_id, m.sender_type, m.sender_id, m.content, m.created_at, m.deleted_at
			 FROM messages m
			 WHERE m.conversation_id = $1
			   AND NOT EXISTS (
			     SELECT 1 FROM message_hidden h
			     WHERE h.message_id = m.id AND h.member_id = $2 AND h.member_type = $3
			   )
			 ORDER BY m.created_at DESC LIMIT $4`,
			convID, memberID, memberType, limit,
		)
	} else {
		rows, err = r.db.Query(
			`SELECT m.id, m.conversation_id, m.sender_type, m.sender_id, m.content, m.created_at, m.deleted_at
			 FROM messages m
			 WHERE m.conversation_id = $1
			   AND NOT EXISTS (
			     SELECT 1 FROM message_hidden h
			     WHERE h.message_id = m.id AND h.member_id = $2 AND h.member_type = $3
			   )
			   AND m.created_at < $4
			 ORDER BY m.created_at DESC LIMIT $5`,
			convID, memberID, memberType, before, limit,
		)
	}
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var msgs []model.Message
	for rows.Next() {
		var m model.Message
		if err := rows.Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.CreatedAt, &m.DeletedAt); err != nil {
			return nil, err
		}
		msgs = append(msgs, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return msgs, nil
}

// CountBefore 返回 created_at < before 的未删 + 未隐藏消息数。
// 用于 APP 进入有未读会话时判断 firstUnread 之前是否还有已读历史,
// 决定 hasMore(是否允许上滑加载历史)。
func (r *MessageRepo) CountBefore(convID, memberID, memberType string, before time.Time) (int, error) {
	var count int
	err := r.db.QueryRow(
		`SELECT COUNT(*) FROM messages m
		 WHERE m.conversation_id = $1 AND m.deleted_at IS NULL AND m.created_at < $2
		   AND NOT EXISTS (
		     SELECT 1 FROM message_hidden h
		     WHERE h.message_id = m.id AND h.member_id = $3 AND h.member_type = $4
		   )`,
		convID, before, memberID, memberType,
	).Scan(&count)
	if err != nil {
		return 0, err
	}
	return count, nil
}

// ListAfter 返回 created_at > after 的消息("未读方向"游标分页),ASC(最老在前)。
// 与 ListBefore(DESC,更老方向)对称,供"进入会话定位第一条未读"场景使用:
// firstUnread + 之后的 N-1 条,让 firstUnread 落在 loaded 开头;APP 端 reverse 后
// 变成 newest first(firstUnread 在末尾=视觉顶部,跳到它,下方是更新的未读)。
//
// 撤回的消息(deleted_at IS NOT NULL)也返,client 端 SanitizeForClient 渲染占位。
// 仅过滤该 member 主动隐藏过的消息。ASC 排序:与 ListBefore 的 DESC 反向,调用方按需 reverse。
func (r *MessageRepo) ListAfter(convID, memberID, memberType string, after time.Time, limit int) ([]model.Message, error) {
	rows, err := r.db.Query(
		`SELECT m.id, m.conversation_id, m.sender_type, m.sender_id, m.content, m.created_at, m.deleted_at
		 FROM messages m
		 WHERE m.conversation_id = $1
		   AND NOT EXISTS (
		     SELECT 1 FROM message_hidden h
		     WHERE h.message_id = m.id AND h.member_id = $2 AND h.member_type = $3
		   )
		   AND m.created_at > $4
		 ORDER BY m.created_at ASC LIMIT $5`,
		convID, memberID, memberType, after, limit,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var msgs []model.Message
	for rows.Next() {
		var m model.Message
		if err := rows.Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.CreatedAt, &m.DeletedAt); err != nil {
			return nil, err
		}
		msgs = append(msgs, m)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return msgs, nil
}
