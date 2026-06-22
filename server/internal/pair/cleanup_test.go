package pair

import (
	"context"
	"testing"
	"time"

	"github.com/wanling/server/internal/repository"
)

func TestRunCleanup_DeletesExpiredTickets(t *testing.T) {
	db := repository.SetupTestDB(t)
	repo := repository.NewPairingRepo(db)

	// 造一条 2 小时前的老记录
	_, err := db.Exec(
		`INSERT INTO pairing_tickets (id, status, created_at) VALUES ($1, 'pending', $2)`,
		"cleanup-old-001", time.Now().Add(-2*time.Hour),
	)
	if err != nil {
		t.Fatalf("插入老记录: %v", err)
	}
	// 造一条新记录
	_, _ = repo.Create("cleanup-fresh-001")

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// 跑 RunCleanup（interval 短，maxAge=1h），等它执行一轮
	done := make(chan struct{})
	go func() {
		RunCleanup(ctx, repo, 50*time.Millisecond, time.Hour)
		close(done)
	}()

	// 等最多 2 秒，老记录应被删
	deadline := time.After(2 * time.Second)
	for {
		got, _ := repo.GetByID("cleanup-old-001")
		if got == nil {
			break // 已删除
		}
		select {
		case <-deadline:
			t.Fatal("超时：老记录未被清理")
		case <-time.After(50 * time.Millisecond):
		}
	}

	// 新记录还在
	got, _ := repo.GetByID("cleanup-fresh-001")
	if got == nil {
		t.Fatal("新记录不应被清理")
	}

	cancel()
	<-done
}
