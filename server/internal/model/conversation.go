package model

import (
	"time"
)

// ConversationType 枚举:区分会话形态。
// 用于 conversations.type 字段 + ListForUser 等查询条件。
const (
	ConvTypeDMUserAgent  = "dm_user_agent" // 1-1 user ↔ agent
	ConvTypeDMUserUser   = "dm_user_user"  // 1-1 user ↔ user
	ConvTypeGroupUser    = "group_user"    // 群聊(纯 user)
	ConvTypeGroupMixed   = "group_mixed"   // 群聊(user + agent 混合)
	ConvTypeAgentSession = "agent_session" // opencode 单 session 实例(1 user + 1 agent,多实例,走 CreateTx 不去重)
)

// ParticipantRole 枚举:participant 在会话中的角色。
// 用于 conversation_participants.role 字段。
const (
	RoleOwner  = "owner"  // 会话创建者(唯一,不可被踢)
	RoleAdmin  = "admin"  // 管理员(可踢人/改群信息)
	RoleMember = "member" // 普通成员
)

// MemberType 枚举:participant 的实体类型。
// 用于 conversation_participants.member_type / messages.sender_type / message_deliveries.recipient_type。
const (
	MemberTypeUser  = "user"
	MemberTypeAgent = "agent"
)

// Conversation 表示一次会话(N 方参与者通用模型)。
// Type 区分会话类型:dm_user_user / dm_user_agent / group_user / group_mixed。
// Title/AvatarURL 仅群聊用,1-1 为空字符串。
type Conversation struct {
	ID          string    `json:"id" db:"id"`
	Type        string    `json:"type" db:"type"`
	Title       string    `json:"title,omitempty" db:"title"`
	AvatarURL   string    `json:"avatar_url,omitempty" db:"avatar_url"`
	SessionMeta NullJSON  `json:"session_meta" db:"session_meta"`     // agent_session: {mode, model_id, provider_id, variant, git_branch, tokens.*}(不含 cwd)
	Directory   *string   `json:"directory,omitempty" db:"directory"` // agent_session: OC session 工作目录,创建时固化。nil=用户选默认
	CreatedAt   time.Time `json:"created_at" db:"created_at"`
}

// ConversationListItem 是 IM 风格列表的一行:会话 + 个人维度 unread/pin/hide + 对端摘要。
//   - dm_user_agent 时 Agent 字段填,OtherUser 为 nil
//   - dm_user_user 时 OtherUser 字段填(对方 user),Agent 为 nil
//   - 群聊两者均 nil(UI 走 Title/AvatarURL 或 Participants)
type ConversationListItem struct {
	ID                    string               `json:"id" db:"id"`
	Type                  string               `json:"type" db:"type"`
	Title                 string               `json:"title,omitempty" db:"title"`
	AvatarURL             string               `json:"avatar_url,omitempty" db:"avatar_url"`
	LastMessageContent    NullJSON             `json:"last_message_content" db:"last_message_content"`
	LastMessageAt         time.Time            `json:"last_message_at" db:"last_message_at"`
	LastMessageSenderID   string               `json:"last_message_sender_id,omitempty" db:"last_message_sender_id"`
	LastMessageSenderType string               `json:"last_message_sender_type,omitempty" db:"last_message_sender_type"`
	LastMessageSenderName string               `json:"last_message_sender_name,omitempty" db:"last_message_sender_name"`
	CreatedAt             time.Time            `json:"created_at" db:"created_at"`
	UnreadCount           int                  `json:"unread_count" db:"unread_count"`
	PinnedAt              *time.Time           `json:"pinned_at,omitempty" db:"pinned_at"`
	HiddenAt              *time.Time           `json:"hidden_at,omitempty" db:"hidden_at"`
	Agent                 *AgentSummary        `json:"agent,omitempty" db:"-"`                    // dm_user_agent 才填
	OtherUser             *UserSummary         `json:"other_user,omitempty" db:"-"`               // dm_user_user 才填
	Participants          []ParticipantSummary `json:"participants" db:"-"`                       // 应用层组装
	SessionCount          int                  `json:"session_count,omitempty"`                   // opencode dm 行: agent_session 数量
	PendingCount          int                  `json:"pending_count,omitempty"`                   // opencode dm 行: 待处理交互卡片数
	LastAgentReplyContent string               `json:"last_agent_reply_content,omitempty" db:"-"` // agent_session: agent 最后一条最终回复预览
	SessionMeta           NullJSON             `json:"session_meta" db:"session_meta"`            // agent_session: {mode, model_id, provider_id, variant}
	Directory             *string              `json:"directory,omitempty" db:"directory"`
}
