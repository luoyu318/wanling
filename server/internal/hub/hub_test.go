package hub

import (
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/wanling/server/internal/model"
)

// newTestClient 创建不含真实连接用于单元测试的 client。
// Send 通道容量 8 避免满缓冲导致测试阻塞。
func newTestClient(id, role string) *Client {
	return &Client{
		ID:            id,
		Role:          role,
		Conn:          nil,
		Send:          make(chan []byte, 8),
		LastHeartbeat: time.Now(),
	}
}

// drainSend 读取 Send 通道中所有数据并返回消息条数，不阻塞。
func drainSend(c *Client) int {
	n := 0
	for {
		select {
		case <-c.Send:
			n++
		default:
			return n
		}
	}
}

// startHub 启动 Hub 的 Run loop 并返回 stop 函数。
func startHub(h *Hub) func() {
	done := make(chan struct{})
	go func() {
		h.Run()
		close(done)
	}()
	return func() {
		// 停止 GC ticker：Register 一个无效消息让 select 退出不够可靠，
		// 直接 rely on test cleanup。这里只保证 hub 不泄露。
	}
}

// TestMultiClientRegister 验证同一 user 多个连接并存。
func TestMultiClientRegister(t *testing.T) {
	h := NewHub(nil, nil, nil)
	go h.Run()

	c1 := newTestClient("user-1", "user")
	c2 := newTestClient("user-1", "user")

	h.Register <- c1
	h.Register <- c2

	// 给 hub goroutine 一点时间处理
	time.Sleep(10 * time.Millisecond)

	key := clientKey("user", "user-1")
	v, ok := h.clients.Load(key)
	if !ok {
		t.Fatal("key should exist after register")
	}
	list := v.([]*Client)
	if len(list) != 2 {
		t.Fatalf("expected 2 clients, got %d", len(list))
	}
}

// TestSendToUserBroadcastsToAll 验证 SendToUser 广播到所有同 user 连接。
func TestSendToUserBroadcastsToAll(t *testing.T) {
	h := NewHub(nil, nil, nil)
	go h.Run()

	c1 := newTestClient("user-1", "user")
	c2 := newTestClient("user-1", "user")

	h.Register <- c1
	h.Register <- c2
	time.Sleep(10 * time.Millisecond)

	msg := &model.WSMessage{Op: model.OpDispatch, T: model.EventMessageCreate, S: 1}
	h.SendToUser("user-1", msg)
	time.Sleep(10 * time.Millisecond)

	n1 := drainSend(c1)
	n2 := drainSend(c2)
	if n1 != 1 {
		t.Fatalf("client 1 should receive 1 message, got %d", n1)
	}
	if n2 != 1 {
		t.Fatalf("client 2 should receive 1 message, got %d", n2)
	}
}

// TestUnregisterRemovesOnlySelf 验证 client A + client B 同 key，A 退出后 B 仍能收到消息。
func TestUnregisterRemovesOnlySelf(t *testing.T) {
	h := NewHub(nil, nil, nil)
	go h.Run()

	c1 := newTestClient("user-1", "user")
	c2 := newTestClient("user-1", "user")

	h.Register <- c1
	h.Register <- c2
	time.Sleep(10 * time.Millisecond)

	h.Unregister <- c1
	time.Sleep(10 * time.Millisecond)

	key := clientKey("user", "user-1")
	v, ok := h.clients.Load(key)
	if !ok {
		t.Fatal("key should still exist after unregister one client")
	}
	list := v.([]*Client)
	if len(list) != 1 {
		t.Fatalf("expected 1 client remaining, got %d", len(list))
	}
	if list[0] != c2 {
		t.Fatal("remaining client should be c2")
	}

	// c2 应仍能收到消息
	msg := &model.WSMessage{Op: model.OpDispatch, T: model.EventMessageCreate, S: 1}
	h.SendToUser("user-1", msg)
	time.Sleep(10 * time.Millisecond)

	if n := drainSend(c2); n != 1 {
		t.Fatalf("c2 should still receive messages, got %d", n)
	}
}

// TestUnregisterLastCleansUp 验证唯一 client 退出后 key 被删除。
func TestUnregisterLastCleansUp(t *testing.T) {
	h := NewHub(nil, nil, nil)
	go h.Run()

	c1 := newTestClient("user-1", "user")
	h.Register <- c1
	time.Sleep(10 * time.Millisecond)

	h.Unregister <- c1
	time.Sleep(10 * time.Millisecond)

	key := clientKey("user", "user-1")
	if _, ok := h.clients.Load(key); ok {
		t.Fatal("key should be deleted after last client unregisters")
	}
}

