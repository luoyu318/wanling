package handler

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/repository"
)

// shortName 复用同包 user_handler_test.go 里的定义，本文件不再重复声明。

// TestConversationHandler_List_ReturnsAgentAndLastMessage 验证 IM 风格列表核心场景：
//   - 200 状态码；
//   - 响应包含对端 agent.name（JOIN agents 表生效）；
//   - 响应包含 last_message_content（UpdateLastMessage 写入的 JSON）。
func TestConversationHandler_List_ReturnsAgentAndLastMessage(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	convRepo := repository.NewConversationRepo(db)
	msgRepo := repository.NewMessageRepo(db)
	arepo := repository.NewAgentRepo(db)

	user, err := urepo.Create(shortName(t, "listh"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	agent, err := arepo.Create(user.ID, "ListHAgent", "secret-key")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}
	conv, err := convRepo.FindOrCreate(user.ID, agent.ID)
	if err != nil {
		t.Fatalf("FindOrCreate 失败: %v", err)
	}
	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "hi"},
	})
	if err := convRepo.UpdateLastMessage(conv.ID, content); err != nil {
		t.Fatalf("UpdateLastMessage 失败: %v", err)
	}

	h := NewConversationHandler(convRepo, msgRepo, arepo, urepo)
	r := gin.New()
	r.GET("/api/conversations", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.List(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	body := w.Body.String()
	if !strings.Contains(body, `"name":"ListHAgent"`) {
		t.Errorf("响应缺少 agent.name: %s", body)
	}
	if !strings.Contains(body, `"last_message_content"`) {
		t.Errorf("响应缺少 last_message_content: %s", body)
	}
}

// TestConversationHandler_List_ExcludesNoMessageConversations 验证 IM 列表的过滤行为：
//   - 没有任何消息的会话（last_message_content IS NULL）不应进入列表；
//   - 空结果应返回 [] 而非 null（避免 APP 端反序列化成 null 后报错）。
func TestConversationHandler_List_ExcludesNoMessageConversations(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	convRepo := repository.NewConversationRepo(db)
	msgRepo := repository.NewMessageRepo(db)
	arepo := repository.NewAgentRepo(db)

	user, err := urepo.Create(shortName(t, "excl"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	agent, err := arepo.Create(user.ID, "ExclAgent", "secret-key")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}
	if _, err := convRepo.FindOrCreate(user.ID, agent.ID); err != nil {
		t.Fatalf("FindOrCreate 失败: %v", err)
	}

	h := NewConversationHandler(convRepo, msgRepo, arepo, urepo)
	r := gin.New()
	r.GET("/api/conversations", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.List(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	// 期望空数组（不是 null）
	body := strings.TrimSpace(w.Body.String())
	if body != "[]" {
		t.Errorf("无消息会话不应进列表，期望 [] 实际: %s", body)
	}
}

// TestConversationHandler_FindOrCreate_ReturnsAgentField 验证：FindOrCreate 响应里包含 agent 详情。
// 用于 ChatPage 改造后从 FindOrCreate 返回里直接拿到 agent 信息（无需再发一个 /agents/{id} 请求）。
func TestConversationHandler_FindOrCreate_ReturnsAgentField(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	convRepo := repository.NewConversationRepo(db)
	msgRepo := repository.NewMessageRepo(db)
	arepo := repository.NewAgentRepo(db)

	user, err := urepo.Create(shortName(t, "foc"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	agent, err := arepo.Create(user.ID, "FOCAgent", "secret-key")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}

	h := NewConversationHandler(convRepo, msgRepo, arepo, urepo)
	r := gin.New()
	r.POST("/api/conversations", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.FindOrCreate(c)
	})

	body := `{"agent_id":"` + agent.ID + `"}`
	req := httptest.NewRequest("POST", "/api/conversations", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	resp := w.Body.String()
	if !strings.Contains(resp, `"name":"FOCAgent"`) {
		t.Errorf("FindOrCreate 响应缺少 agent.name: %s", resp)
	}
	if !strings.Contains(resp, `"id":`) {
		t.Errorf("响应缺少 conversation id: %s", resp)
	}
}

// TestConversationHandler_FindOrCreate_Returns404WhenAgentMissing 验证：
//   - agent 不存在时返回 404（而不是 500，避免被 FK 约束触发 500 分支）；
//   - 不会创建孤儿会话（fail fast，FindOrCreate 不应在 agent 不存在时被调用）。
func TestConversationHandler_FindOrCreate_Returns404WhenAgentMissing(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	convRepo := repository.NewConversationRepo(db)
	msgRepo := repository.NewMessageRepo(db)
	arepo := repository.NewAgentRepo(db)

	user, err := urepo.Create(shortName(t, "foc404"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}

	h := NewConversationHandler(convRepo, msgRepo, arepo, urepo)
	r := gin.New()
	r.POST("/api/conversations", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.FindOrCreate(c)
	})

	// 用一个不存在的 UUID（agents 表里没有这条记录）。
	body := `{"agent_id":"00000000-0000-0000-0000-000000000000"}`
	req := httptest.NewRequest("POST", "/api/conversations", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("期望 404，实际: %d body: %s", w.Code, w.Body.String())
	}

	// 验证没有创建孤儿会话。
	convs, err := convRepo.ListByUser(user.ID)
	if err != nil {
		t.Fatalf("ListByUser 失败: %v", err)
	}
	if len(convs) != 0 {
		t.Errorf("agent 不存在时不应创建会话，实际: %d 条", len(convs))
	}
}

// TestConversationHandler_MarkRead_ClearsUnreadCount 验证：
//   - 200 响应；
//   - DB 中 unread_count 已重置为 0。
func TestConversationHandler_MarkRead_ClearsUnreadCount(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	mrepo := repository.NewMessageRepo(db)

	user, _ := urepo.Create(shortName(t, "mr_"), "$2a$10$hash")
	agent, _ := arepo.Create(user.ID, "Agent", "secret-key-placeholder")
	conv, _ := crepo.FindOrCreate(user.ID, agent.ID)

	// 制造 2 条 agent → user 未读消息（事务内 incr）
	for i := 0; i < 2; i++ {
		tx, _ := crepo.BeginTx()
		_, _ = mrepo.CreateTx(tx, conv.ID, "agent", agent.ID, json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`))
		_ = crepo.UpdateLastMessageTx(tx, conv.ID, json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`))
		_ = crepo.IncrUnreadTx(tx, conv.ID)
		_ = tx.Commit()
	}

	h := NewConversationHandler(crepo, mrepo, arepo, urepo)
	r := gin.New()
	r.POST("/api/conversations/:id/read", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.MarkRead(c)
	})

	req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/read", conv.ID), nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}

	var n int
	_ = db.QueryRow(`SELECT unread_count FROM conversations WHERE id = $1`, conv.ID).Scan(&n)
	if n != 0 {
		t.Errorf("unread_count = %d, want 0", n)
	}
}

// TestConversationHandler_MarkRead_Returns404OnForeignConv 验证：
// 其他用户的会话 ID 调本接口返回 404（越权防护）。
func TestConversationHandler_MarkRead_Returns404OnForeignConv(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)

	owner, _ := urepo.Create(shortName(t, "own_"), "$2a$10$hash")
	intruder, _ := urepo.Create(shortName(t, "int_"), "$2a$10$hash")
	agent, _ := arepo.Create(owner.ID, "Agent", "secret-key-placeholder")
	conv, _ := crepo.FindOrCreate(owner.ID, agent.ID)

	h := NewConversationHandler(crepo, repository.NewMessageRepo(db), arepo, urepo)
	r := gin.New()
	r.POST("/api/conversations/:id/read", func(c *gin.Context) {
		c.Set("userID", intruder.ID) // 入侵者
		h.MarkRead(c)
	})

	req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/read", conv.ID), nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("期望 404，实际: %d body: %s", w.Code, w.Body.String())
	}
}

// TestFindOrCreateAsAgentSuccess 验证 agent 视角的 findOrCreate：能正确按 (agent_id, user_id)
// 拿到会话，响应里含 conv id 和 user 详情（不含 password_hash）。
func TestFindOrCreateAsAgentSuccess(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	convRepo := repository.NewConversationRepo(db)
	msgRepo := repository.NewMessageRepo(db)

	// agent 的 owner
	owner, err := urepo.Create(shortName(t, "owner"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	agent, err := arepo.Create(owner.ID, shortName(t, "ag"), "secret-key")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}
	// 聊天对端 user
	target, err := urepo.Create(shortName(t, "target"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create target user: %v", err)
	}

	h := NewConversationHandler(convRepo, msgRepo, arepo, urepo)

	body, _ := json.Marshal(map[string]string{"user_id": target.ID})
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/api/agents/me/conversations", bytes.NewReader(body))
	c.Set("userID", agent.ID) // agent JWT 解析后写入的实际是 agent_id
	c.Set("role", "agent")

	h.FindOrCreateAsAgent(c)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	resp := w.Body.String()
	if !strings.Contains(resp, `"id":`) {
		t.Errorf("missing conv id: %s", resp)
	}
	// 响应里应有 user 详情（username），不应有 password_hash（model.User json:"-" tag）
	if !strings.Contains(resp, `"username":"`) {
		t.Errorf("missing user.username in response: %s", resp)
	}
	if strings.Contains(resp, "password_hash") {
		t.Errorf("password_hash leaked: %s", resp)
	}
}

// TestFindOrCreateAsAgentRejectsNonexistentUser 验证：对端 user 不存在时返回 404（而非 500）。
// 顺序很关键：必须先 GetByID 校验 user 存在，再 FindOrCreate，否则 FK 约束触发 500。
func TestFindOrCreateAsAgentRejectsNonexistentUser(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)

	owner, _ := urepo.Create(shortName(t, "owner"), "$2a$10$hash")
	agent, _ := arepo.Create(owner.ID, shortName(t, "ag"), "secret-key")

	h := NewConversationHandler(
		repository.NewConversationRepo(db), repository.NewMessageRepo(db),
		arepo, urepo,
	)

	body, _ := json.Marshal(map[string]string{"user_id": "00000000-0000-0000-0000-000000000000"})
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/api/agents/me/conversations", bytes.NewReader(body))
	c.Set("userID", agent.ID)
	c.Set("role", "agent")

	h.FindOrCreateAsAgent(c)

	if w.Code != http.StatusNotFound {
		t.Fatalf("expected 404 for nonexistent user, got %d: %s", w.Code, w.Body.String())
	}
}

// TestFindOrCreateAsAgentIdempotent 验证：同一 (agent, user) 二次调用不新建会话，返回同一 conv_id。
// 这是 FindOrCreate 语义的核心，agent 端的缓存兜底依赖此幂等性。
func TestFindOrCreateAsAgentIdempotent(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	convRepo := repository.NewConversationRepo(db)
	msgRepo := repository.NewMessageRepo(db)

	owner, _ := urepo.Create(shortName(t, "owner"), "$2a$10$hash")
	agent, _ := arepo.Create(owner.ID, shortName(t, "ag"), "secret-key")
	target, _ := urepo.Create(shortName(t, "target"), "$2a$10$hash")

	h := NewConversationHandler(convRepo, msgRepo, arepo, urepo)

	call := func() string {
		body, _ := json.Marshal(map[string]string{"user_id": target.ID})
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Request = httptest.NewRequest("POST", "/", bytes.NewReader(body))
		c.Set("userID", agent.ID)
		h.FindOrCreateAsAgent(c)
		var resp map[string]interface{}
		_ = json.Unmarshal(w.Body.Bytes(), &resp)
		id, _ := resp["id"].(string)
		return id
	}

	id1 := call()
	id2 := call()
	if id1 == "" || id2 == "" {
		t.Fatalf("expected non-empty ids, got %q and %q", id1, id2)
	}
	if id1 != id2 {
		t.Errorf("expected idempotent conv_id, got %s then %s", id1, id2)
	}
}
