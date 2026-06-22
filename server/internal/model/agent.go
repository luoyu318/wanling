package model

import "time"

// AgentStatus 用类型常量集中定义，避免拼写错误、便于 IDE 补全。
// 底层是 string，DB scan / JSON 序列化均按 string 字面量处理。
type AgentStatus string

const (
	AgentStatusOnline  AgentStatus = "online"
	AgentStatusOffline AgentStatus = "offline"
)

type Agent struct {
	ID        string      `json:"id" db:"id"`
	OwnerID   string      `json:"owner_id" db:"owner_id"`
	Name      string      `json:"name" db:"name"`
	AvatarURL string      `json:"avatar_url" db:"avatar_url"`
	Bio       *string     `json:"bio" db:"bio"`
	SecretKey string      `json:"secret_key,omitempty" db:"secret_key"`
	Status    AgentStatus `json:"status" db:"status"`
	CreatedAt time.Time   `json:"created_at" db:"created_at"`
}

// AgentSummary 是 Agent 的展示型子集，用于 IM 列表等只需要展示信息的场景，
// 不暴露 secret_key / owner_id 等敏感或与展示无关的字段。
type AgentSummary struct {
	ID        string      `json:"id" db:"id"`
	Name      string      `json:"name" db:"name"`
	AvatarURL string      `json:"avatar_url" db:"avatar_url"`
	Bio       *string     `json:"bio" db:"bio"`
	Status    AgentStatus `json:"status" db:"status"`
	CreatedAt time.Time   `json:"created_at" db:"created_at"`
}
