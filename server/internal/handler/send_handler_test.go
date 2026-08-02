package handler

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/hub"
	"github.com/wanling/server/internal/message"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// sendAsAgentEnv 汇聚 SendAsAgent 测试的可复用件。
//
// 与 updateContentEnv 同模式(testcontainers DB + user/agent/conv + 在线 user client
// 注册进 hub 捕获 MESSAGE_CREATE 广播),但服务于 SendHandler.SendAsAgent。
type sendAsAgentEnv struct {
	sh         *SendHandler
	db         *sql.DB
	userClient *hub.Client // 注册进 hub 的 user client,捕获 MESSAGE_CREATE 广播
	userID     string
	agentID    string
	convID     string
}

// setupSendAsAgentTest 起 testcontainers DB + user/agent/conv(DM,user 与 agent 互为 participant),
// 构造 SendHandler(复用真实 message.Processor),hub 注册一个在线 user client 模拟 APP 在线。
//
// 关键:不启动 hub.Run(测试不需要 goroutine 转发),PersistAndDispatch 在 commit 后
// 直接调 hub.SendToUser 同步写入 userClient.Send,测试侧从 channel 读即可。
func setupSendAsAgentTest(t *testing.T) sendAsAgentEnv {
	t.Helper()
	db := repository.SetupTestDB(t)
	userRepo := repository.NewUserRepo(db)
	agentRepo := repository.NewAgentRepo(db)
	convRepo := repository.NewConversationRepo(db)
	msgRepo := repository.NewMessageRepo(db)
	participantRepo := repository.NewParticipantRepo(db)
	deliveryRepo := repository.NewDeliveryRepo(db)
	fileRepo := repository.NewFileRepo(db)

	user, err := userRepo.Create(t.Context(), shortName(t, "sndagtu"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	agent, err := agentRepo.Create(t.Context(), user.ID, "Agent", "secret-key", "")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}
	conv, err := convRepo.FindOrCreateDM(t.Context(), "dm_user_agent", repository.DMMembers{
		Initiator: repository.ParticipantInput{MemberID: user.ID, MemberType: "user", Role: "owner"},
		Other:     repository.ParticipantInput{MemberID: agent.ID, MemberType: "agent", Role: "member"},
	})
	if err != nil {
		t.Fatalf("FindOrCreateDM 失败: %v", err)
	}

	// 与 production main.go 组装方式一致:hub + processor + sendHandler。
	// 不启动 hub.Run;SendToUser 直接同步写入目标 client 的 Send channel。
	h := hub.NewHub(nil, agentRepo, participantRepo, nil)
	processor := message.NewProcessor(h, convRepo, msgRepo, agentRepo, userRepo, fileRepo, participantRepo, deliveryRepo, nil, nil, nil)
	sh := NewSendHandler(processor)

	// 注册在线 user client(模拟 APP 在线),agent 发消息后会广播 MESSAGE_CREATE 到此 client。
	userClient := &hub.Client{
		ID:            user.ID,
		Role:          "user",
		Send:          make(chan []byte, 8),
		LastHeartbeat: time.Now(),
	}
	h.RegisterClient(userClient)

	return sendAsAgentEnv{
		sh:         sh,
		db:         db,
		userClient: userClient,
		userID:     user.ID,
		agentID:    agent.ID,
		convID:     conv.ID,
	}
}

// callSendAsAgent 构造 POST /api/conversations/:id/messages 的 gin context 并调 handler。
// actorID 注入 userID context key(production 下由 agentAuth 写入,值=agent_id);
// body 为请求体 JSON(已含 content 字段)。
func callSendAsAgent(t *testing.T, env sendAsAgentEnv, actorID, convID string, body []byte) *httptest.ResponseRecorder {
	t.Helper()
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPost, "/api/conversations/"+convID+"/messages", bytes.NewReader(body))
	c.Request.Header.Set("Content-Type", "application/json")
	c.Params = gin.Params{{Key: "id", Value: convID}}
	c.Set("userID", actorID)
	c.Set("role", "agent")
	env.sh.SendAsAgent(c)
	return w
}

