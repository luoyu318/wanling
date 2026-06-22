package repository

import (
	"testing"

	"golang.org/x/crypto/bcrypt"
)

// TestUserRepo_UpdatePassword_UpdatesHashAndAffectsLogin 验证 UpdatePassword 把
// 数据库里的 password_hash 替换成新值（用 bcrypt 验证）。
func TestUserRepo_UpdatePassword_UpdatesHashAndAffectsLogin(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewUserRepo(db)

	// 建一个初始用户，密码 "oldpw"
	oldHash, err := bcrypt.GenerateFromPassword([]byte("oldpw"), bcrypt.DefaultCost)
	if err != nil {
		t.Fatalf("hash oldpw: %v", err)
	}
	user, err := repo.Create(uniqueShortName(t, "upw_"), string(oldHash))
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	// 改成 "newpw"
	newHash, err := bcrypt.GenerateFromPassword([]byte("newpw"), bcrypt.DefaultCost)
	if err != nil {
		t.Fatalf("hash newpw: %v", err)
	}
	if err := repo.UpdatePassword(user.ID, string(newHash)); err != nil {
		t.Fatalf("UpdatePassword: %v", err)
	}

	// 重新查
	reloaded, err := repo.GetByID(user.ID)
	if err != nil || reloaded == nil {
		t.Fatalf("GetByID after update: %v %v", reloaded, err)
	}
	// 旧密码应失败
	if bcrypt.CompareHashAndPassword([]byte(reloaded.PasswordHash), []byte("oldpw")) == nil {
		t.Errorf("旧密码仍可登录，UpdatePassword 没生效")
	}
	// 新密码应通过
	if err := bcrypt.CompareHashAndPassword([]byte(reloaded.PasswordHash), []byte("newpw")); err != nil {
		t.Errorf("新密码登录失败: %v", err)
	}
}

// TestUserRepo_Update_ReturnsErrorOnMissingUser 验证用户不存在时返回非 nil err
// （而不是静默成功），让 handler 能正确返 404。
func TestUserRepo_UpdatePassword_ReturnsErrorOnMissingUser(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewUserRepo(db)
	err := repo.UpdatePassword("00000000-0000-0000-0000-000000000000", "anyhash")
	if err == nil {
		t.Errorf("期望 err，实际 nil（用户不存在时不应静默成功）")
	}
}

// TestUserRepo_Update_PartialFieldsOnlyUpdatesProvided 验证部分更新语义：
// 只传 nickname 不传 bio，bio 应保持原值不变。
func TestUserRepo_Update_PartialFieldsOnlyUpdatesProvided(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewUserRepo(db)
	user, err := repo.Create(uniqueShortName(t, "upd_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	// 初始 bio 设成 "初始简介"
	oldBio := "初始简介"
	_, err = db.Exec(`UPDATE users SET bio = $1 WHERE id = $2`, oldBio, user.ID)
	if err != nil {
		t.Fatalf("set initial bio: %v", err)
	}

	// 只更新 nickname，bio=nil 表示不动
	newNick := "新昵称"
	reloaded, err := repo.Update(user.ID, UpdateUserParams{Nickname: &newNick})
	if err != nil {
		t.Fatalf("Update: %v", err)
	}
	if reloaded == nil {
		t.Fatalf("Update 返回 nil user")
	}
	if reloaded.Nickname == nil || *reloaded.Nickname != "新昵称" {
		t.Errorf("nickname 应为 新昵称，实际: %v", reloaded.Nickname)
	}
	if reloaded.Bio == nil || *reloaded.Bio != oldBio {
		t.Errorf("bio 应保持 %s 不变，实际: %v", oldBio, reloaded.Bio)
	}
}

// TestUserRepo_Update_EmptyStringClearsField 验证传空串指针能清空字段。
func TestUserRepo_Update_EmptyStringClearsField(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewUserRepo(db)
	user, err := repo.Create(uniqueShortName(t, "clr_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	// 先设 bio 有值
	oldBio := "有值"
	_, _ = db.Exec(`UPDATE users SET bio = $1 WHERE id = $2`, oldBio, user.ID)

	// 传空串指针清空 bio
	emptyBio := ""
	reloaded, err := repo.Update(user.ID, UpdateUserParams{Bio: &emptyBio})
	if err != nil {
		t.Fatalf("Update: %v", err)
	}
	if reloaded.Bio != nil && *reloaded.Bio != "" {
		t.Errorf("bio 应被清空（nil 或空串），实际: %v", reloaded.Bio)
	}
}

// TestUserRepo_Update_AvatarEmptyStringIgnored 验证 avatar_url 传空串被忽略（不清空）。
func TestUserRepo_Update_AvatarEmptyStringIgnored(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewUserRepo(db)
	user, err := repo.Create(uniqueShortName(t, "ava_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	// 先设 avatar_url 有值
	oldAvatar := "/api/files/old"
	_, _ = db.Exec(`UPDATE users SET avatar_url = $1 WHERE id = $2`, oldAvatar, user.ID)

	// 传空串 avatar（应被忽略，保持原值）
	reloaded, err := repo.Update(user.ID, UpdateUserParams{AvatarURL: ""})
	if err != nil {
		t.Fatalf("Update: %v", err)
	}
	if reloaded.AvatarURL != oldAvatar {
		t.Errorf("avatar_url 应保持 %s，实际: %s", oldAvatar, reloaded.AvatarURL)
	}
}
