package handler

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/hub"
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

	user, err := userRepo.Create(shortName(t, "msguser"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	agent, err := agentRepo.Create(user.ID, "Agent", "secret-key")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}
	conv, err := convRepo.FindOrCreateDM("dm_user_agent", repository.DMMembers{
		Initiator: repository.ParticipantInput{MemberID: user.ID, MemberType: "user", Role: "owner"},
		Other:     repository.ParticipantInput{MemberID: agent.ID, MemberType: "agent", Role: "member"},
	})
	if err != nil {
		t.Fatalf("FindOrCreateDM 失败: %v", err)
	}

	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`)
	_, err = msgRepo.Create(conv.ID, "user", user.ID, content)
	if err != nil {
		t.Fatalf("Create msg 失败: %v", err)
	}

	// 不启动 hub.Run(测试不需要真实广播),给个 NewHub 实例即可。
	// presence 传 nil —— handler 测试不验证广播投递,只验证不 panic。
	h := hub.NewHub(nil, agentRepo, participantRepo)

	mh := NewMessageHandler(msgRepo, convRepo, participantRepo, h)
	r := gin.New()
	// 用 c.Set 绕过 AuthMiddleware,直接注入鉴权上下文。
	del := func(c *gin.Context) { c.Set("userID", user.ID); c.Set("role", "user"); mh.Delete(c) }
	bdel := func(c *gin.Context) { c.Set("userID", user.ID); c.Set("role", "user"); mh.BatchDelete(c) }
	r.DELETE("/api/messages/:id", del)
	r.POST("/api/messages/batch-delete", bdel)

	return msgTestEnv{
		engine: r, db: db, msgRepo: msgRepo, convRepo: convRepo,
		userID: user.ID, agentID: agent.ID, convID: conv.ID,
	}
}

// TestMessageHandler_Delete_HappyPath 单删成功,返回 204,消息从列表消失。
func TestMessageHandler_Delete_HappyPath(t *testing.T) {
	env := setupMessageHandlerTest(t)
	list, _ := env.msgRepo.ListByConversation(env.convID, 50, 0)
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
	list, _ = env.msgRepo.ListByConversation(env.convID, 50, 0)
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
	if w.Code != http.StatusNotFound {
		t.Fatalf("应返回 404,实际 %d", w.Code)
	}
}

// TestMessageHandler_Delete_Forbidden 删别人会话的消息返回 403。
// 另建一个 user2 的会话,user 试图删 user2 会话的消息。
func TestMessageHandler_Delete_Forbidden(t *testing.T) {
	env := setupMessageHandlerTest(t)
	// 再建一个 user2 + 自己的会话 + 消息
	user2, err := repository.NewUserRepo(env.db).Create(shortName(t, "msguser2"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user2 失败: %v", err)
	}
	// 用 env 的 agent 给 user2 建会话
	conv2, err := env.convRepo.FindOrCreateDM("dm_user_agent", repository.DMMembers{
		Initiator: repository.ParticipantInput{MemberID: user2.ID, MemberType: "user", Role: "owner"},
		Other:     repository.ParticipantInput{MemberID: env.agentID, MemberType: "agent", Role: "member"},
	})
	if err != nil {
		t.Fatalf("FindOrCreateDM conv2 失败: %v", err)
	}
	content := json.RawMessage(`{"msg_type":"text","data":{"text":"other"}}`)
	m2, err := env.msgRepo.Create(conv2.ID, "user", user2.ID, content)
	if err != nil {
		t.Fatalf("Create m2 失败: %v", err)
	}

	// env.user(user1) 试图删 user2 会话的消息 → 403
	req := httptest.NewRequest(http.MethodDelete, "/api/messages/"+m2.ID, nil)
	w := httptest.NewRecorder()
	env.engine.ServeHTTP(w, req)
	if w.Code != http.StatusForbidden {
		t.Fatalf("越权应返回 403,实际 %d", w.Code)
	}
}

// TestMessageHandler_BatchDelete_HappyPath 批量删 2 条,返回 deleted=2。
func TestMessageHandler_BatchDelete_HappyPath(t *testing.T) {
	env := setupMessageHandlerTest(t)
	list, _ := env.msgRepo.ListByConversation(env.convID, 50, 0)
	if len(list) != 1 {
		t.Fatalf("前置:应有 1 条消息,实际 %d", len(list))
	}
	firstID := list[0].ID // setup 建的那条

	// 再建第 2 条,确保两条 id 不同
	content := json.RawMessage(`{"msg_type":"text","data":{"text":"x"}}`)
	m2, err := env.msgRepo.Create(env.convID, "user", env.userID, content)
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
	var resp map[string]int
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["deleted"] != 2 {
		t.Errorf("deleted 应为 2,实际 %d", resp["deleted"])
	}
	list, _ = env.msgRepo.ListByConversation(env.convID, 50, 0)
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
	if w.Code != http.StatusBadRequest {
		t.Fatalf("空 ids 应返回 400,实际 %d", w.Code)
	}
}

// TestMessageHandler_Delete_RecalcLastMessage 删最后一条后 last_message_content 被清空。
func TestMessageHandler_Delete_RecalcLastMessage(t *testing.T) {
	env := setupMessageHandlerTest(t)
	// 先确认缓存有值
	conv, _ := env.convRepo.GetByID(env.convID)
	if conv == nil {
		t.Fatal("会话不存在")
	}
	// 模拟已有缓存(实际 handler 删除流程会重算)。先手动写一个缓存。
	content := json.RawMessage(`{"msg_type":"text","data":{"text":"cached"}}`)
	_ = env.convRepo.UpdateLastMessage(env.convID, content)

	list, _ := env.msgRepo.ListByConversation(env.convID, 50, 0)
	if len(list) != 1 {
		t.Fatalf("前置:应有 1 条消息,实际 %d", len(list))
	}

	req := httptest.NewRequest(http.MethodDelete, "/api/messages/"+list[0].ID, nil)
	w := httptest.NewRecorder()
	env.engine.ServeHTTP(w, req)
	if w.Code != http.StatusNoContent {
		t.Fatalf("应返回 204,实际 %d", w.Code)
	}

	// 删的是唯一一条 → 全删完 → ClearLastMessage 置 NULL
	conv, _ = env.convRepo.GetByID(env.convID)
	if conv == nil {
		t.Fatal("会话应仍存在")
	}
	if conv.LastMessageContent.Valid {
		t.Errorf("全删完 last_message_content 应为 NULL(Valid=false),实际 Valid=true Raw=%s",
			conv.LastMessageContent.RawMessage)
	}
}