// TestSendAsAgent_HappyPath agent 通过 REST 发消息:
//   - HTTP 200 + 响应 data.message_id 非空;
//   - DB 落了一条 agent 消息(可用 message_id 取出,sender_type=agent);
//   - MESSAGE_CREATE 广播到在线 user client(payload.id 与响应 message_id 一致)。
func TestSendAsAgent_HappyPath(t *testing.T) {
	env := setupSendAsAgentTest(t)

	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hello from agent"}}`)
	body, _ := json.Marshal(map[string]json.RawMessage{"content": content})

	w := callSendAsAgent(t, env, env.agentID, env.convID, body)
	data := AssertOk(t, w, http.StatusOK)
	msgID, _ := data["message_id"].(string)
	if msgID == "" {
		t.Fatalf("响应 data.message_id 为空, body=%s", w.Body.String())
	}
	if _, ok := data["created_at"]; !ok {
		t.Errorf("响应应含 created_at, 实际 %v", data)
	}

	// 验证 DB 落库:按 message_id 取,sender_type 应为 agent
	msgRepo := repository.NewMessageRepo(env.db)
	got, err := msgRepo.Get(t.Context(), msgID)
	if err != nil || got == nil {
		t.Fatalf("DB 取消息失败 msgID=%s err=%v", msgID, err)
	}
	if got.SenderType != "agent" || got.SenderID != env.agentID {
		t.Errorf("DB sender 期望 agent/%s, 实际 %s/%s", env.agentID, got.SenderType, got.SenderID)
	}

	// 验证 MESSAGE_CREATE 广播到在线 user client
	select {
	case raw := <-env.userClient.Send:
		var wsMsg model.WSMessage
		if err := json.Unmarshal(raw, &wsMsg); err != nil {
			t.Fatalf("unmarshal ws 失败: %v", err)
		}
		if wsMsg.T != model.EventMessageCreate {
			t.Fatalf("期望 MESSAGE_CREATE, 实际 %s", wsMsg.T)
		}
		var payload map[string]any
		if err := json.Unmarshal(wsMsg.D, &payload); err != nil {
			t.Fatalf("unmarshal payload 失败: %v", err)
		}
		if payload["id"] != msgID {
			t.Errorf("payload.id 期望 %s, 实际 %v", msgID, payload["id"])
		}
		if payload["conversation_id"] != env.convID {
			t.Errorf("payload.conversation_id 期望 %s, 实际 %v", env.convID, payload["conversation_id"])
		}
		if payload["sender_type"] != "agent" {
			t.Errorf("payload.sender_type 期望 agent, 实际 %v", payload["sender_type"])
		}
	case <-time.After(200 * time.Millisecond):
		t.Fatal("未收到 MESSAGE_CREATE 广播")
	}
}

// TestSendAsAgent_NotParticipant 非 participant agent 发消息 → 403。
//
// 另建一个 agent2(不属于 env.convID 的 participant),用它的 id 注入鉴权上下文发消息,
// PersistAndDispatch 会返 ErrNotParticipant,handler 映射为 403。
// 关键:必须用真实存在的 agent(否则 Exists 查询返 false 同样 403,但语义会混淆),
// 这里建 agent2 + 它与 user 的另一个 DM,确保 agent2 真实存在但不是 env.convID 的成员。
func TestSendAsAgent_NotParticipant(t *testing.T) {
	env := setupSendAsAgentTest(t)

	// 另建 agent2(同一 owner,真实存在的 agent,但不是 env.convID 的 participant)
	agentRepo := repository.NewAgentRepo(env.db)
	agent2, err := agentRepo.Create(t.Context(), env.userID, "Agent2", "secret-key2", "")
	if err != nil {
		t.Fatalf("Create agent2 失败: %v", err)
	}

	content := json.RawMessage(`{"msg_type":"text","data":{"text":"intruder"}}`)
	body, _ := json.Marshal(map[string]json.RawMessage{"content": content})

	w := callSendAsAgent(t, env, agent2.ID, env.convID, body)
	AssertErr(t, w, http.StatusForbidden, "forbidden")

	// 403 路径在 dispatch 之前 return,不应有 MESSAGE_CREATE 广播
	select {
	case <-env.userClient.Send:
		t.Fatal("非 participant 不应触发广播")
	case <-time.After(50 * time.Millisecond):
	}
}

// TestSendAsAgent_MissingMsgType content 缺 msg_type → 400,不落库不广播。
func TestSendAsAgent_MissingMsgType(t *testing.T) {
	env := setupSendAsAgentTest(t)

	badContent := json.RawMessage(`{"data":{"text":"no msg_type"}}`)
	body, _ := json.Marshal(map[string]json.RawMessage{"content": badContent})

	w := callSendAsAgent(t, env, env.agentID, env.convID, body)
	AssertErr(t, w, http.StatusBadRequest, "bad_request")
}

// TestSendAsAgent_ContentNotObject content 不是 JSON object(数组)→ 400。
func TestSendAsAgent_ContentNotObject(t *testing.T) {
	env := setupSendAsAgentTest(t)

	badContent := json.RawMessage(`["not","an","object"]`)
	body, _ := json.Marshal(map[string]json.RawMessage{"content": badContent})

	w := callSendAsAgent(t, env, env.agentID, env.convID, body)
	AssertErr(t, w, http.StatusBadRequest, "bad_request")
}

// TestSendAsAgent_MissingContent 缺 content 字段 → 400(binding:"required" 拦截)。
func TestSendAsAgent_MissingContent(t *testing.T) {
	env := setupSendAsAgentTest(t)

	body := []byte(`{}`)
	w := callSendAsAgent(t, env, env.agentID, env.convID, body)
	AssertErr(t, w, http.StatusBadRequest, "bad_request")
}
