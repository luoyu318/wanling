package repository

import (
	"strings"
	"testing"
)

// uniqueShortName 把测试函数名压成不超过 32 字符的稳定短串,避免超出 users.username varchar(64) 限制。
// plan 原文用 "testuser_" + t.Name() 会超长(测试函数名本身常 > 50 字符),这里加一层裁剪。
func uniqueShortName(t *testing.T, prefix string) string {
	t.Helper()
	name := strings.ToLower(t.Name())
	name = strings.ReplaceAll(name, "test", "")
	name = strings.ReplaceAll(name, "_", "")
	if len(name) > 20 {
		name = name[:20]
	}
	return prefix + name
}
