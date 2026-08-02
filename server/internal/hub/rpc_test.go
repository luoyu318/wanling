package hub

import (
	"context"
	"sync"
	"testing"
	"time"
)

func TestRPCRegistry_RegisterAndResolve(t *testing.T) {
	r := NewRPCRegistry()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	id, ch := r.Register(ctx, "agent-A")

	resp := &RPCResponse{Result: []byte(`{"echo":"hi"}`)}
	if !r.Resolve(id, resp) {
		t.Fatalf("Resolve 返回 false,期望 true")
	}

	select {
	case got := <-ch:
		if string(got.Result) != `{"echo":"hi"}` {
			t.Fatalf("期望 result {\"echo\":\"hi\"}, 实际 %s", got.Result)
		}
	case <-time.After(time.Second):
		t.Fatalf("等结果超时")
	}
}

func TestRPCRegistry_DefaultTimeoutWhenCtxHasNoDeadline(t *testing.T) {
	// 临时把默认超时调小到 50ms,避免真等 60s 拖慢 CI;t.Cleanup 跑完恢复。
	original := rpcDefaultTimeout
	rpcDefaultTimeout = 50 * time.Millisecond
	t.Cleanup(func() { rpcDefaultTimeout = original })

	r := NewRPCRegistry()
	ctx := context.Background() // 无 deadline,Registry 应自动加 rpcDefaultTimeout

	id, ch := r.Register(ctx, "agent-A")

	select {
	case got := <-ch:
		if got.Err == nil || got.Err.Code != -32002 {
			t.Fatalf("期望自动超时 -32002, 实际 %v", got.Err)
		}
	case <-time.After(time.Second):
		t.Fatalf("等默认超时信号超时(应 50ms 触发)")
	}

	if r.Resolve(id, &RPCResponse{Result: []byte(`{}`)}) {
		t.Fatalf("超时后 Resolve 应返回 false")
	}
}

func TestRPCRegistry_RespectsCallerDeadline(t *testing.T) {
	r := NewRPCRegistry()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()

	id, ch := r.Register(ctx, "agent-A")

	select {
	case got := <-ch:
		if got.Err == nil {
			t.Fatalf("期望 timeout error, 实际拿到 result=%s", got.Result)
		}
		if got.Err.Code != -32002 {
			t.Fatalf("期望 code -32002, 实际 %d", got.Err.Code)
		}
	case <-time.After(time.Second):
		t.Fatalf("等超时信号超时")
	}

	if r.Resolve(id, &RPCResponse{Result: []byte(`{}`)}) {
		t.Fatalf("超时后 Resolve 应返回 false")
	}
}

func TestRPCRegistry_CancelAllForAgent(t *testing.T) {
	r := NewRPCRegistry()
	ctx1, cancel1 := context.WithCancel(context.Background())
	defer cancel1()
	ctx2, cancel2 := context.WithCancel(context.Background())
	defer cancel2()
	ctx3, cancel3 := context.WithCancel(context.Background())
	defer cancel3()

	// agent-A 有两个 pending,agent-B 有一个 pending
	id1, ch1 := r.Register(ctx1, "agent-A")
	id2, ch2 := r.Register(ctx2, "agent-A")
	id3, ch3 := r.Register(ctx3, "agent-B")

	// agent-A 还没 cancel,agent-B 的不应被动
	r.CancelAllForAgent("agent-A")

	// agent-A 的两个 ch 都收到 -32003
	for i, ch := range []<-chan *RPCResponse{ch1, ch2} {
		select {
		case got := <-ch:
			if got.Err == nil || got.Err.Code != -32003 {
				t.Fatalf("ch%d 期望 -32003 plugin_disconnected, 实际 %v", i+1, got.Err)
			}
		case <-time.After(time.Second):
			t.Fatalf("ch%d 等信号超时", i+1)
		}
	}

	// agent-B 的 ch 不应被影响(仍 pending)
	select {
	case <-ch3:
		t.Fatalf("agent-B 的 pending 不应被 CancelAllForAgent(agent-A) 触发")
	case <-time.After(100 * time.Millisecond):
	}

	// agent-B 的 pending 仍可被 Resolve
	if !r.Resolve(id3, &RPCResponse{Result: []byte(`{}`)}) {
		t.Fatalf("id3 应仍可 Resolve")
	}

	// 已被 cancel 的 id1/id2 不可再 Resolve
	if r.Resolve(id1, &RPCResponse{Result: []byte(`{}`)}) {
		t.Fatalf("id1 已 cancel,Resolve 应 false")
	}
	if r.Resolve(id2, &RPCResponse{Result: []byte(`{}`)}) {
		t.Fatalf("id2 已 cancel,Resolve 应 false")
	}
}

func TestRPCRegistry_ConcurrentSafe(t *testing.T) {
	r := NewRPCRegistry()
	var wg sync.WaitGroup
	for i := 0; i < 100; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
			defer cancel()
			id, ch := r.Register(ctx, "agent-concurrent")
			go func() {
				r.Resolve(id, &RPCResponse{Result: []byte(`{}`)})
				cancel()
			}()
			<-ch
		}(i)
	}
	wg.Wait()
}

// TestHub_UnregisterCancelsAgentRPC 验证 spec §12 的 fail-fast wiring:
// plugin(agent 角色)WS 断线触发 hub.Unregister 后,该 agent 名下所有 pending RPC
// 必须立即收到 -32003 plugin_disconnected,而不是等 60s 默认超时返 -32002。
//
// 这是 Task 4 review §4 标记的 Critical gap 的回归测试:
// 接线缺失时本测试会 1s 超时失败(等不到 -32003);接线恢复后立即 PASS。
func TestHub_UnregisterCancelsAgentRPC(t *testing.T) {
	rpcReg := NewRPCRegistry()
	h := NewHub(nil, nil, nil, rpcReg)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	go h.Run(ctx)
	defer func() {
		cancel()
		time.Sleep(50 * time.Millisecond) // 让 hub.Run select 退出
	}()

	// 用 RegisterClient 直接写 clients map,绕开 Register 分支的 agentRepo.GetByID 副作用
	// (hub_test.go 同模式:测试不依赖 repo,presence nil-safe)。
	// Unregister 仍走 channel → hub.Run select 路径,这是本测试要验证的接线点。
	fakeClient := newTestClient("agent-1", "agent")
	h.RegisterClient(fakeClient)

	// 注册一个 pending RPC 绑定 agent-1
	_, ch := rpcReg.Register(context.Background(), "agent-1")

	// 模拟 plugin WS 断线:发 Unregister 信号
	h.Unregister <- fakeClient

	// 期望 ch 立即收到 -32003 plugin_disconnected(而非等 60s 超时返 -32002)
	select {
	case got := <-ch:
		if got.Err == nil {
			t.Fatalf("期望收到 *RPCError(-32003),实际收到 result=%s", got.Result)
		}
		if got.Err.Code != rpcErrDisconnected {
			t.Fatalf("期望 code=%d(plugin_disconnected), 实际 %d (msg=%s)",
				rpcErrDisconnected, got.Err.Code, got.Err.Message)
		}
	case <-time.After(time.Second):
		t.Fatalf("等 -32003 信号超时(应立即触发,不等 60s 默认超时);hub.Unregister → rpcRegistry.CancelAllForAgent 接线可能缺失")
	}
}
