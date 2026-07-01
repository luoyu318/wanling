package model

import (
	"time"
)

// Conversation 表示一次会话(N 方参与者通用模型)。
// Type 区分会话类型:dm_user_user / dm_user_agent / group_user / group_mixed。
// Title/AvatarURL 仅群聊用,1-1 为空字符串。
type Conversation struct {
	ID                 string    `json:"id" db:"id"`
	Type               string    `json:"type" db:"type"`
	Title              string    `json:"title,omitempty" db:"title"`
	AvatarURL          string    `json:"avatar_url,omitempty" db:"avatar_url"`
	LastMessageContent NullJSON  `json:"last_message_content" db:"last_message_content"`
	LastMessageAt      time.Time `json:"last_message_at" db:"last_message_at"`
	CreatedAt          time.Time `json:"created_at" db:"created_at"`
}

// ConversationListItem 是 IM 风格列表的一行:会话 + 个人维度 unread/pin/hide + 对端摘要。
// 1-1 dm_user_agent 时 Agent 字段填,其他 type 为 nil(UI 走 Title/AvatarURL)。
type ConversationListItem struct {
	ID                 string              `json:"id" db:"id"`
	Type               string              `json:"type" db:"type"`
	Title              string              `json:"title,omitempty" db:"title"`
	AvatarURL          string              `json:"avatar_url,omitempty" db:"avatar_url"`
	LastMessageContent NullJSON            `json:"last_message_content" db:"last_message_content"`
	LastMessageAt      time.Time           `json:"last_message_at" db:"last_message_at"`
	CreatedAt          time.Time           `json:"created_at" db:"created_at"`
	UnreadCount        int                 `json:"unread_count" db:"unread_count"`
	PinnedAt           *time.Time          `json:"pinned_at,omitempty" db:"pinned_at"`
	HiddenAt           *time.Time          `json:"hidden_at,omitempty" db:"hidden_at"`
	Agent              *AgentSummary       `json:"agent,omitempty" db:"-"` // dm_user_agent 才填
	Participants       []ParticipantSummary `json:"participants" db:"-"`    // 应用层组装
}
