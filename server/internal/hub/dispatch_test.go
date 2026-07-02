package hub

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
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

// seedHubParticipantDB 起 testdb + 插入 1 个 user + 1 个 agent + 1 个 conv + 2 个 participant。
// 专供 SendToConv 路由测试用(N 方模型,SendToConv 按 participants 遍历路由)。
// 返回 hub(已注入 participantRepo)+ convID + userID + agentID。
//
// 不复用 repository.seedParticipantsTestDB 是因为跨 package,且 hub 测试只需最小 seed。
func seedHubParticipantDB(t *testing.T) (*Hub, string, string, string) {
	t.Helper()
	db := repository.SetupTestDB(t)
	partRepo := repository.NewParticipantRepo(db)
	h := NewHub(nil, nil, partRepo)

	now := time.Now().UTC()
	var userID, agentID, convID string
	if err := db.QueryRow(`
		INSERT INTO users (username, password_hash, avatar_url, created_at)
		VALUES ($1, $2, '', $3) RETURNING id
	`, "hubu_"+t.Name(), "hash", now).Scan(&userID); err != nil {
		t.Fatalf("seed user 失败: %v", err)
	}
	if err := db.QueryRow(`
		INSERT INTO agents (owner_id, name, avatar_url, secret_key, status, created_at)
		VALUES ($1, 'HubAgent', '', 'sk', 'offline', $2) RETURNING id
	`, userID, now).Scan(&agentID); err != nil {
		t.Fatalf("seed agent 失败: %v", err)
	}
	if err := db.QueryRow(`
		INSERT INTO conversations (created_at) VALUES ($1) RETURNING id
	`, now).Scan(&convID); err != nil {
		t.Fatalf("seed conversation 失败: %v", err)
	}
	tx, err := db.Begin()
	if err != nil {
		t.Fatalf("begin tx: %v", err)
	}
	if err := partRepo.AddParticipantsTx(tx, convID, []repository.ParticipantInput{
		{MemberID: userID, MemberType: "user", Role: "owner"},
		{MemberID: agentID, MemberType: "agent", Role: "member"},
	}); err != nil {
		t.Fatalf("AddParticipants: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit: %v", err)
	}
	return h, convID, userID, agentID
}

// TestBroadcastMessageUpdateDualEnd 验证 MESSAGE_UPDATE 按 participants 路由,
// user 和 agent 双端都收到。N 方模型后 SendToConv 走 participantRepo.ListByConversation。
func TestBroadcastMessageUpdateDualEnd(t *testing.T) {
	h, convID, userID, agentID := seedHubParticipantDB(t)

	user := newTestClient(userID, "user")
	agent := newTestClient(agentID, "agent")
	registerDirect(h, user)
	registerDirect(h, agent)

	content, _ := json.Marshal(map[string]string{"msg_type": "card", "state": "approved"})
	h.BroadcastMessageUpdate(convID, "msg-1", content)

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
		if payload["conversation_id"] != convID {
			t.Fatalf("expected conversation_id=%s, got %v", convID, payload["conversation_id"])
		}
	}
}

// TestSendApprovalDecidedOnlyToAgent 验证 APPROVAL_DECIDED 只发给 agent。
func TestSendApprovalDecidedOnlyToAgent(t *testing.T) {
	h := NewHub(nil, nil, nil)

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
	h := NewHub(nil, nil, nil)

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
	h := NewHub(nil, nil, nil)
	prev := h.NextSeq()
	for i := 0; i < 10; i++ {
		cur := h.NextSeq()
		if cur <= prev {
			t.Fatalf("seq not monotonic: prev=%d cur=%d", prev, cur)
		}
		prev = cur
	}
}

// TestBroadcastOfflineNoOp 验证离线/无 participants 场景无副作用（不 panic）。
// 覆盖三种情况:
//   - participantRepo 未注入(SendToConv fail-closed 日志后 return,不推)
//   - SendApproval* 给不存在的 agent(SendToAgent key 不存在返 nil)
func TestBroadcastOfflineNoOp(t *testing.T) {
	h := NewHub(nil, nil, nil)

	content, _ := json.Marshal(map[string]string{"msg_type": "card"})
	// 不应 panic;participantRepo=nil 时 SendToConv fail-closed 直接 return
	h.BroadcastMessageUpdate("c-no-repo", "m", content)
	h.SendApprovalDecided("no-agent", map[string]any{"k": "v"})
	h.SendApprovalExpired("no-agent", map[string]any{"k": "v"})

	// 给一点时间确保没异步崩
	time.Sleep(10 * time.Millisecond)
}
