package repository

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"

	"github.com/lib/pq"
	"github.com/wanling/server/internal/model"
)

type ConversationRepo struct {
	db *sql.DB
}

func NewConversationRepo(db *sql.DB) *ConversationRepo {
	return &ConversationRepo{db: db}
}

// FindOrCreate 按 (user_id, agent_id) 唯一约束获取会话；不存在则创建。
// last_message_content 在新建时为 NULL（无消息），scan 到 json.RawMessage 得到 nil 切片。
//
// 实现细节：用 ON CONFLICT DO NOTHING + RETURNING。
// - 新插入：RETURNING 返回新行，1 次 roundtrip。
// - 已存在：DO NOTHING 让 RETURNING 不返回任何行（sql.ErrNoRows），此时二次 SELECT。
//
// 关键 WHY：之前的实现用 `DO UPDATE SET last_message_at = NOW()`，会让"再次打开已有
// 空会话"也污染 last_message_at（无新消息却更新时间戳）。虽然 IM 列表当前用
// `WHERE last_message_content IS NOT NULL` 过滤掉空会话，但该无意义更新仍可能干扰排序。
// 改用 DO NOTHING 保持原 last_message_at，逻辑更纯。
func (r *ConversationRepo) FindOrCreate(userID, agentID string) (*model.Conversation, error) {
	c := &model.Conversation{}
	err := r.db.QueryRow(
		`INSERT INTO conversations (user_id, agent_id)
		 VALUES ($1, $2)
		 ON CONFLICT (user_id, agent_id) DO NOTHING
		 RETURNING id, user_id, agent_id, last_message_content, last_message_at, created_at`,
		userID, agentID,
	).Scan(&c.ID, &c.UserID, &c.AgentID, &c.LastMessageContent, &c.LastMessageAt, &c.CreatedAt)
	if err == nil {
		return c, nil // 新插入
	}
	if errors.Is(err, sql.ErrNoRows) {
		return r.findByUserAndAgent(userID, agentID)
	}
	return nil, err
}

// findByUserAndAgent 命中已存在会话时的二次 SELECT。私有，仅 FindOrCreate 调用。
// 同时取消隐藏(hidden_at = NULL):用户发消息表示重新激活该会话。
func (r *ConversationRepo) findByUserAndAgent(userID, agentID string) (*model.Conversation, error) {
	c := &model.Conversation{}
	err := r.db.QueryRow(
		`SELECT id, user_id, agent_id, last_message_content, last_message_at, created_at
		 FROM conversations WHERE user_id = $1 AND agent_id = $2`,
		userID, agentID,
	).Scan(&c.ID, &c.UserID, &c.AgentID, &c.LastMessageContent, &c.LastMessageAt, &c.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		// 理论上不会发生：DO NOTHING 后该行必然存在。
		// 出现即并发删除或唯一约束被改，按 fail-fast 暴露。
		return nil, err
	}
	if err != nil {
		return nil, err
	}
	// 取消隐藏:用户发消息 = 重新激活会话。pinned_at 不动(置顶状态保持)。
	_, _ = r.db.Exec(
		`UPDATE conversations SET hidden_at = NULL WHERE id = $1`,
		c.ID,
	)
	return c, nil
}

