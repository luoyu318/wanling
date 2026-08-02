package repository

import "testing"

// TestSetupTestDB_ConnectsAndMigrates 是基础设施的 sanity check：
// 验证 SetupTestDB 能起容器、连库、跑完 migration，并最终落地 5 张表。
func TestSetupTestDB_ConnectsAndMigrates(t *testing.T) {
	db := SetupTestDB(t)
	var n int
	if err := db.QueryRow(`SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public'`).Scan(&n); err != nil {
		t.Fatalf("查询失败: %v", err)
	}
	if n < 5 {
		t.Fatalf("迁移后表数量异常: %d (期望>=5)", n)
	}
}
