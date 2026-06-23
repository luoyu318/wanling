package hub

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/wanling/server/internal/model"
)

// recvOne 从 client.Send 取一条消息并反序列化，超时失败。
func recvOne(t *testing.T, c *Client) *model.WSMessage {
	t.Helper()
	select {
	case data := <-c.Send:
		var got model.WSMessage
		if err := json.Unmarshal(data, &got); err != nil {
			t.Fatalf("unmarshal failed: %v", err)
		}
		return &got
	case <-time.After(200 * time.Millisecond):
		t.Fatal("no message received within 200ms")
		return nil
	}
}

// recvNone 断言 client.Send 在 50ms 内无消息。
func recvNone(t *testing.T, c *Client, what string) {
	t.Helper()
	select {
	case <-c.Send:
		t.Fatalf("%s should NOT receive the message", what)
	case <-time.After(50 * time.Millisecond):
	}
}

// registerDirect 直接预置 clients map，绕开 Hub.Run 的 agent 分支
// （该分支会调 agentRepo.GetByID，测试场景下 repo 为 nil）。
// 仅测 dispatch 路径，不走注册副作用。
func registerDirect(h *Hub, c *Client) {
	h.clients.Store(clientKey(c.Role, c.ID), []*Client{c})
}

// TestBroadcastMessageUpdateDualEnd 验证 MESSAGE_UPDATE 同时送达 user 和 agent。
func TestBroadcastMessageUpdateDualEnd(t *testing.T) {
	h := NewHub(nil, nil)

	user := newTestClient("user-1", "user")
	agent := newTestClient("agent-1", "agent")
	registerDirect(h, user)
	registerDirect(h, agent)

	content, _ := json.Marshal(map[string]string{"msg_type": "card", "state": "approved"})
	h.BroadcastMessageUpdate("user-1", "agent-1", "msg-1", "conv-1", content)

	for _, c := range []*Client{user, agent} {
		got := recvOne(t, c)
		if got.T != model.EventMessageUpdate {
			t.Fatalf("expected MESSAGE_UPDATE, got %s", got.T)
		}
		if got.S == 0 {
			t.Fatal("seq should be allocated (>0)")
		}
		var payload map[string]any
		if err := json.Unmarshal(got.D, &payload); err != nil {
			t.Fatalf("unmarshal payload: %v", err)
		}
		if payload["message_id"] != "msg-1" {
			t.Fatalf("expected message_id=msg-1, got %v", payload["message_id"])
		}
		if payload["conversation_id"] != "conv-1" {
			t.Fatalf("expected conversation_id=conv-1, got %v", payload["conversation_id"])
		}
	}
}

// TestSendApprovalDecidedOnlyToAgent 验证 APPROVAL_DECIDED 只发给 agent。
func TestSendApprovalDecidedOnlyToAgent(t *testing.T) {
	h := NewHub(nil, nil)

	agent := newTestClient("agent-1", "agent")
	user := newTestClient("user-1", "user")
	registerDirect(h, agent)
	registerDirect(h, user)

	h.SendApprovalDecided("agent-1", map[string]any{
		"approval_id": "a-1",
		"session_key": "k",
		"decision":    "allow_once",
	})

	got := recvOne(t, agent)
	if got.T != model.EventApprovalDecided {
		t.Fatalf("expected APPROVAL_DECIDED, got %s", got.T)
	}
	var payload map[string]any
	if err := json.Unmarshal(got.D, &payload); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}
	if payload["approval_id"] != "a-1" {
		t.Fatalf("expected approval_id=a-1, got %v", payload["approval_id"])
	}
	if payload["decision"] != "allow_once" {
		t.Fatalf("expected decision=allow_once, got %v", payload["decision"])
	}

	recvNone(t, user, "user")
}

// TestSendApprovalExpiredOnlyToAgent 验证 APPROVAL_EXPIRED 只发给 agent。
func TestSendApprovalExpiredOnlyToAgent(t *testing.T) {
	h := NewHub(nil, nil)

	agent := newTestClient("agent-1", "agent")
	user := newTestClient("user-1", "user")
	registerDirect(h, agent)
	registerDirect(h, user)

	h.SendApprovalExpired("agent-1", map[string]any{
		"approval_id": "a-2",
		"session_key": "k2",
	})

	got := recvOne(t, agent)
	if got.T != model.EventApprovalExpired {
		t.Fatalf("expected APPROVAL_EXPIRED, got %s", got.T)
	}
	var payload map[string]any
	if err := json.Unmarshal(got.D, &payload); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}
	if payload["approval_id"] != "a-2" {
		t.Fatalf("expected approval_id=a-2, got %v", payload["approval_id"])
	}

	recvNone(t, user, "user")
}

// TestNextSeqMonotonic 验证 NextSeq 单调递增。
func TestNextSeqMonotonic(t *testing.T) {
	h := NewHub(nil, nil)
	prev := h.NextSeq()
	for i := 0; i < 10; i++ {
		cur := h.NextSeq()
		if cur <= prev {
			t.Fatalf("seq not monotonic: prev=%d cur=%d", prev, cur)
		}
		prev = cur
	}
}

// TestBroadcastOfflineNoOp 验证双端都离线时无副作用（不 panic）。
func TestBroadcastOfflineNoOp(t *testing.T) {
	h := NewHub(nil, nil)

	content, _ := json.Marshal(map[string]string{"msg_type": "card"})
	// 不应 panic
	h.BroadcastMessageUpdate("no-user", "no-agent", "m", "c", content)
	h.SendApprovalDecided("no-agent", map[string]any{"k": "v"})
	h.SendApprovalExpired("no-agent", map[string]any{"k": "v"})

	// 给一点时间确保没异步崩
	time.Sleep(10 * time.Millisecond)
}
