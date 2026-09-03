package model

import "time"

// PairingStatus 配对票据状态。底层 string，DB scan / JSON 按 string 处理。
type PairingStatus string

const (
	PairingStatusPending   PairingStatus = "pending"
	PairingStatusScanned   PairingStatus = "scanned"
	PairingStatusCompleted PairingStatus = "completed"
	PairingStatusExpired   PairingStatus = "expired"
)

// PairingTicketTTL 票据有效期。超过即视为 expired（查询时计算，不写 expires_at 列）。
const PairingTicketTTL = 5 * time.Minute

// 配对票据完成动作。bind=接管语义(重置 agent 主密钥) / authorize=授权语义(发子密钥,不动主密钥)。
type PairingAction string

const (
	PairingActionBind      PairingAction = "bind"
	PairingActionAuthorize PairingAction = "authorize"
)

// PairingTicket 对应 pairing_tickets 表。仅握手用，非业务表。
// SecretKey 仅在 status=completed 且未被领取时非空（领取后 repo 清空它）。
// Type 是 plugin 在 CreateTicket 时声明的 agent 类型标签
// (hermes 对话型 / opencode 开发型,默认空串=legacy 对话型),
// CompleteTicket 读它建对应类型的 agent。
type PairingTicket struct {
	ID          string        `json:"-" db:"id"` // 不直接 JSON 暴露（响应里按需显式放）
	Status      PairingStatus `json:"status" db:"status"`
	UserID      *string       `json:"user_id,omitempty" db:"user_id"`
	AgentID     *string       `json:"agent_id,omitempty" db:"agent_id"`
	SecretKey   *string       `json:"-" db:"secret_key"` // 凭据不直接 JSON 暴露，handler 显式取
	Type        string        `json:"-" db:"type"`       // agent 类型标签,不直接 JSON 暴露(handler 透传到 agent)
	Action      PairingAction `json:"-" db:"action"`     // 完成动作,不直接 JSON 暴露(handler 按需显式放)
	CreatedAt   time.Time     `json:"created_at" db:"created_at"`
	ScannedAt   *time.Time    `json:"scanned_at,omitempty" db:"scanned_at"`
	CompletedAt *time.Time    `json:"completed_at,omitempty" db:"completed_at"`
}

// IsExpired 判定票据是否过期（基于 created_at + TTL，不查 DB）。
// 已 completed 的票据不算过期（凭据可能还在等领）。
func (t *PairingTicket) IsExpired() bool {
	if t.Status == PairingStatusCompleted {
		return false
	}
	return time.Since(t.CreatedAt) > PairingTicketTTL
}
