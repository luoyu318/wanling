package model

import "time"

// AgentStatus 用类型常量集中定义，避免拼写错误、便于 IDE 补全。
// 底层是 string，DB scan / JSON 序列化均按 string 字面值处理。
//
// 注意:agents 表已删除 status 列(002),DB 不再持久化在线状态。
// 实际状态走 Redis presence key(hub.Register SET + 心跳 RefreshTTL 续期,60s TTL),
// agent_handler List/Get 时用 presence.IsOnline 实时算后赋值给 model.Agent.Status。
type AgentStatus string

const (
	AgentStatusOnline  AgentStatus = "online"
	AgentStatusOffline AgentStatus = "offline"
)

// AgentType 用类型常量集中定义 agent 类型标签。
// 底层 string,DB agents.type 列 VARCHAR(32),默认空串。
//
// 两大类(铺垫):
//   - 对话型(Hermes 类): 只看最终文本回复,单会话。
//     新 agent 走配对带 type=hermes;存量空串兼容归此类。
//   - 开发型(OpenCode 类): 多 session + 工具链 + 富 UI 卡片。
//     当前 opencode,Claude Code / Codex 等同类后期接入不再改源码判断。
type AgentType string

const (
	AgentTypeDefault  AgentType = ""         // 普通 agent(默认,存量空串,新版配对已不产生)
	AgentTypeHermes   AgentType = "hermes"   // hermes 对话型 agent(主流 IM 平台适配)
	AgentTypeOpencode AgentType = "opencode" // OpenCode 多 session 开发型 agent
)

type Agent struct {
	ID        string  `json:"id" db:"id"`
	OwnerID   string  `json:"owner_id" db:"owner_id"`
	Name      string  `json:"name" db:"name"`
	AvatarURL string  `json:"avatar_url" db:"avatar_url"`
	Bio       *string `json:"bio" db:"bio"`
	SecretKey string  `json:"-" db:"secret_key"`
	// Status 不映射 DB 列(002 已删),由 handler 用 presence 实时算后赋值。
	Status AgentStatus `json:"status" db:"-"`
	// Type 是 agent 类型标签(hermes 对话型 / opencode 开发型 / 空串 legacy 对话型)。
	// APP 据 type 分支点击路由:opencode → 二级列表页;其它 → 聊天窗。
	Type      AgentType `json:"type,omitempty" db:"type"`
	CreatedAt time.Time `json:"created_at" db:"created_at"`
}

// AgentSummary 是 Agent 的展示型子集，用于 IM 列表等只需要展示信息的场景，
// 不暴露 secret_key / owner_id 等敏感或与展示无关的字段。
type AgentSummary struct {
	ID        string  `json:"id" db:"id"`
	Name      string  `json:"name" db:"name"`
	AvatarURL string  `json:"avatar_url" db:"avatar_url"`
	Bio       *string `json:"bio" db:"bio"`
	// Type 从 Agent 透传(应用层填充,非 DB 列)。供 IM 列表渲染/路由。
	Type      AgentType `json:"type,omitempty" db:"-"`
	CreatedAt time.Time `json:"created_at" db:"created_at"`
	// Status 在线状态(应用层用 hub.GetClient 实时算后赋值,非 DB 列)。
	Status AgentStatus `json:"status" db:"-"`
}

// ModelInfo 描述一个可选模型，由 plugin 上报、APP 用于模型选择器。
// 无 status 字段 — opencode 的 connected 状态目前不可信会断联。
type ModelInfo struct {
	ProviderID   string `json:"provider_id"`
	ProviderName string `json:"provider_name"`
	ModelID      string `json:"model_id"`
	ModelName    string `json:"model_name"`
}

// SlashCommandInfo 描述一条 OC 命令，由 plugin 上报、APP 用于斜杠命令列表。
// Source 区分 OC 命令(command)与 skill(skill)，APP 据此分组渲染。
type SlashCommandInfo struct {
	Name        string `json:"name"`
	Template    string `json:"template"`
	Description string `json:"description,omitempty"`
	Source      string `json:"source"`
}

type RpcMethod struct {
	Name          string `json:"name"`
	TimeoutHintMs int    `json:"timeout_hint_ms"`
}
