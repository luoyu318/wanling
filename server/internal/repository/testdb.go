package repository

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	_ "github.com/lib/pq"
	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"
)

// SetupTestDB 起一个一次性 Postgres 容器，跑 migrations，返回 *sql.DB。
// 跳过条件：CI=1 时跳过（在 CI 上跑 docker 太重）；本地默认启用。
func SetupTestDB(t *testing.T) *sql.DB {
	t.Helper()
	// 设计权衡：CI=1 时跳过 testcontainers 测试。
	// 原因：CI runner 通常无法直接访问 Docker daemon（需 docker-in-docker 或 socket 映射），
	// 配置成本高。本地开发默认启用，保证 repo 层测试有真库回归保护。
	// 后续接入 CI 时如果 runner 支持 docker，改为相反方向（默认开、显式 SKIP_TESTCONTAINERS=1 才跳过）。
	if os.Getenv("CI") == "1" {
		t.Skip("CI 环境跳过 testcontainers 测试")
	}

	ctx := context.Background()
	req := testcontainers.ContainerRequest{
		Image:        "postgres:16-alpine",
		ExposedPorts: []string{"5432/tcp"},
		Env:          map[string]string{"POSTGRES_USER": "test", "POSTGRES_PASSWORD": "test", "POSTGRES_DB": "test"},
		WaitingFor:   wait.ForLog("database system is ready to accept connections").WithOccurrence(2),
	}
	pgC, err := testcontainers.GenericContainer(ctx, testcontainers.GenericContainerRequest{
		ContainerRequest: req, Started: true,
	})
	if err != nil {
		t.Fatalf("启动 PG 容器失败: %v", err)
	}
	t.Cleanup(func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		if err := pgC.Terminate(shutdownCtx); err != nil {
			t.Logf("警告：销毁容器失败: %v", err)
		}
	})

	host, err := pgC.Host(ctx)
	if err != nil {
		t.Fatalf("获取容器 host 失败: %v", err)
	}
	port, err := pgC.MappedPort(ctx, "5432/tcp")
	if err != nil {
		t.Fatalf("获取容器 port 失败: %v", err)
	}
	dsn := fmt.Sprintf("host=%s port=%s user=test password=test dbname=test sslmode=disable", host, port.Port())

	db, err := sql.Open("postgres", dsn)
	if err != nil {
		t.Fatalf("打开 DB 失败: %v", err)
	}

	// 等 DB 就绪
	for i := 0; i < 30; i++ {
		if err := db.Ping(); err == nil {
			break
		}
		time.Sleep(time.Second)
	}

	// 跑所有 migrations
	migrations, err := filepath.Glob(filepath.Join("..", "..", "migrations", "*.sql"))
	if err != nil {
		t.Fatalf("glob migrations 失败: %v", err)
	}
	for _, m := range migrations {
		sql, err := os.ReadFile(m)
		if err != nil {
			t.Fatalf("读 migration 失败 %s: %v", m, err)
		}
		if _, err := db.Exec(string(sql)); err != nil {
			t.Fatalf("执行 migration 失败 %s: %v", m, err)
		}
	}

	return db
}
