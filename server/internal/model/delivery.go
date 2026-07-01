package model

import "time"

// MessageDelivery 表示一条消息对某个 recipient 的投递状态。
// read_at 为 NULL 表示未读。
type MessageDelivery struct {
	MessageID     string     `json:"message_id" db:"message_id"`
	RecipientID   string     `json:"recipient_id" db:"recipient_id"`
	RecipientType string     `json:"recipient_type" db:"recipient_type"`
	ReadAt        *time.Time `json:"read_at,omitempty" db:"read_at"`
}
