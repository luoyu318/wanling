package model

import "time"

type User struct {
	ID           string    `json:"id" db:"id"`
	Username     string    `json:"username" db:"username"`
	Nickname     *string   `json:"nickname" db:"nickname"`
	Bio          *string   `json:"bio" db:"bio"`
	PasswordHash string    `json:"-" db:"password_hash"`
	AvatarURL    string    `json:"avatar_url" db:"avatar_url"`
	CreatedAt    time.Time `json:"created_at" db:"created_at"`
}

// UserSummary 是用户展示型子集,用于会话 participant 摘要 / 好友搜索结果等场景。
// 故意不含 ID 字段:搜索接口返给客户端时不希望泄漏 user_id(防枚举);
// 内部需要 user_id 的场景(如 FindOrCreateDM)由 handler/repo 直接用完整 User。
//
// 注意:UserSummary 与 ParticipantSummary 不同 —— 后者是「会话成员视角」
// 带 member_id,前者是「全局用户搜索结果视角」不带 id。
//
// Nickname/AvatarURL 由调用方决定是否填充(nickname 可能为 nil,客户端按需 fallback)。
type UserSummary struct {
	Username  string  `json:"username" db:"username"`
	Nickname  *string `json:"nickname,omitempty" db:"nickname"`
	AvatarURL string  `json:"avatar_url" db:"avatar_url"`
}
