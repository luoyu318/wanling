package repository

import (
	"testing"
	"time"

	"github.com/wanling/server/internal/model"
)

func TestPairingRepo_CreateAndGet(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewPairingRepo(db)

	ticket, err := repo.Create("test-ticket-id-001")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if ticket.ID != "test-ticket-id-001" {
		t.Fatalf("ID = %q", ticket.ID)
	}
	if ticket.Status != model.PairingStatusPending {
		t.Fatalf("Status = %q, want pending", ticket.Status)
	}

	got, err := repo.GetByID("test-ticket-id-001")
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

	got, err := repo.GetByID("nonexistent")
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

	user, _ := urepo.Create(uniqueShortName(t, "pair_scan_"), "$2a$10$hash")
	ticket, _ := repo.Create("test-ticket-id-002")

	err := repo.MarkScanned(ticket.ID, user.ID)
	if err != nil {
		t.Fatalf("MarkScanned: %v", err)
	}

	got, _ := repo.GetByID(ticket.ID)
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

	user, _ := urepo.Create(uniqueShortName(t, "pair_comp_"), "$2a$10$hash")
	agent, _ := arepo.Create(user.ID, "PairAgent", "orig-secret")
	ticket, _ := repo.Create("test-ticket-id-003")
	_ = repo.MarkScanned(ticket.ID, user.ID)

	err := repo.MarkCompleted(ticket.ID, agent.ID, "new-secret-from-reset")
	if err != nil {
		t.Fatalf("MarkCompleted: %v", err)
	}

	got, _ := repo.GetByID(ticket.ID)
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

	user, _ := urepo.Create(uniqueShortName(t, "pair_burn_"), "$2a$10$hash")
	agent, _ := arepo.Create(user.ID, "BurnAgent", "orig-secret")
	ticket, _ := repo.Create("test-ticket-id-004")
	_ = repo.MarkScanned(ticket.ID, user.ID)
	_ = repo.MarkCompleted(ticket.ID, agent.ID, "secret-to-burn")

	err := repo.ClearSecretKey(ticket.ID)
	if err != nil {
		t.Fatalf("ClearSecretKey: %v", err)
	}

	got, _ := repo.GetByID(ticket.ID)
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
	_, _ = repo.Create("test-ticket-fresh-001")

	deleted, err := repo.DeleteExpired(1 * time.Hour)
	if err != nil {
		t.Fatalf("DeleteExpired: %v", err)
	}
	if deleted != 1 {
		t.Fatalf("deleted = %d, want 1", deleted)
	}

	// 老记录没了
	got, _ := repo.GetByID("test-ticket-old-001")
	if got != nil {
		t.Fatal("老记录应被删除")
	}
	// 新记录还在
	got, _ = repo.GetByID("test-ticket-fresh-001")
	if got == nil {
		t.Fatal("新记录不应被删除")
	}
}
