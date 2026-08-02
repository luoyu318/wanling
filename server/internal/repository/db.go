package repository

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	_ "github.com/lib/pq"
	"github.com/wanling/server/internal/config"
	logpkg "github.com/wanling/server/internal/log"
)

// 连接池默认值。自托管单机场景够用；多实例/高并发可在 config 暴露参数覆盖。
const (
	defaultMaxOpenConns    = 25
	defaultMaxIdleConns    = 5
	defaultConnMaxLifetime = 5 * time.Minute
	defaultConnMaxIdleTime = 5 * time.Minute
)

func NewDB(cfg config.DBConfig) (*sql.DB, error) {
	// connect_timeout：DB 不可达时 Ping 不会卡到 TCP 默认超时（1~2 分钟），
	// 让启动快速失败报错。sslmode 后追加，DSN 顺序无关。
	dsn := fmt.Sprintf(
		"host=%s port=%d user=%s password=%s dbname=%s sslmode=%s connect_timeout=10",
		cfg.Host, cfg.Port, cfg.User, cfg.Password, cfg.DBName, cfg.SSLMode,
	)
	db, err := sql.Open("postgres", dsn)
	if err != nil {
		return nil, fmt.Errorf("连接数据库失败: %w", err)
	}

	// 连接池配置：限制连接数防止打满 PG（默认无上限），定期回收防泄漏。
	db.SetMaxOpenConns(defaultMaxOpenConns)
	db.SetMaxIdleConns(defaultMaxIdleConns)
	db.SetConnMaxLifetime(defaultConnMaxLifetime)
	db.SetConnMaxIdleTime(defaultConnMaxIdleTime)

	// 指数退避重试:应对 PG 启动慢(容器编排常见场景)
	maxRetries := 5
	backoff := time.Second
	var lastErr error
	for i := 0; i < maxRetries; i++ {
		if err := db.Ping(); err == nil {
			return db, nil
		} else {
			lastErr = err
			logpkg.FromCtx(context.Background()).WarnContext(context.Background(), "DB Ping 失败,准备重试",
				"attempt", i+1, "max_retries", maxRetries, "err", err, "backoff", backoff.String())
			time.Sleep(backoff)
			backoff *= 2
		}
	}
	return nil, fmt.Errorf("数据库 Ping 重试 %d 次仍失败: %w", maxRetries, lastErr)
}

// queryExecutor 是所有 Repo 共用的 SQL 调用入口。
// 设计目的:
// 1. CI lint 规则简化 — 检测"不准直接 r.db.QueryRow/Exec/Query 非 Context 变体"一条规则即可
// 2. 后续如需加 metric(tracing / slow query log),只改本结构体,全 repo 自动生效
// 3. 让 ctx 的强制消费变成类型系统的约束(非 Context 变体无对应方法)
type queryExecutor struct {
	db *sql.DB
}

// queryRow 等价于 db.QueryRowContext,所有 repo 方法通过 r.queryRow(ctx, ...) 调
func (q queryExecutor) queryRow(ctx context.Context, query string, args ...any) *sql.Row {
	return q.db.QueryRowContext(ctx, query, args...)
}

// exec 等价于 db.ExecContext
func (q queryExecutor) exec(ctx context.Context, query string, args ...any) (sql.Result, error) {
	return q.db.ExecContext(ctx, query, args...)
}

// query 等价于 db.QueryContext
func (q queryExecutor) query(ctx context.Context, query string, args ...any) (*sql.Rows, error) {
	return q.db.QueryContext(ctx, query, args...)
}

// beginTx 把 BeginTx 纳入封装层,防止调用方绕过 CI lint 直接访问 r.queryExecutor.db.BeginTx。
// 与 queryRow/exec/query 一样,value receiver,首参 ctx。
func (q queryExecutor) beginTx(ctx context.Context) (*sql.Tx, error) {
	return q.db.BeginTx(ctx, nil)
}