// TestGcRemovesStaleClients 验证 LastHeartbeat 超时被 GC 清理。
func TestGcRemovesStaleClients(t *testing.T) {
	h := NewHub(nil, nil, nil)
	go h.Run()

	c1 := newTestClient("user-1", "user")
	c1.LastHeartbeat = time.Now().Add(-100 * time.Second) // 超过 90s

	h.Register <- c1
	time.Sleep(10 * time.Millisecond)

	// 手动触发 GC 避免等 ticker
	h.gcStaleClients()

	key := clientKey("user", "user-1")
	if _, ok := h.clients.Load(key); ok {
		t.Fatal("stale client should be removed by GC")
	}
}

// TestGcKeepsActiveClients 验证活跃 client 不被 GC 清理。
func TestGcKeepsActiveClients(t *testing.T) {
	h := NewHub(nil, nil, nil)
	go h.Run()

	c1 := newTestClient("user-1", "user")     // LastHeartbeat = time.Now()
	c2 := newTestClient("user-1", "user")
	c2.LastHeartbeat = time.Now().Add(-100 * time.Second) // 超时

	h.Register <- c1
	h.Register <- c2
	time.Sleep(10 * time.Millisecond)

	h.gcStaleClients()

	key := clientKey("user", "user-1")
	v, ok := h.clients.Load(key)
	if !ok {
		t.Fatal("active client key should still exist")
	}
	list := v.([]*Client)
	if len(list) != 1 {
		t.Fatalf("expected 1 active client, got %d", len(list))
	}
	if list[0] != c1 {
		t.Fatal("remaining client should be c1 (active)")
	}
}

// TestBufferedSendFullChannelDoesNotBlock 验证 Send 缓冲满时不阻塞或 panic。
func TestBufferedSendFullChannelDoesNotBlock(t *testing.T) {
	h := NewHub(nil, nil, nil)

	// 创建容量为 1 的 Send channel
	c := &Client{
		ID:            "test",
		Role:          "user",
		Send:          make(chan []byte, 1),
		LastHeartbeat: time.Now(),
	}
	c.Send <- []byte("prefill") // 填满通道

	// 发送多条消息，验证不阻塞
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func(seq int64) {
			defer wg.Done()
			d, _ := json.Marshal(map[string]int64{"seq": seq})
			msg := &model.WSMessage{Op: model.OpDispatch, T: model.EventMessageCreate, S: seq, D: d}
			h.bufferedSend(c, msg) // 不应 panic 或死锁
		}(int64(i))
	}

	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()

	select {
	case <-done:
		// 通过：所有调用完成
	case <-time.After(2 * time.Second):
		t.Fatal("bufferedSend blocked on full channel")
	}
}

// TestSendToUserMissingKeyReturnsNil 验证 key 不存在时 SendToUser 无副作用。
func TestSendToUserMissingKeyReturnsNil(t *testing.T) {
	h := NewHub(nil, nil, nil)
	go h.Run()

	msg := &model.WSMessage{Op: model.OpDispatch, T: model.EventMessageCreate, S: 1}
	if err := h.SendToUser("nonexistent", msg); err != nil {
		t.Fatalf("SendToUser should return nil for missing key, got %v", err)
	}
}

// TestIsUserViewingConv 验证「用户是否正在看某会话」的判断逻辑，
// 该判断决定 agent 发消息时要不要计未读（修复「看了却显示未读」）。
// 覆盖：单端在看、多端任一看、没连接、看的是别的会话。
func TestIsUserViewingConv(t *testing.T) {
	h := NewHub(nil, nil, nil)
	go h.Run()

	// user-1 两个连接（多端登录），分别在 convA 和 convB
	c1 := newTestClient("user-1", "user")
	c1.SetActiveConv("convA")
	c2 := newTestClient("user-1", "user")
	c2.SetActiveConv("convB")
	h.Register <- c1
	h.Register <- c2
	time.Sleep(10 * time.Millisecond)

	// 1. 任一连接在看 convA → true（c1 在看）
	if !h.IsUserViewingConv("user-1", "convA") {
		t.Error("user-1 should be viewing convA (via c1)")
	}
	// 2. 任一连接在看 convB → true（c2 在看）
	if !h.IsUserViewingConv("user-1", "convB") {
		t.Error("user-1 should be viewing convB (via c2)")
	}
	// 3. 没有任何连接在看 convC → false
	if h.IsUserViewingConv("user-1", "convC") {
		t.Error("user-1 should NOT be viewing convC")
	}
	// 4. 不存在的 user → false
	if h.IsUserViewingConv("user-2", "convA") {
		t.Error("nonexistent user-2 should not be viewing anything")
	}
	// 5. 清除 c1 的 activeConv 后，convA 不再有人看 → false
	c1.SetActiveConv("")
	time.Sleep(5 * time.Millisecond)
	if h.IsUserViewingConv("user-1", "convA") {
		t.Error("convA should not be viewed after c1 cleared")
	}
	// 6. convB 仍被 c2 看 → true
	if !h.IsUserViewingConv("user-1", "convB") {
		t.Error("convB should still be viewed by c2")
	}
}
