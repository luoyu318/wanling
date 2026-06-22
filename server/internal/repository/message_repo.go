package repository

import (
	"database/sql"
	"encoding/json"
	"errors"

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

// CreateTx 在外部事务中创建消息，供 MessageProcessor 与缓存更新原子化提交使用。
// 调用方负责 Begin/Commit/Rollback；本方法只 INSERT + RETURNING。
func (r *MessageRepo) CreateTx(tx *sql.Tx, convID, senderType, senderID string, content json.RawMessage) (*model.Message, error) {
	return r.createMessage(tx.QueryRow, convID, senderType, senderID, content)
}

// createMessage 是 Create / CreateTx 的公共实现，用闭包接收 QueryRow 能力。
// *sql.DB 和 *sql.Tx 的 QueryRow 方法签名相同，闭包方案比 interface 更轻量。
func (r *MessageRepo) createMessage(
	queryRow func(query string, args ...interface{}) *sql.Row,
	convID, senderType, senderID string, content json.RawMessage,
) (*model.Message, error) {
	m := &model.Message{}
	err := queryRow(
		`INSERT INTO messages (conversation_id, sender_type, sender_id, content)
		 VALUES ($1, $2, $3, $4)
		 RETURNING id, conversation_id, sender_type, sender_id, content, created_at`,
		convID, senderType, senderID, content,
	).Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.CreatedAt)
	return m, err
}

func (r *MessageRepo) ListByConversation(convID string, limit, offset int) ([]model.Message, error) {
	rows, err := r.db.Query(
		`SELECT id, conversation_id, sender_type, sender_id, content, created_at
		 FROM messages WHERE conversation_id = $1 AND deleted_at IS NULL
		 ORDER BY created_at DESC LIMIT $2 OFFSET $3`,
		convID, limit, offset,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var msgs []model.Message
	for rows.Next() {
		var m model.Message
		if err := rows.Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.CreatedAt); err != nil {
			return nil, err
		}
		msgs = append(msgs, m)
	}
	// rows.Err 捕获迭代过程中的错误（DB 连接断开等），避免静默返回部分结果。
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return msgs, nil
}

// Get 按 id 查单条消息（不过滤 deleted_at,权限校验需要知道消息是否存在）。
// 不存在返回 (nil, nil)。
func (r *MessageRepo) Get(id string) (*model.Message, error) {
	m := &model.Message{}
	err := r.db.QueryRow(
		`SELECT id, conversation_id, sender_type, sender_id, content, created_at
		 FROM messages WHERE id = $1`,
		id,
	).Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return m, nil
}

// GetByIDs 批量查询消息（不过滤 deleted_at）。供 BatchDelete 权限校验用。
func (r *MessageRepo) GetByIDs(ids []string) ([]model.Message, error) {
	rows, err := r.db.Query(
		`SELECT id, conversation_id, sender_type, sender_id, content, created_at
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
		if err := rows.Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.CreatedAt); err != nil {
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
func (r *MessageRepo) SoftDelete(id string) error {
	_, err := r.db.Exec(
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

// LastNonDeleted 返回会话最新一条未删消息。会话已无未删消息时返回 (nil, nil)。
// 供删除后重算 conversations.last_message_content 缓存用。
func (r *MessageRepo) LastNonDeleted(convID string) (*model.Message, error) {
	m := &model.Message{}
	err := r.db.QueryRow(
		`SELECT id, conversation_id, sender_type, sender_id, content, created_at
		 FROM messages WHERE conversation_id = $1 AND deleted_at IS NULL
		 ORDER BY created_at DESC LIMIT 1`,
		convID,
	).Scan(&m.ID, &m.ConversationID, &m.SenderType, &m.SenderID, &m.Content, &m.CreatedAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return m, nil
}
