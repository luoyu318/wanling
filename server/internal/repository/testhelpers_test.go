package repository

import (
	"database/sql"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// uniqueShortName 把测试函数名压成不超过 32 字符的稳定短串，避免超出 users.username varchar(64) 限制。
// plan 原文用 "testuser_" + t.Name() 会超长（测试函数名本身常 > 50 字符），这里加一层裁剪。
//
// 原定义在 conversation_repo_test.go,因 Batch 1 中途 conversation_repo(_test).go 加了
// legacy_repos build tag 暂时绕开编译(Task 1.6 才改造 ConversationRepo/MessageRepo),
// uniqueShortName 被多处其他测试文件引用,提出来作为公共 helper 避免连带屏蔽。
func uniqueShortName(t *testing.T, prefix string) string {
	t.Helper()
	name := strings.ToLower(t.Name())
	// 去掉 Test 前缀和下划线，截短
	name = strings.ReplaceAll(name, "test", "")
	name = strings.ReplaceAll(name, "_", "")
	if len(name) > 20 {
		name = name[:20]
	}
	return prefix + name
}

// migration015Path 返回 015 migration SQL 文件绝对路径。失败时 fail 测试。
func migration015Path(t *testing.T) string {
	t.Helper()
	// 测试工作目录是 server/internal/repository/,../../migrations 是 server/migrations
	p := filepath.Join("..", "..", "migrations", "015_participants_model.sql")
	abs, err := filepath.Abs(p)
	if err != nil {
		t.Fatalf("解析 migration 015 路径失败: %v", err)
	}
	if _, err := os.Stat(abs); err != nil {
		t.Fatalf("migration 015 文件不存在 %s: %v", abs, err)
	}
	return abs
}

// ExecMigration015 在已连到 001-014 schema 的 DB 上手动执行 015 SQL。
//
// 背景:SetupTestDB 默认跳过 015_participants_model.sql(见 testdb.go 的
// migrationSkipPrefixes),因为 Batch 1 中途 ConversationRepo/MessageRepo 还没改造,
// 大部分 repo 测试仍依赖老 schema。需要新 schema 的测试(participants/deliveries/
// friendship 等)在 SetupTestDB 之后手动调本函数跑 015。
//
// 原 helper 是 migration_015_test.go 内的私有 execMigration015,因 Task 1.3 开始
// 多个 repo 测试文件都要用,提取为公共导出 helper(测试包内可见)。
func ExecMigration015(t *testing.T, db *sql.DB) {
	t.Helper()
	sqlBytes, err := os.ReadFile(migration015Path(t))
	if err != nil {
		t.Fatalf("读 migration 015 失败: %v", err)
	}
	if _, err := db.Exec(string(sqlBytes)); err != nil {
		t.Fatalf("执行 migration 015 失败: %v", err)
	}
}
