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

// PairingTicket 对应 pairing_tickets 表。仅握手用，非业务表。
// SecretKey 仅在 status=completed 且未被领取时非空（领取后 repo 清空它）。
type PairingTicket struct {
	ID          string        `json:"-" db:"id"`              // 不直接 JSON 暴露（响应里按需显式放）
	Status      PairingStatus `json:"status" db:"status"`
	UserID      *string       `json:"user_id,omitempty" db:"user_id"`
	AgentID     *string       `json:"agent_id,omitempty" db:"agent_id"`
	SecretKey   *string       `json:"-" db:"secret_key"`      // 凭据不直接 JSON 暴露，handler 显式取
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
