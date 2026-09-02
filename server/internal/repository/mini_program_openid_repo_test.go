package repository

import (
	"testing"

	"github.com/google/uuid"
)

// TestMiniProgramOpenidRepo_GetOrCreateOpenid 四态:首次生成/幂等稳定/跨 appid 隔离/跨用户隔离。
func TestMiniProgramOpenidRepo_GetOrCreateOpenid(t *testing.T) {
	db := SetupTestDB(t)
	ur := NewUserRepo(db)
	repo := NewMiniProgramOpenidRepo(db)

	u1, err := ur.Create(t.Context(), uniqueShortName(t, "oid1"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user1: %v", err)
	}
	u2, err := ur.Create(t.Context(), uniqueShortName(t, "oid2"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user2: %v", err)
	}
	appidA := "mp-" + uuid.NewString()[:8]
	appidB := "mp-" + uuid.NewString()[:8]

	// 1. 首次生成:非空合法 UUID
	oid, err := repo.GetOrCreateOpenid(t.Context(), u1.ID, appidA)
	if err != nil {
		t.Fatalf("首次生成: %v", err)
	}
	if _, err := uuid.Parse(oid); err != nil {
		t.Fatalf("openid 应为合法 UUID,实际 %q", oid)
	}

	// 2. 幂等稳定:同 (user, appid) 二次调用同值
	oidAgain, err := repo.GetOrCreateOpenid(t.Context(), u1.ID, appidA)
	if err != nil {
		t.Fatalf("二次调用: %v", err)
	}
	if oidAgain != oid {
		t.Fatalf("幂等性破坏: 首次 %s 二次 %s", oid, oidAgain)
	}

	// 3. 跨 appid 隔离:同用户不同 appid 不同值
	oidB, err := repo.GetOrCreateOpenid(t.Context(), u1.ID, appidB)
	if err != nil {
		t.Fatalf("跨 appid: %v", err)
	}
	if oidB == oid {
		t.Fatalf("同用户跨 appid 应不同: %s", oidB)
	}

	// 4. 跨用户隔离:不同用户同 appid 不同值
	oidU2, err := repo.GetOrCreateOpenid(t.Context(), u2.ID, appidA)
	if err != nil {
		t.Fatalf("跨用户: %v", err)
	}
	if oidU2 == oid {
		t.Fatalf("不同用户同 appid 应不同: %s", oidU2)
	}
}
