package handler

import "testing"

// TestRoleForUsername 验证 ADMIN_USERNAMES 命中签发 admin,其余 user。
func TestRoleForUsername(t *testing.T) {
	admins := []string{"root", "ops"}
	if got := roleForUsername(admins, "root"); got != "admin" {
		t.Errorf("root 应为 admin,实际 %s", got)
	}
	if got := roleForUsername(admins, "ops"); got != "admin" {
		t.Errorf("ops 应为 admin,实际 %s", got)
	}
	if got := roleForUsername(admins, "alice"); got != "user" {
		t.Errorf("alice 应为 user,实际 %s", got)
	}
	if got := roleForUsername(nil, "root"); got != "user" {
		t.Errorf("未配置管理员时应全为 user,实际 %s", got)
	}
}
