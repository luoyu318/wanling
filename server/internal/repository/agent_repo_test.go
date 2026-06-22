package repository

import (
	"crypto/rand"
	"encoding/hex"
	"testing"

	"github.com/wanling/server/internal/model"
)

// createTestAgent 建一个测试用 agent，自动建 owner user 满足外键。
func createTestAgent(t *testing.T, repo *AgentRepo, ownerID string) *model.Agent {
	t.Helper()
	a, err := repo.Create(ownerID, "testagent-"+shorten(t.Name()), "secret_xxx")
	if err != nil {
		t.Fatalf("Create agent: %v", err)
	}
	return a
}

// shorten 把测试名压短，避免 agent name 过长或含特殊字符。
func shorten(s string) string {
	if len(s) > 16 {
		return s[:16]
	}
	return s
}

// TestAgentRepo_Update_BioPointer 验证传 bio 指针能更新 bio。
func TestAgentRepo_Update_BioPointer(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewAgentRepo(db)
	urepo := NewUserRepo(db)
	user, err := urepo.Create(uniqueShortName(t, "own_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create owner user: %v", err)
	}

	agent := createTestAgent(t, repo, user.ID)

	newBio := "这是一个测试 agent"
	emptyName := ""
	emptyAvatar := ""
	reloaded, err := repo.Update(agent.ID, emptyName, emptyAvatar, &newBio)
	if err != nil {
		t.Fatalf("Update: %v", err)
	}
	if reloaded == nil {
		t.Fatalf("Update 返回 nil agent")
	}
	if reloaded.Bio == nil || *reloaded.Bio != newBio {
		t.Errorf("bio 应为 %s，实际: %v", newBio, reloaded.Bio)
	}
}

// TestAgentRepo_Update_BioNilKeepsValue 验证 bio=nil 不动。
func TestAgentRepo_Update_BioNilKeepsValue(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewAgentRepo(db)
	urepo := NewUserRepo(db)
	user, _ := urepo.Create(uniqueShortName(t, "own_"), "$2a$10$hash")
	agent := createTestAgent(t, repo, user.ID)

	// 先设 bio
	oldBio := "原简介"
	_, _ = db.Exec(`UPDATE agents SET bio = $1 WHERE id = $2`, oldBio, agent.ID)

	// Update 传 nil bio（不动），只改 name
	reloaded, err := repo.Update(agent.ID, "新名字", "", nil)
	if err != nil {
		t.Fatalf("Update: %v", err)
	}
	if reloaded.Bio == nil || *reloaded.Bio != oldBio {
		t.Errorf("bio 应保持 %s，实际: %v", oldBio, reloaded.Bio)
	}
	if reloaded.Name != "新名字" {
		t.Errorf("name 应为 新名字，实际: %s", reloaded.Name)
	}
}

// TestAgentRepo_Update_BioEmptyStringClears 验证传空串指针清空 bio。
func TestAgentRepo_Update_BioEmptyStringClears(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewAgentRepo(db)
	urepo := NewUserRepo(db)
	user, _ := urepo.Create(uniqueShortName(t, "own_"), "$2a$10$hash")
	agent := createTestAgent(t, repo, user.ID)

	oldBio := "有值"
	_, _ = db.Exec(`UPDATE agents SET bio = $1 WHERE id = $2`, oldBio, agent.ID)

	emptyBio := ""
	reloaded, err := repo.Update(agent.ID, "", "", &emptyBio)
	if err != nil {
		t.Fatalf("Update: %v", err)
	}
	if reloaded.Bio != nil && *reloaded.Bio != "" {
		t.Errorf("bio 应被清空，实际: %v", reloaded.Bio)
	}
}

// randKey 测试用随机密钥生成（与 handler.generateSecretKey 同算法，避免跨包循环依赖）。
func randKey(t *testing.T) string {
	t.Helper()
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		t.Fatalf("rand.Read: %v", err)
	}
	return hex.EncodeToString(b)
}

// TestAgentRepo_ResetSecretKey_ChangesKey 验证重置 key 后新 key 落盘且与旧 key 不同。
func TestAgentRepo_ResetSecretKey_ChangesKey(t *testing.T) {
	db := SetupTestDB(t)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, err := urepo.Create(uniqueShortName(t, "reset_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user: %v", err)
	}
	origKey := randKey(t)
	agent, err := arepo.Create(user.ID, "ResetAgent", origKey)
	if err != nil {
		t.Fatalf("Create agent: %v", err)
	}

	newKey, err := arepo.ResetSecretKey(agent.ID)
	if err != nil {
		t.Fatalf("ResetSecretKey: %v", err)
	}
	if newKey == "" {
		t.Fatal("newKey 为空")
	}
	if newKey == origKey {
		t.Fatal("新 key 与旧 key 相同，未重置")
	}

	// 再查一次，确认 DB 里存的确实是新 key
	after, err := arepo.GetByID(agent.ID)
	if err != nil {
		t.Fatalf("GetByID: %v", err)
	}
	if after.SecretKey != newKey {
		t.Fatalf("DB key = %q, want %q", after.SecretKey, newKey)
	}
}

// TestAgentRepo_ResetSecretKey_NonexistentReturnsError agent 不存在时应返回错误。
func TestAgentRepo_ResetSecretKey_NonexistentReturnsError(t *testing.T) {
	db := SetupTestDB(t)
	arepo := NewAgentRepo(db)

	_, err := arepo.ResetSecretKey("00000000-0000-0000-0000-000000000000")
	if err == nil {
		t.Fatal("期望返回错误（agent 不存在），实际 nil")
	}
}
