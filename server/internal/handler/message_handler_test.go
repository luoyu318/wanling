package handler

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/hub"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// setupMessageHandlerTest 起 testcontainers DB + 建一个 user/agent/conv + 1 条消息,
// 返回可复用的 gin engine / repo / 关键 id / db 引用。
// 鉴权用 c.Set("userID"/"role") 绕过真实 JWT(与 conversation_handler_test 同模式),
// 专注测 handler 逻辑而非鉴权(鉴权由 AuthMiddleware 单测覆盖)。
type msgTestEnv struct {
	engine   *gin.Engine
	db       *sql.DB
	msgRepo  *repository.MessageRepo
	convRepo *repository.ConversationRepo
	userID   string
	agentID  string
	convID   string
}

func setupMessageHandlerTest(t *testing.T) msgTestEnv {
	t.Helper()
	db := repository.SetupTestDB(t)
	userRepo := repository.NewUserRepo(db)
	agentRepo := repository.NewAgentRepo(db)
	convRepo := repository.NewConversationRepo(db)
	msgRepo := repository.NewMessageRepo(db)
	participantRepo := repository.NewParticipantRepo(db)

	user, err := userRepo.Create(t.Context(), shortName(t, "msguser"), "$2a$10$hash")
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

	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`)
	_, err = msgRepo.Create(t.Context(), conv.ID, "user", user.ID, content)
	if err != nil {
		t.Fatalf("Create msg 失败: %v", err)
	}

	// 不启动 hub.Run(测试不需要真实广播),给个 NewHub 实例即可。
	// presence 传 nil —— handler 测试不验证广播投递,只验证不 panic。
	h := hub.NewHub(nil, agentRepo, participantRepo, nil)

	mh := NewMessageHandler(msgRepo, convRepo, participantRepo, userRepo, agentRepo, h)
	r := gin.New()
	// 用 c.Set 绕过 AuthMiddleware,直接注入鉴权上下文。
	del := func(c *gin.Context) { c.Set("userID", user.ID); c.Set("role", "user"); mh.Delete(c) }
	bdel := func(c *gin.Context) { c.Set("userID", user.ID); c.Set("role", "user"); mh.BatchDelete(c) }
	getCtx := func(c *gin.Context) { c.Set("userID", user.ID); c.Set("role", "user"); mh.GetMessageContext(c) }
	r.DELETE("/api/messages/:id", del)
	r.POST("/api/messages/batch-delete", bdel)
	r.GET("/api/messages/:id/context", getCtx)

	return msgTestEnv{
		engine: r, db: db, msgRepo: msgRepo, convRepo: convRepo,
		userID: user.ID, agentID: agent.ID, convID: conv.ID,
	}
}

// TestMessageHandler_Delete_HappyPath 单删成功,返回 204,消息从列表消失。
func TestMessageHandler_Delete_HappyPath(t *testing.T) {
	env := setupMessageHandlerTest(t)
	list, _ := env.msgRepo.ListByConversation(t.Context(), env.convID, env.userID, "user", 50, 0)
	if len(list) != 1 {
		t.Fatalf("前置:应有 1 条消息,实际 %d", len(list))
	}
	msgID := list[0].ID

	req := httptest.NewRequest(http.MethodDelete, "/api/messages/"+msgID, nil)
	w := httptest.NewRecorder()
	env.engine.ServeHTTP(w, req)

	if w.Code != http.StatusNoContent {
		t.Fatalf("应返回 204,实际 %d body=%s", w.Code, w.Body.String())
	}
	list, _ = env.msgRepo.ListByConversation(t.Context(), env.convID, env.userID, "user", 50, 0)
	if len(list) != 0 {
		t.Errorf("删除后应无消息,实际 %d", len(list))
	}
}

// TestMessageHandler_Delete_NotFound 不存在的消息 id 返回 404。
// 用合法 UUID 格式(否则 Postgres 在 uuid 列上报 syntax error → 500 而非 404)。
func TestMessageHandler_Delete_NotFound(t *testing.T) {
	env := setupMessageHandlerTest(t)
	req := httptest.NewRequest(http.MethodDelete, "/api/messages/00000000-0000-0000-0000-000000000000", nil)
	w := httptest.NewRecorder()
	env.engine.ServeHTTP(w, req)
	AssertErr(t, w, http.StatusNotFound, "not_found")
}

// TestMessageHandler_Delete_Forbidden 删别人会话的消息返回 403。
// 另建一个 user2 的会话,user 试图删 user2 会话的消息。
func TestMessageHandler_Delete_Forbidden(t *testing.T) {
	env := setupMessageHandlerTest(t)
	// 再建一个 user2 + 自己的会话 + 消息
	user2, err := repository.NewUserRepo(env.db).Create(t.Context(), shortName(t, "msguser2"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user2 失败: %v", err)
	}
	// 用 env 的 agent 给 user2 建会话
	conv2, err := env.convRepo.FindOrCreateDM(t.Context(), "dm_user_agent", repository.DMMembers{
		Initiator: repository.ParticipantInput{MemberID: user2.ID, MemberType: "user", Role: "owner"},
		Other:     repository.ParticipantInput{MemberID: env.agentID, MemberType: "agent", Role: "member"},
	})
	if err != nil {
		t.Fatalf("FindOrCreateDM conv2 失败: %v", err)
	}
	content := json.RawMessage(`{"msg_type":"text","data":{"text":"other"}}`)
	m2, err := env.msgRepo.Create(t.Context(), conv2.ID, "user", user2.ID, content)
	if err != nil {
		t.Fatalf("Create m2 失败: %v", err)
	}

	// env.user(user1) 试图删 user2 会话的消息 → 403
	req := httptest.NewRequest(http.MethodDelete, "/api/messages/"+m2.ID, nil)
	w := httptest.NewRecorder()
	env.engine.ServeHTTP(w, req)
	AssertErr(t, w, http.StatusForbidden, "forbidden")
}

// TestMessageHandler_BatchDelete_HappyPath 批量删 2 条,返回 deleted=2。
func TestMessageHandler_BatchDelete_HappyPath(t *testing.T) {
	env := setupMessageHandlerTest(t)
	list, _ := env.msgRepo.ListByConversation(t.Context(), env.convID, env.userID, "user", 50, 0)
	if len(list) != 1 {
		t.Fatalf("前置:应有 1 条消息,实际 %d", len(list))
	}
	firstID := list[0].ID // setup 建的那条

	// 再建第 2 条,确保两条 id 不同
	content := json.RawMessage(`{"msg_type":"text","data":{"text":"x"}}`)
	m2, err := env.msgRepo.Create(t.Context(), env.convID, "user", env.userID, content)
	if err != nil {
		t.Fatalf("Create m2 失败: %v", err)
	}

	body, _ := json.Marshal(map[string][]string{"ids": {firstID, m2.ID}})
	req := httptest.NewRequest(http.MethodPost, "/api/messages/batch-delete", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	env.engine.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("应返回 200,实际 %d body=%s", w.Code, w.Body.String())
	}
	data := AssertOk(t, w, http.StatusOK)
	deleted := int(data["deleted"].(float64))
	if deleted != 2 {
		t.Errorf("deleted 应为 2,实际 %d", deleted)
	}
	list, _ = env.msgRepo.ListByConversation(t.Context(), env.convID, env.userID, "user", 50, 0)
	if len(list) != 0 {
		t.Errorf("批量删后应无消息,实际 %d", len(list))
	}
}

// TestMessageHandler_BatchDelete_EmptyIDs 空 ids 返回 400。
func TestMessageHandler_BatchDelete_EmptyIDs(t *testing.T) {
	env := setupMessageHandlerTest(t)
	body, _ := json.Marshal(map[string][]string{"ids": {}})
	req := httptest.NewRequest(http.MethodPost, "/api/messages/batch-delete", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	env.engine.ServeHTTP(w, req)
	AssertErr(t, w, http.StatusBadRequest, "bad_request")
}

// === GetMessageContext 测试 ===
//
// GetMessageContext 服务于「跨页跳转」:用户点击引用块,客户端拉一段上下文单独渲染。
// 测试覆盖:happy path、非 participant(403)、target 不存在(404)、target 已撤回(404)。

// createNMsgsInConv 在 env.convID 内连发 n 条消息,每条间隔 2ms 错开 created_at。
// 返回的消息按创建顺序排列(msgs[0] 最早, msgs[n-1] 最新)。
func createNMsgsInConv(t *testing.T, env msgTestEnv, senderID string, n int) []string {
	t.Helper()
	var ids []string
	for i := 0; i < n; i++ {
		content := json.RawMessage(`{"msg_type":"text","data":{"text":"m"}}`)
		m, err := env.msgRepo.Create(t.Context(), env.convID, "user", senderID, content)
		if err != nil {
			t.Fatalf("Create m%d 失败: %v", i, err)
		}
		ids = append(ids, m.ID)
		time.Sleep(2 * time.Millisecond)
	}
	return ids
}

// TestGetMessageContextHappyPath user 在 conv 内调 API → 200,返回 target + before + after。
// before 按 DESC(最近在前),after 按 ASC(最老在前),与 repo 协议一致。
func TestGetMessageContextHappyPath(t *testing.T) {
	env := setupMessageHandlerTest(t)
	ids := createNMsgsInConv(t, env, env.userID, 5) // m0..m4,target = m2
	targetID := ids[2]

	// before=1 → [m1];after=1 → [m3]
	req := httptest.NewRequest(http.MethodGet, "/api/messages/"+targetID+"/context?before=1&after=1", nil)
	w := httptest.NewRecorder()
	env.engine.ServeHTTP(w, req)

	data := AssertOk(t, w, http.StatusOK)
	targetMap, ok := data["target"].(map[string]any)
	if !ok {
		t.Fatalf("target 应为对象,实际 %T", data["target"])
	}
	if targetMap["id"] != targetID {
		t.Errorf("target.id 期望 %s, 实际 %v", targetID, targetMap["id"])
	}

	beforeArr, ok := data["before"].([]any)
	if !ok {
		t.Fatalf("before 应为数组, 实际 %T", data["before"])
	}
	if len(beforeArr) != 1 {
		t.Fatalf("before 期望 1 条, 实际 %d", len(beforeArr))
	}
	if beforeArr[0].(map[string]any)["id"] != ids[1] {
		t.Errorf("before[0].id 期望 %s (m1), 实际 %v", ids[1], beforeArr[0])
	}

	afterArr, ok := data["after"].([]any)
	if !ok {
		t.Fatalf("after 应为数组, 实际 %T", data["after"])
	}
	if len(afterArr) != 1 {
		t.Fatalf("after 期望 1 条, 实际 %d", len(afterArr))
	}
	if afterArr[0].(map[string]any)["id"] != ids[3] {
		t.Errorf("after[0].id 期望 %s (m3), 实际 %v", ids[3], afterArr[0])
	}

	// 校验非空数组而非 nil(JSON 一致性)
	if strings.Contains(w.Body.String(), `"before":null`) {
		t.Errorf("before 不应为 null")
	}
	if strings.Contains(w.Body.String(), `"after":null`) {
		t.Errorf("after 不应为 null")
	}
}

// TestGetMessageContextNotParticipant 非 participant 调 API → 403。
// env.user(user1) 试图访问 user2 会话里的消息 → 403 forbidden。
func TestGetMessageContextNotParticipant(t *testing.T) {
	env := setupMessageHandlerTest(t)
	// 再建 user2 + 自己的会话 + 消息
	user2, err := repository.NewUserRepo(env.db).Create(t.Context(), shortName(t, "msguser2"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user2 失败: %v", err)
	}
	conv2, err := env.convRepo.FindOrCreateDM(t.Context(), "dm_user_agent", repository.DMMembers{
		Initiator: repository.ParticipantInput{MemberID: user2.ID, MemberType: "user", Role: "owner"},
		Other:     repository.ParticipantInput{MemberID: env.agentID, MemberType: "agent", Role: "member"},
	})
	if err != nil {
		t.Fatalf("FindOrCreateDM conv2 失败: %v", err)
	}
	content := json.RawMessage(`{"msg_type":"text","data":{"text":"other"}}`)
	m2, err := env.msgRepo.Create(t.Context(), conv2.ID, "user", user2.ID, content)
	if err != nil {
		t.Fatalf("Create m2 失败: %v", err)
	}

	// env.user(user1) 试图访问 user2 会话里的消息 → 403
	req := httptest.NewRequest(http.MethodGet, "/api/messages/"+m2.ID+"/context", nil)
	w := httptest.NewRecorder()
	env.engine.ServeHTTP(w, req)
	AssertErr(t, w, http.StatusForbidden, "forbidden")
}

// TestGetMessageContextNotFound target_id 不存在 → 404。
// 用合法 UUID 格式(否则 Postgres 在 uuid 列上报 syntax error → 500 而非 404)。
func TestGetMessageContextNotFound(t *testing.T) {
	env := setupMessageHandlerTest(t)
	req := httptest.NewRequest(http.MethodGet, "/api/messages/00000000-0000-0000-0000-000000000000/context", nil)
	w := httptest.NewRecorder()
	env.engine.ServeHTTP(w, req)
	AssertErr(t, w, http.StatusNotFound, "not_found")
}

// TestGetMessageContextSoftDeleted target 已撤回(deleted_at 已设)→ 404。
// 撤回语义:跳转到已撤回的消息没意义,客户端应感知并提示用户。
func TestGetMessageContextSoftDeleted(t *testing.T) {
	env := setupMessageHandlerTest(t)
	ids := createNMsgsInConv(t, env, env.userID, 1)
	targetID := ids[0]

	// 通过 tx 撤回(SoftDeleteTx,与 production Delete handler 一致)
	tx, err := env.db.BeginTx(t.Context(), nil)
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	if err := env.msgRepo.SoftDeleteTx(t.Context(), tx, targetID); err != nil {
		_ = tx.Rollback()
		t.Fatalf("SoftDeleteTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit 失败: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/messages/"+targetID+"/context", nil)
	w := httptest.NewRecorder()
	env.engine.ServeHTTP(w, req)
	AssertErr(t, w, http.StatusNotFound, "not_found")
}

// === UpdateContent 测试 ===
//
// UpdateContent 服务于「交互卡片状态变更」:plugin PATCH 原 card 消息的 status
// (permission_card / question_card 从 pending → 终态)。测试覆盖:
//   - happy path:agent 改自己发的卡片 → 200,DB 原地替换,MESSAGE_UPDATE 广播到 user client;
//   - 非 sender 改 → 403(且不广播);
//   - content 缺 msg_type → 400。

// updateContentEnv 汇聚 UpdateContent 测试的可复用件。
type updateContentEnv struct {
	mh         *MessageHandler
	msgID      string
	userClient *hub.Client // 注册进 hub 的 user client,捕获 MESSAGE_UPDATE 广播
	userID     string
	agentID    string
	convID     string
}

// setupUpdateContentTest 起 testcontainers DB + user/agent/conv + 一条 agent
// permission_card 消息,hub 注册一个在线 user client,返回可复用件。
func setupUpdateContentTest(t *testing.T) updateContentEnv {
	return setupMsgUpdateTest(t, json.RawMessage(`{"msg_type":"permission_card","data":{"status":"pending"}}`))
}

// setupMsgUpdateTest 起 testcontainers DB + user/agent/conv + 一条初始 content
// 为 initContent 的 agent 消息,hub 注册一个在线 user client,返回可复用件。
func setupMsgUpdateTest(t *testing.T, initContent json.RawMessage) updateContentEnv {
	t.Helper()
	db := repository.SetupTestDB(t)
	userRepo := repository.NewUserRepo(db)
	agentRepo := repository.NewAgentRepo(db)
	convRepo := repository.NewConversationRepo(db)
	msgRepo := repository.NewMessageRepo(db)
	participantRepo := repository.NewParticipantRepo(db)

	user, err := userRepo.Create(t.Context(), shortName(t, "updc"), "$2a$10$hash")
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

	// agent 发一条初始卡片消息
	msg, err := msgRepo.Create(t.Context(), conv.ID, "agent", agent.ID, initContent)
	if err != nil {
		t.Fatalf("Create msg 失败: %v", err)
	}

	// hub + 注册在线 user client(不启动 Run;RegisterClient 同步写入 clients map)
	h := hub.NewHub(nil, agentRepo, participantRepo, nil)
	userClient := &hub.Client{
		ID:            user.ID,
		Role:          "user",
		Send:          make(chan []byte, 8),
		LastHeartbeat: time.Now(),
	}
	h.RegisterClient(userClient)

	mh := NewMessageHandler(msgRepo, convRepo, participantRepo, userRepo, agentRepo, h)
	return updateContentEnv{
		mh:         mh,
		msgID:      msg.ID,
		userClient: userClient,
		userID:     user.ID,
		agentID:    agent.ID,
		convID:     conv.ID,
	}
}

// patchUpdateContent 构造一个 PATCH /api/messages/:id 的 gin context 并调 handler。
// actorID/role 决定鉴权上下文;content 为 nil 时 body 不带 content(测必填校验)。
func patchUpdateContent(t *testing.T, env updateContentEnv, actorID, role string, content json.RawMessage) *httptest.ResponseRecorder {
	t.Helper()
	var body []byte
	if content != nil {
		body, _ = json.Marshal(map[string]json.RawMessage{"content": content})
	} else {
		body = []byte(`{}`)
	}
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPatch, "/api/messages/"+env.msgID, bytes.NewReader(body))
	c.Request.Header.Set("Content-Type", "application/json")
	c.Params = gin.Params{{Key: "id", Value: env.msgID}}
	c.Set("userID", actorID)
	c.Set("role", role)
	env.mh.UpdateContent(c)
	return w
}

// TestMessageHandlerUpdateContent agent 改自己发的卡片:
//   - HTTP 200;
//   - DB content 原地替换为 approved;
//   - MESSAGE_UPDATE 广播到在线 user client(验 message_id + content.status)。
func TestMessageHandlerUpdateContent(t *testing.T) {
	env := setupUpdateContentTest(t)
	newContent := json.RawMessage(`{"msg_type":"permission_card","data":{"status":"approved","result":"once"}}`)

	w := patchUpdateContent(t, env, env.agentID, "agent", newContent)
	AssertOk(t, w, http.StatusOK)

	// 验证 DB 原地替换
	updated, _ := env.mh.msgRepo.Get(t.Context(), env.msgID)
	var got map[string]any
	if err := json.Unmarshal(updated.Content, &got); err != nil {
		t.Fatalf("unmarshal DB content 失败: %v", err)
	}
	data, _ := got["data"].(map[string]any)
	if data["status"] != "approved" {
		t.Errorf("DB content.data.status 期望 approved, 实际 %v", data["status"])
	}

	// 验证 MESSAGE_UPDATE 广播到 user client
	select {
	case raw := <-env.userClient.Send:
		var wsMsg model.WSMessage
		if err := json.Unmarshal(raw, &wsMsg); err != nil {
			t.Fatalf("unmarshal ws 失败: %v", err)
		}
		if wsMsg.T != model.EventMessageUpdate {
			t.Fatalf("期望 MESSAGE_UPDATE, 实际 %s", wsMsg.T)
		}
		var payload map[string]any
		if err := json.Unmarshal(wsMsg.D, &payload); err != nil {
			t.Fatalf("unmarshal payload 失败: %v", err)
		}
		if payload["message_id"] != env.msgID {
			t.Errorf("payload.message_id 期望 %s, 实际 %v", env.msgID, payload["message_id"])
		}
		if payload["conversation_id"] != env.convID {
			t.Errorf("payload.conversation_id 期望 %s, 实际 %v", env.convID, payload["conversation_id"])
		}
		// 广播的 content 应为更新后的内容
		contentMap, _ := payload["content"].(map[string]any)
		contentData, _ := contentMap["data"].(map[string]any)
		if contentData["status"] != "approved" {
			t.Errorf("broadcast content.status 期望 approved, 实际 %v", contentData["status"])
		}
	case <-time.After(200 * time.Millisecond):
		t.Fatal("未收到 MESSAGE_UPDATE 广播")
	}
}

// TestMessageHandlerUpdateContentWrongSender 非 sender 试图改(agent 发的消息,user 改)→ 403,
// 且不广播(无 MESSAGE_UPDATE)。
func TestMessageHandlerUpdateContentWrongSender(t *testing.T) {
	env := setupUpdateContentTest(t)
	newContent := json.RawMessage(`{"msg_type":"permission_card","data":{"status":"approved"}}`)

	// user(actorID=user) 改 agent 发的消息 → 403
	w := patchUpdateContent(t, env, env.userID, "user", newContent)
	AssertErr(t, w, http.StatusForbidden, "forbidden")

	// 非 sender 路径在广播之前 return,不应有 MESSAGE_UPDATE
	select {
	case <-env.userClient.Send:
		t.Fatal("非 sender 改消息不应触发广播")
	case <-time.After(50 * time.Millisecond):
	}
}

// TestMessageHandlerUpdateContentMissingMsgType content 缺 msg_type → 400。
func TestMessageHandlerUpdateContentMissingMsgType(t *testing.T) {
	env := setupUpdateContentTest(t)
	// content 是 JSON object 但无 msg_type
	badContent := json.RawMessage(`{"data":{"status":"approved"}}`)

	w := patchUpdateContent(t, env, env.agentID, "agent", badContent)
	AssertErr(t, w, http.StatusBadRequest, "bad_request")
}

// TestMessageHandlerUpdateContentContentNotObject content 不是 JSON object(数组)→ 400。
func TestMessageHandlerUpdateContentContentNotObject(t *testing.T) {
	env := setupUpdateContentTest(t)
	badContent := json.RawMessage(`["not","an","object"]`)

	w := patchUpdateContent(t, env, env.agentID, "agent", badContent)
	AssertErr(t, w, http.StatusBadRequest, "bad_request")
}

// TestMessageHandlerUpdateContentPreservesSilent PATCH 更新 status 时保留原 silent 字段。
//
// 背景:tool_card 创建时 silent=true(process 跳过 IncrUnread),但 plugin 后续 PATCH
// status 时 content 只带 {msg_type,data,status} 不含 silent,server 整体替换后
// silent 字段丢失 → 重算未读时把该消息当"非 silent"计入,导致未读残留。
// 修复:PATCH 时新 content 若未带 silent,并入原消息的 silent 值。
func TestMessageHandlerUpdateContentPreservesSilent(t *testing.T) {
	db := repository.SetupTestDB(t)
	userRepo := repository.NewUserRepo(db)
	agentRepo := repository.NewAgentRepo(db)
	convRepo := repository.NewConversationRepo(db)
	msgRepo := repository.NewMessageRepo(db)
	participantRepo := repository.NewParticipantRepo(db)

	user, err := userRepo.Create(t.Context(), shortName(t, "upds"), "$2a$10$hash")
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

	// 创建一条 silent=true 的 tool_card(模拟 plugin 发卡)
	content := json.RawMessage(`{"msg_type":"tool_card","data":{"name":"read","status":"running"},"silent":true}`)
	msg, err := msgRepo.Create(t.Context(), conv.ID, "agent", agent.ID, content)
	if err != nil {
		t.Fatalf("Create msg 失败: %v", err)
	}

	h := hub.NewHub(nil, agentRepo, participantRepo, nil)
	mh := NewMessageHandler(msgRepo, convRepo, participantRepo, userRepo, agentRepo, h)

	// PATCH 更新 status,content 不含 silent(模拟 plugin tool_card.ts 的 updateMessageContent)
	newContent := json.RawMessage(`{"msg_type":"tool_card","data":{"name":"read","status":"completed"}}`)
	body, _ := json.Marshal(map[string]json.RawMessage{"content": newContent})
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPatch, "/api/messages/"+msg.ID, bytes.NewReader(body))
	c.Request.Header.Set("Content-Type", "application/json")
	c.Params = gin.Params{{Key: "id", Value: msg.ID}}
	c.Set("userID", agent.ID)
	c.Set("role", "agent")
	mh.UpdateContent(c)
	AssertOk(t, w, http.StatusOK)

	// 验证 DB content 保留了 silent=true
	updated, _ := msgRepo.Get(t.Context(), msg.ID)
	var got map[string]any
	if err := json.Unmarshal(updated.Content, &got); err != nil {
		t.Fatalf("unmarshal DB content 失败: %v", err)
	}
	silent, ok := got["silent"].(bool)
	if !ok || !silent {
		t.Errorf("PATCH 后 silent 应保留 true, 实际 %v (silent=%v)", got["silent"], silent)
	}
}

// 聚合卡回合结束:PATCH silent 从 true 翻转为 false 时,应对非 sender 全员 IncrUnread。
//
// 场景:aggregate_card 创建时 silent=true(回合进行中不打扰),回合结束 plugin PATCH
// 显式带 silent=false 让结果对用户可见 → 该消息从"不计数"翻转为"计数",
// 应对非 sender(user) unread_count +1,与发消息 IncrUnreadTx 口径一致。
func TestUpdateContent_SilentFlip_IncrsUnread(t *testing.T) {
	db := repository.SetupTestDB(t)
	userRepo := repository.NewUserRepo(db)
	agentRepo := repository.NewAgentRepo(db)
	convRepo := repository.NewConversationRepo(db)
	msgRepo := repository.NewMessageRepo(db)
	participantRepo := repository.NewParticipantRepo(db)

	user, err := userRepo.Create(t.Context(), shortName(t, "silentflip"), "$2a$10$hash")
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

	// agent 发一张 silent=true 的聚合卡(回合进行中,不触发未读)
	content := json.RawMessage(`{"msg_type":"aggregate_card","data":{"status":"running"},"silent":true}`)
	msg, err := msgRepo.Create(t.Context(), conv.ID, "agent", agent.ID, content)
	if err != nil {
		t.Fatalf("Create msg 失败: %v", err)
	}

	// 前置:user 未读应为 0(silent 消息不计数)
	p, err := participantRepo.Get(t.Context(), conv.ID, user.ID, "user")
	if err != nil || p == nil {
		t.Fatalf("Get participant 失败: %v", err)
	}
	if p.UnreadCount != 0 {
		t.Fatalf("前置:silent=true 时 user 未读应为 0,实际 %d", p.UnreadCount)
	}

	h := hub.NewHub(nil, agentRepo, participantRepo, nil)
	mh := NewMessageHandler(msgRepo, convRepo, participantRepo, userRepo, agentRepo, h)

	// PATCH content 显式带 silent=false(回合结束,聚合卡结果对用户可见)
	newContent := json.RawMessage(`{"msg_type":"aggregate_card","data":{"status":"done"},"silent":false}`)
	body, _ := json.Marshal(map[string]json.RawMessage{"content": newContent})
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest(http.MethodPatch, "/api/messages/"+msg.ID, bytes.NewReader(body))
	c.Request.Header.Set("Content-Type", "application/json")
	c.Params = gin.Params{{Key: "id", Value: msg.ID}}
	c.Set("userID", agent.ID)
	c.Set("role", "agent")
	mh.UpdateContent(c)
	AssertOk(t, w, http.StatusOK)

	// 翻转后:user 未读应为 1(非 sender 全员 IncrUnread)
	p2, err := participantRepo.Get(t.Context(), conv.ID, user.ID, "user")
	if err != nil || p2 == nil {
		t.Fatalf("Get participant 失败: %v", err)
	}
	if p2.UnreadCount != 1 {
		t.Errorf("silent true→false 翻转后 user 未读应为 1,实际 %d", p2.UnreadCount)
	}
}

// ===== 聚合卡增量 op 测试 =====

// aggregateInitContent 聚合卡初始 content:state=generating + 两个元素, silent=true。
const aggregateInitContent = `{"msg_type":"aggregate_card","data":{"state":"generating","elements":[{"type":"tool_card","element_id":"e1","data":{"name":"read","status":"running"}},{"type":"text","element_id":"e2","data":{"text":"hi"}}]},"silent":true}`

// setupAggregateUpdateTest 起一套聚合卡更新环境(初始 content 见 aggregateInitContent)。
func setupAggregateUpdateTest(t *testing.T) updateContentEnv {
	t.Helper()
	return setupMsgUpdateTest(t, json.RawMessage(aggregateInitContent))
}

// getMsgContent 读取 DB 中当前消息 content 并解析为 map[string]any。
func getMsgContent(t *testing.T, env updateContentEnv) map[string]any {
	t.Helper()
	updated, err := env.mh.msgRepo.Get(t.Context(), env.msgID)
	if err != nil {
		t.Fatalf("Get msg 失败: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(updated.Content, &got); err != nil {
		t.Fatalf("unmarshal DB content 失败: %v", err)
	}
	return got
}

// msgContentData 取 content 的 data(map)。
func msgContentData(t *testing.T, got map[string]any) map[string]any {
	t.Helper()
	data, ok := got["data"].(map[string]any)
	if !ok {
		t.Fatalf("content.data 非 object: %v", got["data"])
	}
	return data
}

// msgElements 取 content.data.elements([]any)。
func msgElements(t *testing.T, data map[string]any) []any {
	t.Helper()
	elems, ok := data["elements"].([]any)
	if !ok {
		t.Fatalf("data.elements 非数组: %v", data["elements"])
	}
	return elems
}

// recvMessageUpdate 从在线 user client 收取一条 MESSAGE_UPDATE 并解析 payload。
func recvMessageUpdate(t *testing.T, env updateContentEnv) map[string]any {
	t.Helper()
	select {
	case raw := <-env.userClient.Send:
		var wsMsg model.WSMessage
		if err := json.Unmarshal(raw, &wsMsg); err != nil {
			t.Fatalf("unmarshal ws 失败: %v", err)
		}
		if wsMsg.T != model.EventMessageUpdate {
			t.Fatalf("期望 MESSAGE_UPDATE, 实际 %s", wsMsg.T)
		}
		var payload map[string]any
		if err := json.Unmarshal(wsMsg.D, &payload); err != nil {
			t.Fatalf("unmarshal payload 失败: %v", err)
		}
		return payload
	case <-time.After(200 * time.Millisecond):
		t.Fatal("未收到 MESSAGE_UPDATE 广播")
		return nil
	}
}

// TestUpdateContent_Append_Element 聚合卡 append:元素追加到末尾,DB 存全量,
// 广播带增量 op 结构(与入站一致)。
func TestUpdateContent_Append_Element(t *testing.T) {
	env := setupAggregateUpdateTest(t)
	delta := json.RawMessage(`{"msg_type":"aggregate_card","data":{"op":"append","element":{"type":"text","element_id":"e3","data":{"text":"done"}}}}`)

	w := patchUpdateContent(t, env, env.agentID, "agent", delta)
	AssertOk(t, w, http.StatusOK)

	// DB:全量合并,e3 追加到末尾
	got := getMsgContent(t, env)
	elems := msgElements(t, msgContentData(t, got))
	if len(elems) != 3 {
		t.Fatalf("append 后 elements 应 3 个, 实际 %d", len(elems))
	}
	last := elems[2].(map[string]any)
	if last["element_id"] != "e3" {
		t.Errorf("末尾元素应 e3, 实际 %v", last["element_id"])
	}
	if last["data"].(map[string]any)["text"] != "done" {
		t.Errorf("e3 data 应 {text:done}, 实际 %v", last["data"])
	}

	// 广播带增量 op(APP 应用增量)
	payload := recvMessageUpdate(t, env)
	contentData := msgContentData(t, payload["content"].(map[string]any))
	if contentData["op"] != "append" {
		t.Errorf("广播 content.data.op 期望 append, 实际 %v", contentData["op"])
	}
	el := contentData["element"].(map[string]any)
	if el["element_id"] != "e3" {
		t.Errorf("广播 element_id 期望 e3, 实际 %v", el["element_id"])
	}
}

// TestUpdateContent_Append_MissingElement append 缺 element → 400(fail fast)。
func TestUpdateContent_Append_MissingElement(t *testing.T) {
	env := setupAggregateUpdateTest(t)
	delta := json.RawMessage(`{"msg_type":"aggregate_card","data":{"op":"append"}}`)

	w := patchUpdateContent(t, env, env.agentID, "agent", delta)
	AssertErr(t, w, http.StatusBadRequest, "bad_request")
}

// TestUpdateContent_Append_PreservesSilent 增量 append 不改变原 content 的 silent。
func TestUpdateContent_Append_PreservesSilent(t *testing.T) {
	env := setupAggregateUpdateTest(t)
	delta := json.RawMessage(`{"msg_type":"aggregate_card","data":{"op":"append","element":{"type":"text","element_id":"e3","data":{"text":"done"}}}}`)

	w := patchUpdateContent(t, env, env.agentID, "agent", delta)
	AssertOk(t, w, http.StatusOK)

	got := getMsgContent(t, env)
	silent, ok := got["silent"].(bool)
	if !ok || !silent {
		t.Errorf("增量 append 后 silent 应保留 true, 实际 %v", got["silent"])
	}

	// 广播带原始增量(不并入 silent),APP 应用增量
	payload := recvMessageUpdate(t, env)
	bcast := payload["content"].(map[string]any)
	if _, hasSilent := bcast["silent"]; hasSilent {
		t.Errorf("增量广播不应带顶层 silent, 实际 %v", bcast)
	}
}

// TestUpdateContent_Update_ElementData 聚合卡 update:按 element_id 整体替换元素 data。
func TestUpdateContent_Update_ElementData(t *testing.T) {
	env := setupAggregateUpdateTest(t)
	delta := json.RawMessage(`{"msg_type":"aggregate_card","data":{"op":"update","element_id":"e1","data":{"name":"read","status":"completed"}}}`)

	w := patchUpdateContent(t, env, env.agentID, "agent", delta)
	AssertOk(t, w, http.StatusOK)

	got := getMsgContent(t, env)
	elems := msgElements(t, msgContentData(t, got))
	if len(elems) != 2 {
		t.Fatalf("update 不应增删元素, 实际 %d", len(elems))
	}
	e1 := elems[0].(map[string]any)
	if e1["element_id"] != "e1" {
		t.Fatalf("首个元素应 e1, 实际 %v", e1["element_id"])
	}
	d1 := e1["data"].(map[string]any)
	if d1["status"] != "completed" {
		t.Errorf("e1 data.status 期望 completed, 实际 %v", d1["status"])
	}
	if d1["name"] != "read" {
		t.Errorf("e1 data.name 期望保留 read, 实际 %v", d1["name"])
	}

	payload := recvMessageUpdate(t, env)
	contentData := msgContentData(t, payload["content"].(map[string]any))
	if contentData["op"] != "update" || contentData["element_id"] != "e1" {
		t.Errorf("广播增量期望 op=update element_id=e1, 实际 %v", contentData)
	}
}

// TestUpdateContent_Update_ElementNotFound update 目标元素不存在 → 400(fail fast)。
func TestUpdateContent_Update_ElementNotFound(t *testing.T) {
	env := setupAggregateUpdateTest(t)
	delta := json.RawMessage(`{"msg_type":"aggregate_card","data":{"op":"update","element_id":"nope","data":{"x":1}}}`)

	w := patchUpdateContent(t, env, env.agentID, "agent", delta)
	AssertErr(t, w, http.StatusBadRequest, "bad_request")
}

// TestUpdateContent_Remove_Element 聚合卡 remove:按 element_id 删除元素。
func TestUpdateContent_Remove_Element(t *testing.T) {
	env := setupAggregateUpdateTest(t)
	delta := json.RawMessage(`{"msg_type":"aggregate_card","data":{"op":"remove","element_id":"e1"}}`)

	w := patchUpdateContent(t, env, env.agentID, "agent", delta)
	AssertOk(t, w, http.StatusOK)

	got := getMsgContent(t, env)
	elems := msgElements(t, msgContentData(t, got))
	if len(elems) != 1 {
		t.Fatalf("remove 后 elements 应 1 个, 实际 %d", len(elems))
	}
	if elems[0].(map[string]any)["element_id"] != "e2" {
		t.Errorf("剩余元素应 e2, 实际 %v", elems[0])
	}

	payload := recvMessageUpdate(t, env)
	contentData := msgContentData(t, payload["content"].(map[string]any))
	if contentData["op"] != "remove" || contentData["element_id"] != "e1" {
		t.Errorf("广播增量期望 op=remove element_id=e1, 实际 %v", contentData)
	}
}

// TestUpdateContent_Remove_ElementNotFound remove 目标元素不存在 → 幂等成功(200)。
func TestUpdateContent_Remove_ElementNotFound(t *testing.T) {
	env := setupAggregateUpdateTest(t)
	delta := json.RawMessage(`{"msg_type":"aggregate_card","data":{"op":"remove","element_id":"nope"}}`)

	w := patchUpdateContent(t, env, env.agentID, "agent", delta)
	AssertOk(t, w, http.StatusOK)

	got := getMsgContent(t, env)
	if n := len(msgElements(t, msgContentData(t, got))); n != 2 {
		t.Errorf("remove 不存在元素应幂等保留 2 个, 实际 %d", n)
	}
}

// TestUpdateContent_Reorder_Elements 聚合卡 reorder:按 order 数组重排 elements。
func TestUpdateContent_Reorder_Elements(t *testing.T) {
	env := setupAggregateUpdateTest(t)
	delta := json.RawMessage(`{"msg_type":"aggregate_card","data":{"op":"reorder","order":["e2","e1"]}}`)

	w := patchUpdateContent(t, env, env.agentID, "agent", delta)
	AssertOk(t, w, http.StatusOK)

	got := getMsgContent(t, env)
	elems := msgElements(t, msgContentData(t, got))
	if len(elems) != 2 {
		t.Fatalf("reorder 后 elements 应 2 个, 实际 %d", len(elems))
	}
	if elems[0].(map[string]any)["element_id"] != "e2" || elems[1].(map[string]any)["element_id"] != "e1" {
		t.Errorf("reorder 后顺序应 [e2,e1], 实际 [%v,%v]",
			elems[0].(map[string]any)["element_id"], elems[1].(map[string]any)["element_id"])
	}

	payload := recvMessageUpdate(t, env)
	contentData := msgContentData(t, payload["content"].(map[string]any))
	order, _ := contentData["order"].([]any)
	if contentData["op"] != "reorder" || len(order) != 2 || order[0] != "e2" {
		t.Errorf("广播增量期望 op=reorder order=[e2,e1], 实际 %v", contentData)
	}
}

// TestUpdateContent_Reorder_UnknownElement reorder 中引用不存在的元素 → 400(fail fast)。
func TestUpdateContent_Reorder_UnknownElement(t *testing.T) {
	env := setupAggregateUpdateTest(t)
	delta := json.RawMessage(`{"msg_type":"aggregate_card","data":{"op":"reorder","order":["e2","nope"]}}`)

	w := patchUpdateContent(t, env, env.agentID, "agent", delta)
	AssertErr(t, w, http.StatusBadRequest, "bad_request")
}

// TestUpdateContent_SetState 聚合卡 set_state:改 data.state。
func TestUpdateContent_SetState(t *testing.T) {
	env := setupAggregateUpdateTest(t)
	delta := json.RawMessage(`{"msg_type":"aggregate_card","data":{"op":"set_state","state":"done"}}`)

	w := patchUpdateContent(t, env, env.agentID, "agent", delta)
	AssertOk(t, w, http.StatusOK)

	got := getMsgContent(t, env)
	if st := msgContentData(t, got)["state"]; st != "done" {
		t.Errorf("data.state 期望 done, 实际 %v", st)
	}
	if n := len(msgElements(t, msgContentData(t, got))); n != 2 {
		t.Errorf("set_state 不应改动 elements, 实际 %d 个", n)
	}

	payload := recvMessageUpdate(t, env)
	contentData := msgContentData(t, payload["content"].(map[string]any))
	if contentData["op"] != "set_state" || contentData["state"] != "done" {
		t.Errorf("广播增量期望 op=set_state state=done, 实际 %v", contentData)
	}
}

// TestUpdateContent_SetSilent 聚合卡 set_silent:显式改 content.silent。
func TestUpdateContent_SetSilent(t *testing.T) {
	env := setupAggregateUpdateTest(t)
	delta := json.RawMessage(`{"msg_type":"aggregate_card","data":{"op":"set_silent","silent":false}}`)

	w := patchUpdateContent(t, env, env.agentID, "agent", delta)
	AssertOk(t, w, http.StatusOK)

	got := getMsgContent(t, env)
	silent, ok := got["silent"].(bool)
	if !ok || silent {
		t.Errorf("set_silent false 后 content.silent 应为 false, 实际 %v", got["silent"])
	}

	payload := recvMessageUpdate(t, env)
	contentData := msgContentData(t, payload["content"].(map[string]any))
	if contentData["op"] != "set_silent" || contentData["silent"] != false {
		t.Errorf("广播增量期望 op=set_silent silent=false, 实际 %v", contentData)
	}
}

// TestUpdateContent_SetSilent_Flip_IncrsUnread set_silent true→false 翻转时,
// 对非 sender 全员 IncrUnread(复用 Task 1 翻转逻辑)。
func TestUpdateContent_SetSilent_Flip_IncrsUnread(t *testing.T) {
	env := setupAggregateUpdateTest(t)

	// 前置:silent=true 创建,user 未读应为 0
	p, err := env.mh.participantRepo.Get(t.Context(), env.convID, env.userID, "user")
	if err != nil || p == nil {
		t.Fatalf("Get participant 失败: %v", err)
	}
	if p.UnreadCount != 0 {
		t.Fatalf("前置:silent=true 时 user 未读应为 0,实际 %d", p.UnreadCount)
	}

	delta := json.RawMessage(`{"msg_type":"aggregate_card","data":{"op":"set_silent","silent":false}}`)
	w := patchUpdateContent(t, env, env.agentID, "agent", delta)
	AssertOk(t, w, http.StatusOK)

	p2, err := env.mh.participantRepo.Get(t.Context(), env.convID, env.userID, "user")
	if err != nil || p2 == nil {
		t.Fatalf("Get participant 失败: %v", err)
	}
	if p2.UnreadCount != 1 {
		t.Errorf("set_silent true→false 翻转后 user 未读应为 1,实际 %d", p2.UnreadCount)
	}
}

// TestUpdateContent_NoOp_Elements_FullReplace data 无 op 且含 elements → 全量替换(旧 plugin / 非聚合)。
func TestUpdateContent_NoOp_Elements_FullReplace(t *testing.T) {
	env := setupAggregateUpdateTest(t)
	full := json.RawMessage(`{"msg_type":"aggregate_card","data":{"state":"done","elements":[{"type":"text","element_id":"x1","data":{"text":"new"}}]}}`)

	w := patchUpdateContent(t, env, env.agentID, "agent", full)
	AssertOk(t, w, http.StatusOK)

	got := getMsgContent(t, env)
	data := msgContentData(t, got)
	if data["state"] != "done" {
		t.Errorf("全量替换 data.state 期望 done, 实际 %v", data["state"])
	}
	elems := msgElements(t, data)
	if len(elems) != 1 || elems[0].(map[string]any)["element_id"] != "x1" {
		t.Fatalf("全量替换后 elements 应只剩 [x1], 实际 %v", elems)
	}

	// 无 op → 广播全量(非增量)
	payload := recvMessageUpdate(t, env)
	contentData := msgContentData(t, payload["content"].(map[string]any))
	if _, hasOp := contentData["op"]; hasOp {
		t.Errorf("无 op 全量替换广播不应带 op, 实际 %v", contentData)
	}
}
