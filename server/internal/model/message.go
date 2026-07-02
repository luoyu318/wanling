package model

import (
	"database/sql"
	"encoding/json"
	"time"
)

// MsgType 集中定义消息类型常量。msg_type 存在消息 content JSONB 内，
// 不是 Message 结构体字段；这里常量供构造 / 校验时引用。
type MsgType string

const (
	MsgTypeText     MsgType = "text"
	MsgTypeMarkdown MsgType = "markdown"
	MsgTypeImage    MsgType = "image"
	MsgTypeFile     MsgType = "file"
	MsgTypeMixed    MsgType = "mixed"
	MsgTypeCard     MsgType = "card"
)

type Message struct {
	ID             string          `json:"id" db:"id"`
	ConversationID string          `json:"conversation_id" db:"conversation_id"`
	SenderType     string          `json:"sender_type" db:"sender_type"`
	SenderID       string          `json:"sender_id" db:"sender_id"`
	Content        json.RawMessage `json:"content" db:"content"`
	CreatedAt      time.Time       `json:"created_at" db:"created_at"`
	// DeletedAt 标记撤回时间(全局软删),DB 完整保留原 Content 用于审计。
	// 通过 SanitizeForClient 在 API 出口处把 Content 改写为占位 {"msg_type":"recalled"},
	// 避免原文泄漏。json:"-" 不直接序列化字段本身。
	DeletedAt sql.NullTime `json:"-"`
}

// SanitizeForClient 把撤回消息(DeletedAt.Valid)的 Content 改写为占位
// {"msg_type":"recalled","data":{}}。
//
// DB 保留原 Content 用于审计,只在 API 出口处覆写,避免泄漏原文。
// 内部逻辑(权限校验、撤回时限判断等)应直接读原始 Message,不调本方法。
//
// 调用点:ConversationHandler.Messages (c.JSON 前对每条消息调)。
func (m *Message) SanitizeForClient() {
	if !m.DeletedAt.Valid {
		return
	}
	m.Content = json.RawMessage(`{"msg_type":"recalled","data":{}}`)
}

type MessageContent struct {
	MsgType MsgType         `json:"msg_type"`
	Data    json.RawMessage `json:"data"`
}

type TextData struct {
	Text string `json:"text"`
}

type FileRefData struct {
	FileID string `json:"file_id"`
}