// ListByUser 按最近消息时间倒序返回该用户所有会话。
// SQL 字段顺序与 Scan 顺序必须一致（last_message_content 在 last_message_at 之前）。
func (r *ConversationRepo) ListByUser(userID string) ([]model.Conversation, error) {
	rows, err := r.db.Query(
		`SELECT id, user_id, agent_id, last_message_content, last_message_at, created_at
		 FROM conversations WHERE user_id = $1 ORDER BY last_message_at DESC`,
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var convos []model.Conversation
	for rows.Next() {
		var c model.Conversation
		if err := rows.Scan(&c.ID, &c.UserID, &c.AgentID, &c.LastMessageContent, &c.LastMessageAt, &c.CreatedAt); err != nil {
			return nil, err
		}
		convos = append(convos, c)
	}
	return convos, nil
}

// GetByID 返回单个会话；不存在时 (nil, nil)。
func (r *ConversationRepo) GetByID(id string) (*model.Conversation, error) {
	c := &model.Conversation{}
	err := r.db.QueryRow(
		`SELECT id, user_id, agent_id, last_message_content, last_message_at, created_at FROM conversations WHERE id = $1`,
		id,
	).Scan(&c.ID, &c.UserID, &c.AgentID, &c.LastMessageContent, &c.LastMessageAt, &c.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	return c, err
}

// ListWithAgent 列出用户所有有消息且未隐藏的会话（IM 风格列表）。
// 过滤:hidden_at IS NULL(软删除不显示) + last_message_content IS NOT NULL(无消息不进列表)。
// 排序:置顶组在前(pinned_at IS NOT NULL DESC),组内按 last_message_at DESC。
// SELECT 不含 a.secret_key / a.owner_id：IM 列表无需敏感字段，避免泄漏。
// Scan 顺序与 SELECT 列顺序严格一致：
//  1. c.id, c.last_message_content, c.last_message_at, c.created_at, c.unread_count, (pinned_at IS NOT NULL) is_pinned
//  2. a.id, a.name, a.avatar_url, a.bio, a.status, a.created_at
func (r *ConversationRepo) ListWithAgent(userID string) ([]model.ConversationListItem, error) {
	rows, err := r.db.Query(
		`SELECT c.id, c.last_message_content, c.last_message_at, c.created_at, c.unread_count,
		        (c.pinned_at IS NOT NULL) AS is_pinned,
		        a.id, a.name, a.avatar_url, a.bio, a.status, a.created_at
		 FROM conversations c
		 JOIN agents a ON a.id = c.agent_id
		 WHERE c.user_id = $1 AND c.last_message_content IS NOT NULL AND c.hidden_at IS NULL
		 ORDER BY (c.pinned_at IS NOT NULL) DESC, c.last_message_at DESC`,
		userID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var items []model.ConversationListItem
	for rows.Next() {
		var item model.ConversationListItem
		if err := rows.Scan(
			&item.ID, &item.LastMessageContent, &item.LastMessageAt, &item.CreatedAt, &item.UnreadCount,
			&item.IsPinned,
			&item.Agent.ID, &item.Agent.Name, &item.Agent.AvatarURL, &item.Agent.Bio, &item.Agent.Status, &item.Agent.CreatedAt,
		); err != nil {
			return nil, err
		}
		items = append(items, item)
	}
	// rows.Err 处理迭代过程中的错误（DB 连接断开等）
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return items, nil
}

// UpdateLastMessage 在消息持久化后调用，更新会话的 last_message_content 与 last_message_at。
// 写入时间用 NOW()（数据库时间），避免应用服务器时钟不一致。
// content 是消息的完整 JSON（含 msg_type/data 字段）。
func (r *ConversationRepo) UpdateLastMessage(convID string, content json.RawMessage) error {
	_, err := r.db.Exec(
		`UPDATE conversations SET last_message_content = $1, last_message_at = NOW() WHERE id = $2`,
		[]byte(content), convID,
	)
	return err
}

// ClearLastMessage 把会话的 last_message_content 置 NULL。
// 用于消息全删完后清空缓存(避免 IM 列表显示已不存在的最后一条消息)。
// 不更新 last_message_at(保留原时间戳,语义上该会话仍存在,只是无消息)。
func (r *ConversationRepo) ClearLastMessage(convID string) error {
	_, err := r.db.Exec(
		`UPDATE conversations SET last_message_content = NULL WHERE id = $1`,
		convID,
	)
	return err
}

// BeginTx 启动一个事务，供 MessageProcessor 在事务内同时写消息 + 更新缓存。
func (r *ConversationRepo) BeginTx() (*sql.Tx, error) {
	return r.db.Begin()
}

// UpdateLastMessageTx 与 UpdateLastMessage 行为一致，但在外部事务中执行。
// 调用方负责 Commit/Rollback。用于保证"写消息 + 更新缓存"的原子性。
func (r *ConversationRepo) UpdateLastMessageTx(tx *sql.Tx, convID string, content json.RawMessage) error {
	_, err := tx.Exec(
		`UPDATE conversations SET last_message_content = $1, last_message_at = NOW() WHERE id = $2`,
		[]byte(content), convID,
	)
	return err
}

// IncrUnreadTx 在外部事务内把会话 unread_count++ 并取消隐藏。
// 调用方（MessageProcessor）负责 Commit。
// agent → user 方向调用:新消息来时会话自动恢复显示(即使之前被用户软删除)。
func (r *ConversationRepo) IncrUnreadTx(tx *sql.Tx, convID string) error {
	_, err := tx.Exec(
		`UPDATE conversations
		 SET unread_count = unread_count + 1, hidden_at = NULL
		 WHERE id = $1`,
		convID,
	)
	return err
}

// MarkRead 把指定会话的 unread_count 重置为 0。
// 同时把该会话所有未读消息的 is_read 置 TRUE。
// user_id 校验防越权：其他用户调本接口返回 sql.ErrNoRows。
func (r *ConversationRepo) MarkRead(convID, userID string) error {
	res, err := r.db.Exec(
		`UPDATE conversations SET unread_count = 0 WHERE id = $1 AND user_id = $2`,
		convID, userID,
	)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return sql.ErrNoRows
	}
	// 同步标记消息已读（best effort，失败不致命）
	_, _ = r.db.Exec(
		`UPDATE messages SET is_read = TRUE WHERE conversation_id = $1 AND is_read = FALSE`,
		convID,
	)
	return nil
}

// MarkMessagesRead 批量按 messageId 标记已读，并重算会话 unread_count。
// 用于"用户上滑阅读未读消息时按 messageId 同步进度"。
//
// 事务保证：
//  1. UPDATE messages SET is_read=TRUE WHERE id IN(...) AND conversation_id AND sender_type='agent'
//  2. 重算 unread_count = 该会话 remaining 未读 agent 消息数（含 deleted_at IS NULL 过滤）
//  3. UPDATE conversations SET unread_count=$new WHERE id AND user_id（越权 0 行 → ErrNoRows）
//
// 越权防护：conversation_id 必须属于该 user（UPDATE conversations 的 user_id 校验 + 空 ID 分支的 SELECT 校验）。
// messageIDs 中不属于该会话的 id 自动被 WHERE 过滤（不报错，幂等）。
// 空 messageIDs 直接 SELECT 当前 unread_count，不执行 UPDATE（防御性，避免 IN () 语法错）。
//
// 返回新的 unread_count 供调用方同步本地。会话不存在或越权时返回 sql.ErrNoRows。
func (r *ConversationRepo) MarkMessagesRead(convID, userID string, messageIDs []string) (int, error) {
	tx, err := r.db.BeginTx(context.Background(), nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback() // commit 后 noop

	// 空 messageIDs：直接返回当前 unread_count（防御性，避免 ANY($1::text[]) 空 array 语义歧义）
	// SELECT 带 user_id 校验，越权同样返 sql.ErrNoRows
	if len(messageIDs) == 0 {
		var current int
		err = tx.QueryRow(
			`SELECT unread_count FROM conversations WHERE id = $1 AND user_id = $2`,
			convID, userID,
		).Scan(&current)
		if err != nil {
			return 0, err
		}
		if err := tx.Commit(); err != nil {
			return 0, err
		}
		return current, nil
	}

	// 1. 批量标记消息已读（只标记该会话的 agent 消息，防越权 + 防误标 user 消息）
	// messages.id 是 UUID 类型，必须 cast 成 uuid[]（text[] 会触发 "operator does not exist: uuid = text"）
	// 用 ANY($1::uuid[]) 比 IN (...) 更适合动态数组（lib/pq Array 编码）
	_, err = tx.Exec(
		`UPDATE messages SET is_read = TRUE
		 WHERE id = ANY($1::uuid[])
		   AND conversation_id = $2
		   AND sender_type = 'agent'
		   AND is_read = FALSE`,
		pq.Array(messageIDs), convID,
	)
	if err != nil {
		return 0, err
	}

	// 2. 重算 unread_count：该会话 remaining 未读 agent 消息数
	// deleted_at IS NULL 过滤软删的（migration 006）
	var newUnread int
	err = tx.QueryRow(
		`SELECT COUNT(*) FROM messages
		 WHERE conversation_id = $1
		   AND sender_type = 'agent'
		   AND is_read = FALSE
		   AND deleted_at IS NULL`,
		convID,
	).Scan(&newUnread)
	if err != nil {
		return 0, err
	}

	// 3. 更新 conversations.unread_count（带 user_id 校验防越权）
	// 0 行 = 会话不存在或不属于该 user → ErrNoRows（让 handler 返 404）
	convRes, err := tx.Exec(
		`UPDATE conversations SET unread_count = $3
		 WHERE id = $1 AND user_id = $2`,
		convID, userID, newUnread,
	)
	if err != nil {
		return 0, err
	}
	convRows, err := convRes.RowsAffected()
	if err != nil {
		return 0, err
	}
	if convRows == 0 {
		return 0, sql.ErrNoRows
	}

	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return newUnread, nil
}

// GetUnreadCount 返回会话的未读数。带 user_id 校验，越权返回 sql.ErrNoRows。
// 单独提供是因为 model.Conversation 没有 UnreadCount 字段，GetByID 拿不到该值。
// 供 UnreadInfo handler 使用。
func (r *ConversationRepo) GetUnreadCount(convID, userID string) (int, error) {
	var count int
	err := r.db.QueryRow(
		`SELECT unread_count FROM conversations WHERE id = $1 AND user_id = $2`,
		convID, userID,
	).Scan(&count)
	return count, err
}

// Pin 把会话置顶。user_id 校验防越权:他人会话返回 sql.ErrNoRows。
func (r *ConversationRepo) Pin(convID, userID string) error {
	res, err := r.db.Exec(
		`UPDATE conversations SET pinned_at = NOW() WHERE id = $1 AND user_id = $2`,
		convID, userID,
	)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return sql.ErrNoRows
	}
	return nil
}

// Unpin 取消置顶。幂等:重复取消也会 affect 1 行(覆盖 NULL 为 NULL)。
func (r *ConversationRepo) Unpin(convID, userID string) error {
	res, err := r.db.Exec(
		`UPDATE conversations SET pinned_at = NULL WHERE id = $1 AND user_id = $2`,
		convID, userID,
	)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return sql.ErrNoRows
	}
	return nil
}

// Hide 软删除会话:hidden_at = NOW()。聊天记录保留,新消息来时 IncrUnreadTx 自动取消隐藏。
func (r *ConversationRepo) Hide(convID, userID string) error {
	res, err := r.db.Exec(
		`UPDATE conversations SET hidden_at = NOW() WHERE id = $1 AND user_id = $2`,
		convID, userID,
	)
	if err != nil {
		return err
	}
	rows, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if rows == 0 {
		return sql.ErrNoRows
	}
	return nil
}
