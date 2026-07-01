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
// 背景:SetupTestDB 默认跑完整 001-015 migration 链(Batch 1 完成后)。
// 仅 migration_015_test.go 用本函数验证「老 schema seed + 跑 015 回填」逻辑:
//   1. 用 setupTestDBSkipping015 拿到只跑 001-014 的 DB(老 schema)
//   2. seed 老格式数据(user_id/agent_id/is_read 等)
//   3. 调本函数跑 015,验证回填到 participants/deliveries 等新表
//
// 普通业务测试不应调本函数(SetupTestDB 已自动应用 015)。
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
