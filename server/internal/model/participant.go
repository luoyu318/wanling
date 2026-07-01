package model

import "time"

// ConversationParticipant 表示会话的一个参与者。
// conv_id + member_id + member_type 是复合主键(member_id 多态关联 user 或 agent)。
type ConversationParticipant struct {
	ConvID            string     `json:"conv_id" db:"conv_id"`
	MemberID          string     `json:"member_id" db:"member_id"`
	MemberType        string     `json:"member_type" db:"member_type"` // user / agent
	Role              string     `json:"role" db:"role"`                // owner / admin / member
	UnreadCount       int        `json:"unread_count" db:"unread_count"`
	LastReadMessageID *string    `json:"last_read_message_id,omitempty" db:"last_read_message_id"`
	JoinedAt          time.Time  `json:"joined_at" db:"joined_at"`
	HiddenAt          *time.Time `json:"hidden_at,omitempty" db:"hidden_at"`
	PinnedAt          *time.Time `json:"pinned_at,omitempty" db:"pinned_at"`
}

// ParticipantSummary 是会话详情 / IM 列表里渲染用的摘要(带 username/nickname/avatar)。
type ParticipantSummary struct {
	MemberID   string `json:"member_id" db:"member_id"`
	MemberType string `json:"member_type" db:"member_type"`
	Role       string `json:"role" db:"role"`
	Username   string `json:"username" db:"username"`
	Nickname   string `json:"nickname" db:"nickname"`
	AvatarURL  string `json:"avatar_url" db:"avatar_url"`
}
