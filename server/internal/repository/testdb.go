package repository

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	_ "github.com/lib/pq"
	"github.com/testcontainers/testcontainers-go"
	"github.com/testcontainers/testcontainers-go/wait"
)

// migrationSkipPrefixes 用于在 schema 重构过渡期跳过特定 migration。
//
// 当前为空:Batch 1 已完成(Task 1.6 收尾),所有 repo 都跑在新 schema 上,
// SetupTestDB 默认应用完整 001-015 migration 链。
//
// 如需跳过某 migration(未来 schema 重构过渡期),加入前缀(如 "016_")。
// isMigrationSkipped 用 strings.HasPrefix 做前缀匹配。
var migrationSkipPrefixes = []string{}

// SetupTestDB 起一个一次性 Postgres 容器，跑 migrations，返回 *sql.DB。
// 跳过条件：CI=1 时跳过（在 CI 上跑 docker 太重）；本地默认启用。
//
// 默认行为:跑 migrations 目录下所有 .sql(当前 migrationSkipPrefixes 为空,
// 即完整跑 001-015 链)。
//
// migration_015_test 验证「老 schema seed + 跑 015 回填」逻辑,需要先在 001-014
// 老 schema 上 seed 数据,用 SetupTestDBSkipping015 拿到只跑 001-014 的 DB。
func SetupTestDB(t *testing.T) *sql.DB {
	t.Helper()
	return setupTestDBWithSkip(t, nil)
}

// SetupTestDBSkipping015 起 DB 并跑 001-014 + 016,跳过 015 + 017。
// 仅 migration_015_test 用(在老 schema 上 seed 数据,再手动 ExecMigration015 验证回填)。
//
// 跳过 017 的原因:015 line 105 会建 idx_conversations_last_msg_at 索引(基于
// conversations.last_message_at 列),017 DROP 该列会让 ExecMigration015 失败。
// 跳过 017 让该列保留,015 测试在自己的沙盒里跑完整升级流程。
// 业务测试应直接调 SetupTestDB(已自动应用 015/016/017 完整链)。
func SetupTestDBSkipping015(t *testing.T) *sql.DB {
	t.Helper()
	return setupTestDBWithSkip(t, []string{"015_", "017_"})
}

// setupTestDBWithSkip 是 SetupTestDB / SetupTestDBSkipping015 的共享实现。
// extraSkip 在全局 migrationSkipPrefixes 基础上额外临时跳过的前缀。
func setupTestDBWithSkip(t *testing.T, extraSkip []string) *sql.DB {
	t.Helper()
	// 设计权衡：CI=1 时跳过 testcontainers 测试。
	// 原因：CI runner 通常无法直接访问 Docker daemon（需 docker-in-docker 或 socket 映射），
	// 配置成本高。本地开发默认启用，保证 repo 层测试有真库回归保护。
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

	// 跑所有 migrations(跳过 migrationSkipPrefixes + extraSkip 列出的前缀)
	migrations, err := filepath.Glob(filepath.Join("..", "..", "migrations", "*.sql"))
	if err != nil {
		t.Fatalf("glob migrations 失败: %v", err)
	}
	for _, m := range migrations {
		name := filepath.Base(m)
		if isMigrationSkipped(name) || isAnyPrefixMatched(name, extraSkip) {
			continue
		}
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

// isMigrationSkipped 判断给定 migration 文件名是否被 SetupTestDB 默认跳过。
func isMigrationSkipped(name string) bool {
	return isAnyPrefixMatched(name, migrationSkipPrefixes)
}

// isAnyPrefixMatched 通用前缀匹配 helper。
func isAnyPrefixMatched(name string, prefixes []string) bool {
	for _, p := range prefixes {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	return false
}
