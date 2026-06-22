// Package pair 提供扫码配对的辅助组件（票据清理等）。
package pair

import (
	"context"
	"log"
	"time"

	"github.com/wanling/server/internal/repository"
)

// RunCleanup 后台定时清理过期票据，随 ctx 结束退出。
// interval 触发间隔；maxAge 超过此时长的票据被删（含已完成/已过期的握手记录）。
// 设计为 goroutine 调用：go RunCleanup(ctx, repo, 10*time.Minute, time.Hour)。
func RunCleanup(ctx context.Context, repo *repository.PairingRepo, interval, maxAge time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	// 启动时先跑一次，避免重启后第一轮要等整个 interval
	cleanupOnce(repo, maxAge)

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			cleanupOnce(repo, maxAge)
		}
	}
}

func cleanupOnce(repo *repository.PairingRepo, maxAge time.Duration) {
	n, err := repo.DeleteExpired(maxAge)
	if err != nil {
		log.Printf("[pair-cleanup] 清理过期票据失败: %v", err)
		return
	}
	if n > 0 {
		log.Printf("[pair-cleanup] 已清理 %d 条过期票据", n)
	}
}
