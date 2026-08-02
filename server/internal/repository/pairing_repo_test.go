package repository

import (
	"testing"
	"time"

	"github.com/wanling/server/internal/model"
)

func TestPairingRepo_CreateAndGet(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewPairingRepo(db)

	ticket, err := repo.Create(t.Context(), "test-ticket-id-001", "")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if ticket.ID != "test-ticket-id-001" {
		t.Fatalf("ID = %q", ticket.ID)
	}
	if ticket.Status != model.PairingStatusPending {
		t.Fatalf("Status = %q, want pending", ticket.Status)
	}

	got, err := repo.GetByID(t.Context(), "test-ticket-id-001")
	if err != nil {
		t.Fatalf("GetByID: %v", err)
	}
	if got == nil {
		t.Fatal("GetByID 返回 nil")
	}
	if got.Status != model.PairingStatusPending {
		t.Fatalf("got.Status = %q", got.Status)
	}
}

func TestPairingRepo_GetByID_NotFound(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewPairingRepo(db)

	got, err := repo.GetByID(t.Context(), "nonexistent")
	if err != nil {
		t.Fatalf("GetByID err: %v", err)
	}
	if got != nil {
		t.Fatalf("期望 nil，实际 %+v", got)
	}
}

func TestPairingRepo_MarkScanned(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewPairingRepo(db)
	urepo := NewUserRepo(db)

	user, _ := urepo.Create(t.Context(), uniqueShortName(t, "pair_scan_"), "$2a$10$hash")
	ticket, _ := repo.Create(t.Context(), "test-ticket-id-002", "")

	err := repo.MarkScanned(t.Context(), ticket.ID, user.ID)
	if err != nil {
		t.Fatalf("MarkScanned: %v", err)
	}

	got, _ := repo.GetByID(t.Context(), ticket.ID)
	if got.Status != model.PairingStatusScanned {
		t.Fatalf("Status = %q, want scanned", got.Status)
	}
	if got.UserID == nil || *got.UserID != user.ID {
		t.Fatalf("UserID = %v, want %s", got.UserID, user.ID)
	}
	if got.ScannedAt == nil {
		t.Fatal("ScannedAt 为 nil")
	}
}

func TestPairingRepo_MarkCompleted_SelectExisting(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewPairingRepo(db)
	arepo := NewAgentRepo(db)
	urepo := NewUserRepo(db)

	user, _ := urepo.Create(t.Context(), uniqueShortName(t, "pair_comp_"), "$2a$10$hash")
	agent, _ := arepo.Create(t.Context(), user.ID, "PairAgent", "orig-secret", "")
	ticket, _ := repo.Create(t.Context(), "test-ticket-id-003", "")
	_ = repo.MarkScanned(t.Context(), ticket.ID, user.ID)

	err := repo.MarkCompleted(t.Context(), ticket.ID, agent.ID, "new-secret-from-reset")
	if err != nil {
		t.Fatalf("MarkCompleted: %v", err)
	}

	got, _ := repo.GetByID(t.Context(), ticket.ID)
	if got.Status != model.PairingStatusCompleted {
		t.Fatalf("Status = %q, want completed", got.Status)
	}
	if got.AgentID == nil || *got.AgentID != agent.ID {
		t.Fatalf("AgentID = %v, want %s", got.AgentID, agent.ID)
	}
	if got.SecretKey == nil || *got.SecretKey != "new-secret-from-reset" {
		t.Fatalf("SecretKey = %v, want new-secret-from-reset", got.SecretKey)
	}
}

func TestPairingRepo_ClearSecretKey_BurnAfterReading(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewPairingRepo(db)
	arepo := NewAgentRepo(db)
	urepo := NewUserRepo(db)

	user, _ := urepo.Create(t.Context(), uniqueShortName(t, "pair_burn_"), "$2a$10$hash")
	agent, _ := arepo.Create(t.Context(), user.ID, "BurnAgent", "orig-secret", "")
	ticket, _ := repo.Create(t.Context(), "test-ticket-id-004", "")
	_ = repo.MarkScanned(t.Context(), ticket.ID, user.ID)
	_ = repo.MarkCompleted(t.Context(), ticket.ID, agent.ID, "secret-to-burn")

	err := repo.ClearSecretKey(t.Context(), ticket.ID)
	if err != nil {
		t.Fatalf("ClearSecretKey: %v", err)
	}

	got, _ := repo.GetByID(t.Context(), ticket.ID)
	if got.SecretKey != nil {
		t.Fatalf("SecretKey = %v, 期望领走后清空为 nil", got.SecretKey)
	}
	// 状态仍是 completed（保留供审计）
	if got.Status != model.PairingStatusCompleted {
		t.Fatalf("Status = %q, want completed", got.Status)
	}
}

func TestPairingRepo_DeleteExpired(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewPairingRepo(db)

	// 造一条老记录（直接插入，绕过 Create 的 default NOW()）
	old := time.Now().Add(-2 * time.Hour)
	_, err := db.Exec(
		`INSERT INTO pairing_tickets (id, status, created_at) VALUES ($1, 'pending', $2)`,
		"test-ticket-old-001", old,
	)
	if err != nil {
		t.Fatalf("插入老记录: %v", err)
	}
	// 造一条新记录
	_, _ = repo.Create(t.Context(), "test-ticket-fresh-001", "")

	deleted, err := repo.DeleteExpired(t.Context(), 1*time.Hour)
	if err != nil {
		t.Fatalf("DeleteExpired: %v", err)
	}
	if deleted != 1 {
		t.Fatalf("deleted = %d, want 1", deleted)
	}

	// 老记录没了
	got, _ := repo.GetByID(t.Context(), "test-ticket-old-001")
	if got != nil {
		t.Fatal("老记录应被删除")
	}
	// 新记录还在
	got, _ = repo.GetByID(t.Context(), "test-ticket-fresh-001")
	if got == nil {
		t.Fatal("新记录不应被删除")
	}
}

// TestPairingRepo_CreateWithType 验证 type 字段透传:Create 带 type=opencode,
// GetByID 读回时 ticket.Type 一致;默认空串保持向后兼容。
func TestPairingRepo_CreateWithType(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewPairingRepo(db)

	t.Run("opencode type 落库读回", func(t *testing.T) {
		ticket, err := repo.Create(t.Context(), "type-oc-001", "opencode")
		if err != nil {
			t.Fatalf("Create: %v", err)
		}
		if ticket.Type != "opencode" {
			t.Fatalf("Create 返回 Type = %q, want opencode", ticket.Type)
		}
		got, err := repo.GetByID(t.Context(), "type-oc-001")
		if err != nil || got == nil {
			t.Fatalf("GetByID: %v %v", got, err)
		}
		if got.Type != "opencode" {
			t.Errorf("GetByID Type = %q, want opencode", got.Type)
		}
	})

	t.Run("默认空串 type(向后兼容)", func(t *testing.T) {
		ticket, err := repo.Create(t.Context(), "type-default-001", "")
		if err != nil {
			t.Fatalf("Create: %v", err)
		}
		if ticket.Type != "" {
			t.Errorf("Type = %q, want empty", ticket.Type)
		}
	})
}
