package repository

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/lib/pq"
)

// isPQQueryCanceled 判断错误是否是 PG 端的 query_canceled (SQLSTATE 57014)。
// lib/pq 在 ctx cancel 时:优先把 ctx.Err() 存为 conn 错误(driver 层),
// 但若 cancel 包晚于 query 完成到达 PG,server 仍可能返回 ErrorResponse(57014),
// driver 把它包装成 *pq.Error。两者语义等价(都表示查询被 ctx 中断)。
func isPQQueryCanceled(err error) bool {
	var pqErr *pq.Error
	if errors.As(err, &pqErr) {
		return pqErr.Code == "57014"
	}
	return false
}

// TestQueryExecutor_QueryRowContext 验证 queryExecutor.queryRow 透传 ctx 给 driver,
// ctx cancel 后查询立即返回(不卡到 PG 默认超时)。
//
// 用 pg_sleep(6) 模拟慢查询,200ms 后 cancel,断言返回时间 < 3s。
//
// SQL 说明:pg_sleep 返回 void,不能直接 `::int`(PG 报 42846 void→integer 无 cast)。
// 用 `count(*) FROM pg_sleep(6)` 包装:FROM 子句里 pg_sleep 单行返回,count 聚合
// 出 1 行 1 列 int8,Scan 到 int 没歧义,且 sleep 在子查询里真实生效。
//
// 阈值说明:
//   - sleep 时长取 6s(不是 2s):lib/pq 的 watchCancel 用 background ctx 重新 dial 一条
//     新 TCP 连接发 CancelRequest 包,在 testcontainers(docker 网络代理)环境下
//     dial + cancel 包往返实测 ~1-2s,需要留充足窗口让 cancel 先于 query 完成。
//   - 返回阈值 3s:同理,cancel 路径延迟远大于 ctx.Done() 触发本身,不能用毫秒级阈值。
//   - 期望错误:lib/pq 在 ctx cancel 时把 ctx.Err() 存为 conn 错误,errors.Is 应匹配。
//     若实际返回 pq.Error(57014 query_canceled)也视为 cancel 生效(driver 兜底)。
func TestQueryExecutor_QueryRowContext(t *testing.T) {
	if testing.Short() {
		t.Skip("跳过: 集成测试需 PG 容器")
	}
	db := SetupTestDB(t)
	q := queryExecutor{db: db}

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(200 * time.Millisecond)
		cancel()
	}()

	start := time.Now()
	var res int
	err := q.queryRow(ctx, "SELECT count(*) FROM pg_sleep(6)").Scan(&res)
	elapsed := time.Since(start)

	// 接受两种 cancel 表现:driver 层 context.Canceled,或 PG 端 57014 query_canceled
	// (后者是 lib/pq 收到 server ErrorResponse 时的回退路径,语义等价)
	if !errors.Is(err, context.Canceled) && !isPQQueryCanceled(err) {
		t.Fatalf("期望 context.Canceled 或 pq query_canceled, 实际 %v", err)
	}
	if elapsed > 3*time.Second {
		t.Fatalf("期望 < 3s 返回(cancel 生效), 实际 %v", elapsed)
	}
}

// TestQueryExecutor_ExecContext_HappyPath 验证正常路径 ExecContext 能执行
func TestQueryExecutor_ExecContext_HappyPath(t *testing.T) {
	if testing.Short() {
		t.Skip("跳过: 集成测试需 PG 容器")
	}
	db := SetupTestDB(t)
	q := queryExecutor{db: db}

	_, err := q.exec(context.Background(), "SELECT 1")
	if err != nil {
		t.Fatalf("exec 失败: %v", err)
	}
}

// TestQueryExecutor_QueryContext_HappyPath 验证正常路径 QueryContext 能执行
func TestQueryExecutor_QueryContext_HappyPath(t *testing.T) {
	if testing.Short() {
		t.Skip("跳过: 集成测试需 PG 容器")
	}
	db := SetupTestDB(t)
	q := queryExecutor{db: db}

	rows, err := q.query(context.Background(), "SELECT 1")
	if err != nil {
		t.Fatalf("query 失败: %v", err)
	}
	defer rows.Close()
}
