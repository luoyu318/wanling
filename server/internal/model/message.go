package model

import (
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
)

type Message struct {
	ID             string          `json:"id" db:"id"`
	ConversationID string          `json:"conversation_id" db:"conversation_id"`
	SenderType     string          `json:"sender_type" db:"sender_type"`
	SenderID       string          `json:"sender_id" db:"sender_id"`
	Content        json.RawMessage `json:"content" db:"content"`
	CreatedAt      time.Time       `json:"created_at" db:"created_at"`
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
