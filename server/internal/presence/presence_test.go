package presence

import (
	"context"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/redis/go-redis/v9"
)

// newTestPresence 起一个进程内 miniredis + 连接好的 Presence，测试结束自动清理。
// miniredis 精确复现 Redis 的 SET/EXPIRE/DEL 语义，无需 Docker、CI 也能跑，
// 适合验证 presence key 的续期/重建逻辑。
func newTestPresence(t *testing.T) (*Presence, *miniredis.Miniredis, *redis.Client) {
	t.Helper()
	mr := miniredis.RunT(t)
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	t.Cleanup(func() { _ = rdb.Close() })
	return New(rdb), mr, rdb
}

// TestOnlineOfflineIsOnline_Basic 验证正常建连/查询/断开流程。
func TestOnlineOfflineIsOnline_Basic(t *testing.T) {
	p, _, _ := newTestPresence(t)

	if p.IsOnline("agent", "a1") {
		t.Fatal("未 Online 前应判定离线")
	}

	if err := p.Online("agent", "a1"); err != nil {
		t.Fatalf("Online 失败: %v", err)
	}
	if !p.IsOnline("agent", "a1") {
		t.Fatal("Online 后应判定在线")
	}

	if err := p.Offline("agent", "a1"); err != nil {
		t.Fatalf("Offline 失败: %v", err)
	}
	if p.IsOnline("agent", "a1") {
		t.Fatal("Offline 后应判定离线")
	}
}

// TestOnline_SetsTTL 验证 Online 建的 key 带 60s TTL（过期后自动消失）。
func TestOnline_SetsTTL(t *testing.T) {
	p, mr, _ := newTestPresence(t)

	_ = p.Online("agent", "a1")
	key := "presence:agent:a1"
	if !mr.Exists(key) {
		t.Fatal("Online 后 key 应存在")
	}
	ttl := mr.TTL(key)
	if ttl <= 0 || ttl > ttlConst() {
		t.Fatalf("TTL 应在 (0, 60s]，实际 %v", ttl)
	}
}

// TestRefreshTTL_RenewsExistingKey 验证 key 存在时 RefreshTTL 续期 TTL。
func TestRefreshTTL_RenewsExistingKey(t *testing.T) {
	p, mr, _ := newTestPresence(t)

	_ = p.Online("agent", "a1")
	key := "presence:agent:a1"
	// 快进 40s，TTL 应已降到 20s 以下
	mr.FastForward(40 * time.Second)
	if ttl := mr.TTL(key); ttl > 20*time.Second {
		t.Fatalf("快进 40s 后 TTL 应 <=20s，实际 %v", ttl)
	}

	// 续期，TTL 应回到接近 60s
	if err := p.RefreshTTL("agent", "a1"); err != nil {
		t.Fatalf("RefreshTTL 失败: %v", err)
	}
	if ttl := mr.TTL(key); ttl <= 40*time.Second {
		t.Fatalf("RefreshTTL 后 TTL 应 >40s（接近 60s），实际 %v", ttl)
	}
}

// TestRefreshTTL_RebuildsMissingKey 是核心回归测试。
//
// 复现 bug：presence key 一旦丢失（Redis 清空/server 重启），EXPIRE 无法重建，
// 导致 agent「WS 连接存活、能收发消息，但状态永久离线」。修复后 RefreshTTL
// 用 SET，key 丢失后一次心跳即自愈。
//
// 修复前（EXPIRE）此用例 FAIL，修复后（SET）PASS。
func TestRefreshTTL_RebuildsMissingKey(t *testing.T) {
	p, mr, _ := newTestPresence(t)
	ctx := context.Background()

	// 1. agent 正常上线
	_ = p.Online("agent", "a1")
	key := "presence:agent:a1"
	if !p.IsOnline("agent", "a1") {
		t.Fatal("Online 后应在线")
	}

	// 2. 模拟 key 丢失（Redis 清空 / server 重启后既有连接不断，key 却没了）
	mr.Del(key)
	if p.IsOnline("agent", "a1") {
		t.Fatal("key 被 Del 后应离线（模拟 Redis 清空）")
	}

	// 3. 心跳触发 RefreshTTL —— 修复后应重建 key
	if err := p.RefreshTTL("agent", "a1"); err != nil {
		t.Fatalf("RefreshTTL 失败: %v", err)
	}

	// 4. 断言自愈成功：key 重新存在 + IsOnline 回到 true + TTL 合理
	if !p.IsOnline("agent", "a1") {
		t.Fatal("RefreshTTL 后应重新在线（key 丢失后心跳应自愈）—— 这是 bug 的核心断言")
	}
	if !mr.Exists(key) {
		t.Fatal("key 应被 RefreshTTL 重建")
	}
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	defer rdb.Close()
	ttl, err := rdb.TTL(ctx, key).Result()
	if err != nil {
		t.Fatalf("查 TTL 失败: %v", err)
	}
	if ttl <= 0 || ttl > ttlConst() {
		t.Fatalf("重建后 TTL 应在 (0, 60s]，实际 %v", ttl)
	}
}

// TestNilClient_IsAlwaysOffline 验证降级路径：rdb 为 nil 时所有方法安全返回，
// IsOnline 恒为 false。对应 main.go「Redis 连不上降级单机模式」。
func TestNilClient_IsAlwaysOffline(t *testing.T) {
	p := New(nil)

	if p.IsOnline("agent", "a1") {
		t.Fatal("nil rdb 时 IsOnline 应恒为 false")
	}
	// 以下均不应 panic
	if err := p.Online("agent", "a1"); err != nil {
		t.Fatalf("nil rdb 时 Online 应安全返回 nil，实际 %v", err)
	}
	if err := p.Offline("agent", "a1"); err != nil {
		t.Fatalf("nil rdb 时 Offline 应安全返回 nil，实际 %v", err)
	}
	if err := p.RefreshTTL("agent", "a1"); err != nil {
		t.Fatalf("nil rdb 时 RefreshTTL 应安全返回 nil，实际 %v", err)
	}
}

// ttlConst 返回包内 ttl 常量（60s），供测试断言复用，避免魔法数字。
func ttlConst() time.Duration { return ttl }
