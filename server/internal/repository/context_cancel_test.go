package repository

import (
	"context"
	"errors"
	"testing"
	"time"
)

// TestContextCancel_ReachesDriver 验证 repo 方法接的 ctx 真消费(透传到 driver)。
//
// 思路:用 UserRepo.GetByID 调一个不存在的 ID,但在调用前 cancel ctx,
// 期望立即返回 context.Canceled(或 pq query_canceled 57014)。
// 验证 ctx 真下沉到 driver,而不是被 repo 忽略。
//
// 阈值 3s:testcontainers cancel 路径慢(详见 db_test.go TestQueryExecutor_QueryRowContext 注释)。
func TestContextCancel_ReachesDriver(t *testing.T) {
	if testing.Short() {
		t.Skip("跳过: 集成测试需 PG 容器")
	}
	db := SetupTestDB(t)
	repo := NewUserRepo(db)

	ctx, cancel := context.WithCancel(context.Background())
	cancel() // 立即 cancel

	start := time.Now()
	_, err := repo.GetByID(ctx, "nonexistent")
	elapsed := time.Since(start)

	// pq driver 在 ctx 已 canceled 时立即返回 context.Canceled 或 pq.Error(57014)
	if !isCtxCanceled(err) {
		t.Fatalf("期望 context.Canceled 或 pq query_canceled, 实际 %v", err)
	}
	if elapsed > 3*time.Second {
		t.Fatalf("期望立即返回(< 3s,testcontainers cancel 路径慢), 实际 %v", elapsed)
	}
}

// TestContextCancel_DuringLongQuery 验证慢查询被 cancel 后立即返回。
//
// 用 pg_sleep(6) 模拟慢查询,200ms 后 cancel,期望 < 3s 返回。
// 这是 H4 修复的核心验证:ctx 真生效,慢查询不会卡到 PG 默认超时。
//
// SQL 说明(同 db_test.go):用 `count(*) FROM pg_sleep(6)` 包装,
// FROM 子句里 pg_sleep 单行返回,count 聚合出 1 行 1 列,Scan 到 int 没歧义,
// 且 sleep 在子查询里真实生效。
func TestContextCancel_DuringLongQuery(t *testing.T) {
	if testing.Short() {
		t.Skip("跳过: 集成测试需 PG 容器")
	}
	db := SetupTestDB(t)
	repo := NewUserRepo(db)

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(200 * time.Millisecond)
		cancel()
	}()

	// 借用 queryExecutor 跑一个慢查询
	_ = repo // 保持引用避免 lint 警告(repo 在本用例里仅证明组装 OK)
	q := queryExecutor{db: db}
	start := time.Now()
	var count int
	err := q.queryRow(ctx, "SELECT count(*) FROM pg_sleep(6)").Scan(&count)
	elapsed := time.Since(start)

	if !isCtxCanceled(err) {
		t.Fatalf("期望 context.Canceled 或 pq query_canceled, 实际 %v", err)
	}
	if elapsed > 3*time.Second {
		t.Fatalf("期望 < 3s 返回(cancel 生效), 实际 %v", elapsed)
	}
}

// isCtxCanceled 同时接受 context.Canceled/errors.Is 透传 和 pq.Error(57014) query_canceled。
//
// lib/pq 的 ctx cancel 有两条等价路径:
//  1. driver 层把 ctx.Err() 存为 conn 错误 → errors.Is(err, context.Canceled) 命中
//  2. cancel 包晚于 query 完成,PG server 仍返 ErrorResponse(SQLSTATE 57014)→ driver 包装为 *pq.Error
//
// 复用 db_test.go 的 isPQQueryCanceled(同 package,直接调用)。
func isCtxCanceled(err error) bool {
	if errors.Is(err, context.Canceled) {
		return true
	}
	return isPQQueryCanceled(err)
}
