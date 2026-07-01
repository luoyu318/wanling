package model

import "time"

// Friendship 表示 user → user 的好友关系。
// 单向存储 + 应用层校验双向(A→B 后 B→A 拒绝)。
type Friendship struct {
	ID          string     `json:"id" db:"id"`
	UserID      string     `json:"user_id" db:"user_id"`       // 发起方
	FriendID    string     `json:"friend_id" db:"friend_id"`   // 接收方
	Status      string     `json:"status" db:"status"`         // pending / accepted / rejected / canceled
	CreatedAt   time.Time  `json:"created_at" db:"created_at"`
	RespondedAt *time.Time `json:"responded_at,omitempty" db:"responded_at"`
}
