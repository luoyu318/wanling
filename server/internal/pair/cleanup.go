// Package pair 提供扫码配对的辅助组件（票据清理等）。
package pair

import (
	"context"
	"runtime/debug"
	"time"

	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/repository"
)

// RunCleanup 后台定时清理过期票据，随 ctx 结束退出。
// interval 触发间隔；maxAge 超过此时长的票据被删（含已完成/已过期的握手记录）。
// 设计为 goroutine 调用：go RunCleanup(ctx, repo, 10*time.Minute, time.Hour)。
//
// 每 tick 派生 10s 超时 ctx,防 DB 慢查询 hang 后台 goroutine(影响后续 tick 节奏)。
func RunCleanup(ctx context.Context, repo *repository.PairingRepo, interval, maxAge time.Duration) {
	defer func() {
		if r := recover(); r != nil {
			logpkg.FromCtx(ctx).ErrorContext(ctx, "pair cleanup panic",
				"recover", r, "stack", string(debug.Stack()))
		}
	}()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	// 启动时先跑一次，避免重启后第一轮要等整个 interval
	cleanupOnce(ctx, repo, maxAge)

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			cleanupOnce(ctx, repo, maxAge)
		}
	}
}

func cleanupOnce(ctx context.Context, repo *repository.PairingRepo, maxAge time.Duration) {
	// 单 tick 内 repo 调用共享 10s 超时 ctx,防 hang
	tickCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	n, err := repo.DeleteExpired(tickCtx, maxAge)
	if err != nil {
		logpkg.FromCtx(tickCtx).ErrorContext(tickCtx, "pair-cleanup 清理过期票据失败", "err", err)
		return
	}
	if n > 0 {
		logpkg.FromCtx(tickCtx).InfoContext(tickCtx, "pair-cleanup 清理过期票据", "count", n)
	}
}
