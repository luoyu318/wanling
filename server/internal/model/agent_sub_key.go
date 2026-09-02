package model

import "time"

// AgentSubKey 对应 agent_sub_keys 表:agent 的受限子密钥(wlsk_ 前缀,REST-only 授权)。
// SecretKey 是凭据,JSON 序列化永不暴露(handler 按需显式取)。
// RevokedAt 非空 = 已吊销;GetByKey 含已吊销记录也返回,由调用方判 RevokedAt。
type AgentSubKey struct {
	ID         string     `json:"id" db:"id"`
	AgentID    string     `json:"agent_id" db:"agent_id"`
	Name       string     `json:"name" db:"name"`
	SecretKey  string     `json:"-" db:"secret_key"`
	CreatedAt  time.Time  `json:"created_at" db:"created_at"`
	LastUsedAt *time.Time `json:"last_used_at,omitempty" db:"last_used_at"`
	RevokedAt  *time.Time `json:"revoked_at,omitempty" db:"revoked_at"`
}
