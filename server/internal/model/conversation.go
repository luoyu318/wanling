package model

import (
	"time"
)

// Conversation 表示一次用户与 Agent 的会话。
// LastMessageContent 缓存最近一条消息的 JSON 内容，用于列表页渲染（避免 JOIN messages）。
// 数据库中该列可空（NULL），用 NullJSON 包装以正确处理 scan NULL 与 JSON 序列化。
type Conversation struct {
	ID                 string    `json:"id" db:"id"`
	UserID             string    `json:"user_id" db:"user_id"`
	AgentID            string    `json:"agent_id" db:"agent_id"`
	LastMessageContent NullJSON  `json:"last_message_content" db:"last_message_content"`
	LastMessageAt      time.Time `json:"last_message_at" db:"last_message_at"`
	CreatedAt          time.Time `json:"created_at" db:"created_at"`
}

// ConversationListItem 是 IM 风格列表的一行：会话 + 对端 Agent 摘要 + 最后一条消息预览。
// 通过 ListWithAgent 在 SQL 层 JOIN agents 表得到，避免 N+1 查询。
// 仅列出 last_message_content IS NOT NULL 的会话（无消息的不进 IM 列表）。
// Agent 用 [AgentSummary]：IM 列表无需 secret_key / owner_id，避免敏感字段泄漏到客户端。
type ConversationListItem struct {
	ID                 string       `json:"id" db:"id"`
	Agent              AgentSummary `json:"agent"`
	LastMessageContent NullJSON     `json:"last_message_content" db:"last_message_content"`
	LastMessageAt      time.Time    `json:"last_message_at" db:"last_message_at"`
	CreatedAt          time.Time    `json:"created_at" db:"created_at"`
	UnreadCount        int          `json:"unread_count" db:"unread_count"`
	IsPinned           bool         `json:"is_pinned" db:"is_pinned"`
}
