package handler

import (
	"context"
	"database/sql"
	"encoding/json"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/wanling/server/internal/hub"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// TestCheckOrigin_SameOrigin 验证 allowedOrigins 为空时,Origin host == Host header 同源放行。
func TestCheckOrigin_SameOrigin(t *testing.T) {
	h := &WSHandler{allowedOrigins: nil}
	req := httptest.NewRequest("GET", "/", nil)
	req.Host = "example.com"
	req.Header.Set("Origin", "http://example.com")
	if !h.checkOrigin(req) {
		t.Fatal("同源应放行")
	}
}

// TestCheckOrigin_CrossOriginRejected 验证 allowedOrigins 为空时,跨源 Origin 被拒。
func TestCheckOrigin_CrossOriginRejected(t *testing.T) {
	h := &WSHandler{allowedOrigins: nil}
	req := httptest.NewRequest("GET", "/", nil)
	req.Host = "example.com"
	req.Header.Set("Origin", "http://evil.com")
	if h.checkOrigin(req) {
		t.Fatal("跨源应拒绝")
	}
}

// TestCheckOrigin_WhitelistPriority 验证白名单优先于同源:
// 配置白名单后,即便 Origin 与 Host 同源也不在白名单内 → 拒绝;
// 在白名单内 → 放行(不要求同源)。
func TestCheckOrigin_WhitelistPriority(t *testing.T) {
	h := &WSHandler{allowedOrigins: []string{"http://dev.com"}}
	req := httptest.NewRequest("GET", "/", nil)
	req.Host = "example.com"
	// 同源但不在白名单 → 拒绝(白名单优先)
	req.Header.Set("Origin", "http://example.com")
	if h.checkOrigin(req) {
		t.Fatal("白名单存在时,非白名单同源应拒绝")
	}
	// 白名单内 → 放行
	req.Header.Set("Origin", "http://dev.com")
	if !h.checkOrigin(req) {
		t.Fatal("白名单内应放行")
	}
}

// TestCheckOrigin_NoOriginHeader 验证无 Origin 头(非浏览器 client,如 plugin adapter)始终放行。
func TestCheckOrigin_NoOriginHeader(t *testing.T) {
	h := &WSHandler{allowedOrigins: nil}
	req := httptest.NewRequest("GET", "/", nil)
	req.Host = "example.com"
	if !h.checkOrigin(req) {
		t.Fatal("无 Origin 头(非浏览器 client)应放行")
	}
}

func TestWSHandler_OpPluginResult_RoutesToRegistry(t *testing.T) {
	rpcReg := hub.NewRPCRegistry()

	id, ch := rpcReg.Register(t.Context(), "agent-1")

	wsMsg := model.WSMessage{
		Op: model.OpPluginResult,
		D:  []byte(`{"jsonrpc":"2.0","id":"` + id + `","result":{"echo":"hi"}}`),
	}

	h := newTestWSHandler(rpcReg)
	h.routeAgentIncoming(t.Context(), "agent-1", &wsMsg)

	got := <-ch
	if string(got.Result) != `{"echo":"hi"}` {
		t.Fatalf("期望 {\"echo\":\"hi\"}, 实际 %s", got.Result)
	}
}

func TestWSHandler_OpPluginResult_UnknownIDNoop(t *testing.T) {
	rpcReg := hub.NewRPCRegistry()

	wsMsg := model.WSMessage{
		Op: model.OpPluginResult,
		D:  []byte(`{"jsonrpc":"2.0","id":"non-existent","result":{}}`),
	}

	h := newTestWSHandler(rpcReg)
	h.routeAgentIncoming(t.Context(), "agent-1", &wsMsg)
}

func newTestWSHandler(rpcReg *hub.RPCRegistry) *WSHandler {
	return &WSHandler{rpcRegistry: rpcReg}
}

// === OpStream(op=14)入站路由三态测试 ===
// 复盘 reviewer 发现:readPump 的 case model.OpStream 分支(role 门禁 + IDOR 接线)零覆盖。
// 现已把该逻辑提取为 handleOpStream,此处直调验证三态。

// recvStream 从 client.Send 取一条消息并反序列化,超时失败。
func recvStream(t *testing.T, c *hub.Client) *model.WSMessage {
	t.Helper()
	select {
	case data := <-c.Send:
		var got model.WSMessage
		if err := json.Unmarshal(data, &got); err != nil {
			t.Fatalf("unmarshal failed: %v", err)
		}
		return &got
	case <-time.After(200 * time.Millisecond):
		t.Fatal("200ms 内未收到消息")
		return nil
	}
}

// recvNoneStream 断言 client.Send 在 50ms 内无消息(未透传)。
func recvNoneStream(t *testing.T, c *hub.Client, what string) {
	t.Helper()
	select {
	case <-c.Send:
		t.Fatalf("%s 不应收到消息", what)
	case <-time.After(50 * time.Millisecond):
	}
}

// seedStreamHandlerDB 起 testcontainers 真 PG + 注入真实 participantRepo 的 hub,
// seed 1 user + 1 agent + 1 conv + 2 participants。返回 hub + db + 三 ID。
// handler 包无 hub.seedHubParticipantDB(跨 package 私有),本处最小复刻。
func seedStreamHandlerDB(t *testing.T) (h *hub.Hub, db *sql.DB, convID, userID, agentID string) {
	t.Helper()
	db = repository.SetupTestDB(t)
	partRepo := repository.NewParticipantRepo(db)
	h = hub.NewHub(nil, nil, partRepo, nil)

	now := time.Now().UTC()
	if err := db.QueryRow(`
		INSERT INTO users (username, password_hash, avatar_url, created_at)
		VALUES ($1, $2, '', $3) RETURNING id
	`, "wsu_"+t.Name(), "hash", now).Scan(&userID); err != nil {
		t.Fatalf("seed user 失败: %v", err)
	}
	if err := db.QueryRow(`
		INSERT INTO agents (owner_id, name, avatar_url, secret_key, created_at)
		VALUES ($1, 'StreamAgent', '', 'sk', $2) RETURNING id
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
	if err := partRepo.AddParticipantsTx(t.Context(), tx, convID, []repository.ParticipantInput{
		{MemberID: userID, MemberType: "user", Role: "owner"},
		{MemberID: agentID, MemberType: "agent", Role: "member"},
	}); err != nil {
		t.Fatalf("AddParticipants: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit: %v", err)
	}
	return h, db, convID, userID, agentID
}

// TestHandleOpStream_AgentParticipantForwarded:agent 是会话 participant →
// 透传成功,正在观看该会话的 user client 收到 op=14 STREAM。
func TestHandleOpStream_AgentParticipantForwarded(t *testing.T) {
	h, _, convID, userID, agentID := seedStreamHandlerDB(t)

	user := hub.NewClient(context.Background(), userID, "user", nil)
	user.SetActiveConv(convID)
	h.RegisterClient(user)

	agent := hub.NewClient(context.Background(), agentID, "agent", nil)

	wsh := &WSHandler{hub: h}
	data, _ := json.Marshal(map[string]any{
		"conversation_id": convID,
		"stream_id":       "s-1",
		"msg_type":        "reasoning",
		"text":            "思考中",
	})
	wsh.handleOpStream(agent, data)

	got := recvStream(t, user)
	if got.Op != model.OpStream {
		t.Fatalf("期望 op=%d(STREAM), 实际 op=%d", model.OpStream, got.Op)
	}
	var p map[string]any
	if err := json.Unmarshal(got.D, &p); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}
	if p["stream_id"] != "s-1" {
		t.Fatalf("期望 stream_id=s-1, 实际 %v", p["stream_id"])
	}
}

// TestHandleOpStream_AgentNonParticipantRejected:agent 非该会话 participant(IDOR) →
// fail-closed 拒绝,正在观看的 user client 收不到任何消息。
// 构造一个 user 是 participant 但 agent 不是的 conv,验证 IDOR 门禁。
func TestHandleOpStream_AgentNonParticipantRejected(t *testing.T) {
	h, db, _, userID, agentID := seedStreamHandlerDB(t)

	// 第二个 conv:仅 user 是 participant,seeded agent 未加入
	now := time.Now().UTC()
	var convID2 string
	if err := db.QueryRow(`INSERT INTO conversations (created_at) VALUES ($1) RETURNING id`, now).Scan(&convID2); err != nil {
		t.Fatalf("seed conv2 失败: %v", err)
	}
	partRepo := repository.NewParticipantRepo(db)
	tx, err := db.Begin()
	if err != nil {
		t.Fatalf("begin tx: %v", err)
	}
	if err := partRepo.AddParticipantsTx(t.Context(), tx, convID2, []repository.ParticipantInput{
		{MemberID: userID, MemberType: "user", Role: "owner"},
	}); err != nil {
		t.Fatalf("AddParticipants conv2: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit: %v", err)
	}

	// user 正在观看 conv2(若 IDOR 失守,这里会收到)
	user := hub.NewClient(context.Background(), userID, "user", nil)
	user.SetActiveConv(convID2)
	h.RegisterClient(user)

	// seeded agent 不是 conv2 的 participant
	agent := hub.NewClient(context.Background(), agentID, "agent", nil)

	wsh := &WSHandler{hub: h}
	data, _ := json.Marshal(map[string]any{
		"conversation_id": convID2,
		"stream_id":       "leak",
	})
	wsh.handleOpStream(agent, data)

	recvNoneStream(t, user, "user(IDOR 拒绝)")
}

// TestHandleOpStream_UserRoleRejected:user 发 op=14 → role 门禁拒绝,不透传。
// sender 用 participant user(即便 IDOR 会过,role 门禁仍先拦截)。
func TestHandleOpStream_UserRoleRejected(t *testing.T) {
	h, _, convID, userID, _ := seedStreamHandlerDB(t)

	// 观看的 user(若 role 门禁失守,这里会收到)
	viewer := hub.NewClient(context.Background(), userID, "user", nil)
	viewer.SetActiveConv(convID)
	h.RegisterClient(viewer)

	// 另一端 user 作为 sender(user 不允许发 op=14)
	sender := hub.NewClient(context.Background(), userID, "user", nil)

	wsh := &WSHandler{hub: h}
	data, _ := json.Marshal(map[string]any{
		"conversation_id": convID,
		"stream_id":       "leak",
	})
	wsh.handleOpStream(sender, data)

	recvNoneStream(t, viewer, "viewer(role 拒绝)")
}
