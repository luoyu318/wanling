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
	"github.com/wanling/server/internal/approval"
	"github.com/wanling/server/internal/hub"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// setupApprovalFixture 建 user/agent/conv，返回 ID。
// 复用 SetupTestDB 跑过 migration 001-008。
func setupApprovalFixture(t *testing.T, db *sql.DB) (userID, agentID, convID string) {
	t.Helper()
	userRepo := repository.NewUserRepo(db)
	agentRepo := repository.NewAgentRepo(db)
	convRepo := repository.NewConversationRepo(db)

	user, err := userRepo.Create(shortName(t, "u"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	agent, err := agentRepo.Create(user.ID, shortName(t, "a"), "secret")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}
	conv, err := convRepo.FindOrCreate(user.ID, agent.ID)
	if err != nil {
		t.Fatalf("create conv: %v", err)
	}
	return user.ID, agent.ID, conv.ID
}

// TestCreateApprovalSuccess agent 发起审批卡片，返回 approval_id + state=pending，
// DB 落了 message + approval，actions 数量按 card_type 决定。
func TestCreateApprovalSuccess(t *testing.T) {
	db := repository.SetupTestDB(t)
	userID, agentID, convID := setupApprovalFixture(t, db)
	repo := repository.NewApprovalRepo(db)
	agentRepo := repository.NewAgentRepo(db)
	// 不启动 hub.Run(测试不需真实广播)，SendToConv 对没注册的 client 是 noop。
	h := hub.NewHub(nil, agentRepo)
	hnd := NewApprovalHandler(
		repo, repository.NewMessageRepo(db),
		repository.NewConversationRepo(db), agentRepo,
		h, nil, // service 暂时 nil，CreateApproval 不调 service
	)

	body := map[string]any{
		"card_type":   "command",
		"title":       "命令执行审批",
		"preview":     "rm -rf /tmp",
		"session_key": "exec:1",
		"timeout_sec": 300,
		"meta": []map[string]any{
			{"icon": "📁", "text": "/home"},
		},
	}
	bodyBytes, _ := json.Marshal(body)

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/api/conversations/"+convID+"/approvals", bytes.NewReader(bodyBytes))
	c.Params = gin.Params{{Key: "id", Value: convID}}
	c.Set("userID", agentID)
	c.Set("role", "agent")

	hnd.CreateApproval(c)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal resp: %v", err)
	}
	if resp["approval_id"] == nil || resp["state"] != "pending" {
		t.Fatalf("unexpected resp: %v", resp)
	}

	// 验证 DB 落了 message + approval
	approvalID := resp["approval_id"].(string)
	a, _ := repo.GetByID(approvalID)
	if a == nil || a.State != model.ApprovalStatePending {
		t.Fatalf("approval wrong: %+v", a)
	}
	if len(a.Actions) != 3 { // command = 3 按钮 (allow_once / allow_always / deny)
		t.Fatalf("expected 3 actions, got %d", len(a.Actions))
	}
	if a.UserID != userID {
		t.Errorf("approval.UserID = %q, want %q", a.UserID, userID)
	}
}

// TestCreateApprovalRejectsNonAgent 非 agent role 调用返回 403。
func TestCreateApprovalRejectsNonAgent(t *testing.T) {
	db := repository.SetupTestDB(t)
	_, _, convID := setupApprovalFixture(t, db)
	agentRepo := repository.NewAgentRepo(db)
	hnd := NewApprovalHandler(
		repository.NewApprovalRepo(db), repository.NewMessageRepo(db),
		repository.NewConversationRepo(db), agentRepo,
		hub.NewHub(nil, agentRepo), nil,
	)

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/", bytes.NewReader([]byte(`{}`)))
	c.Params = gin.Params{{Key: "id", Value: convID}}
	c.Set("userID", "u-1")
	c.Set("role", "user") // 非 agent

	hnd.CreateApproval(c)
	if w.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", w.Code)
	}
}

// TestCreateApprovalRejectsWrongAgent 会话的 agent_id 与当前 agent 不匹配，返回 403。
func TestCreateApprovalRejectsWrongAgent(t *testing.T) {
	db := repository.SetupTestDB(t)
	_, _, convID := setupApprovalFixture(t, db)
	agentRepo := repository.NewAgentRepo(db)
	hnd := NewApprovalHandler(
		repository.NewApprovalRepo(db), repository.NewMessageRepo(db),
		repository.NewConversationRepo(db), agentRepo,
		hub.NewHub(nil, agentRepo), nil,
	)

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/", bytes.NewReader([]byte(`{"card_type":"command","title":"t","session_key":"k"}`)))
	c.Params = gin.Params{{Key: "id", Value: convID}}
	c.Set("userID", "another-agent-id")
	c.Set("role", "agent")

	hnd.CreateApproval(c)
	if w.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for wrong agent, got %d", w.Code)
	}
}

// TestDecideApprovalSuccess user 同意审批，state 推进到 approved。
func TestDecideApprovalSuccess(t *testing.T) {
	db := repository.SetupTestDB(t)
	userID, agentID, convID := setupApprovalFixture(t, db)
	repo := repository.NewApprovalRepo(db)
	msgRepo := repository.NewMessageRepo(db)
	convRepo := repository.NewConversationRepo(db)
	agentRepo := repository.NewAgentRepo(db)

	// 建一条 pending approval（直接走 repo，绕过 CreateApproval handler）
	cardData := model.CardContent{
		CardType: model.CardTypeCommand, Title: "命令审批", Preview: "rm -rf x",
		Actions: []model.ApprovalAction{
			{ID: "allow_once"}, {ID: "deny"},
		},
		State:     model.ApprovalStatePending,
		ExpiresAt: time.Now().Add(5 * time.Minute).UTC(),
	}
	contentMap := struct {
		MsgType string          `json:"msg_type"`
		Data    model.CardContent `json:"data"`
	}{MsgType: "card", Data: cardData}
	contentBytes, _ := json.Marshal(contentMap)
	msg, _ := msgRepo.Create(convID, "agent", agentID, contentBytes)

	a, _ := repo.Create(model.Approval{
		MessageID: msg.ID, ConversationID: convID, AgentID: agentID, UserID: userID,
		CardType: model.CardTypeCommand, Actions: cardData.Actions,
		ExpiresAt:  time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "exec:1",
	})

	// service 用真 repo + 真 hub（但 hub 不开 Run，noop 广播）
	h := hub.NewHub(nil, agentRepo)
	svc := approval.NewService(repo, h, repo)
	hnd := NewApprovalHandler(repo, msgRepo, convRepo, agentRepo, h, svc)

	body, _ := json.Marshal(map[string]string{"action_id": "allow_once"})
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/api/approvals/"+a.ID+"/decide", bytes.NewReader(body))
	c.Params = gin.Params{{Key: "id", Value: a.ID}}
	c.Set("userID", userID)
	c.Set("role", "user")

	hnd.Decide(c)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	got, _ := repo.GetByID(a.ID)
	if got.State != model.ApprovalStateApproved {
		t.Fatalf("expected approved state, got %s", got.State)
	}
}

// TestDecideApprovalRejectsAgent 非 user role 调用返回 403。
func TestDecideApprovalRejectsAgent(t *testing.T) {
	db := repository.SetupTestDB(t)
	_, agentID, _ := setupApprovalFixture(t, db)
	repo := repository.NewApprovalRepo(db)
	h := hub.NewHub(nil, repository.NewAgentRepo(db))
	svc := approval.NewService(repo, h, repo)
	hnd := NewApprovalHandler(repo, repository.NewMessageRepo(db),
		repository.NewConversationRepo(db), repository.NewAgentRepo(db), h, svc)

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/", bytes.NewReader([]byte(`{"action_id":"deny"}`)))
	c.Params = gin.Params{{Key: "id", Value: "x"}}
	c.Set("userID", agentID)
	c.Set("role", "agent") // 非 user

	hnd.Decide(c)
	if w.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", w.Code)
	}
}

// TestDecideApprovalConflict approval 已 approved，再次 decide 返回 409。
func TestDecideApprovalConflict(t *testing.T) {
	db := repository.SetupTestDB(t)
	userID, agentID, convID := setupApprovalFixture(t, db)
	repo := repository.NewApprovalRepo(db)
	msgRepo := repository.NewMessageRepo(db)
	convRepo := repository.NewConversationRepo(db)
	agentRepo := repository.NewAgentRepo(db)

	// 建一条已 approved 的审批
	cardData := model.CardContent{
		CardType: model.CardTypeCommand, Title: "t", Preview: "rm -rf x",
		Actions:   []model.ApprovalAction{{ID: "allow_once"}, {ID: "deny"}},
		State:     model.ApprovalStateApproved, // 已 approved
		ExpiresAt: time.Now().Add(5 * time.Minute).UTC(),
	}
	contentMap := struct {
		MsgType string          `json:"msg_type"`
		Data    model.CardContent `json:"data"`
	}{MsgType: "card", Data: cardData}
	contentBytes, _ := json.Marshal(contentMap)
	msg, _ := msgRepo.Create(convID, "agent", agentID, contentBytes)

	a, _ := repo.Create(model.Approval{
		MessageID: msg.ID, ConversationID: convID, AgentID: agentID, UserID: userID,
		CardType: model.CardTypeCommand, Actions: cardData.Actions,
		ExpiresAt:  time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "k",
	})
	// 推到 approved
	repo.MarkDecided(a.ID, "allow_once", userID, "", nil)

	h := hub.NewHub(nil, agentRepo)
	svc := approval.NewService(repo, h, repo)
	hnd := NewApprovalHandler(repo, msgRepo, convRepo, agentRepo, h, svc)

	body, _ := json.Marshal(map[string]string{"action_id": "deny"})
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/", bytes.NewReader(body))
	c.Params = gin.Params{{Key: "id", Value: a.ID}}
	c.Set("userID", userID)
	c.Set("role", "user")

	hnd.Decide(c)
	if w.Code != http.StatusConflict {
		t.Fatalf("expected 409 for already-decided, got %d: %s", w.Code, w.Body.String())
	}
}

// TestGetApprovalSuccess GET 返回审批详情。
func TestGetApprovalSuccess(t *testing.T) {
	db := repository.SetupTestDB(t)
	userID, agentID, convID := setupApprovalFixture(t, db)
	repo := repository.NewApprovalRepo(db)
	msgRepo := repository.NewMessageRepo(db)

	cardData := model.CardContent{
		CardType: model.CardTypeCommand, Title: "t",
		Actions:   []model.ApprovalAction{{ID: "allow_once"}},
		State:     model.ApprovalStatePending, ExpiresAt: time.Now().Add(5 * time.Minute).UTC(),
	}
	contentMap := struct {
		MsgType string          `json:"msg_type"`
		Data    model.CardContent `json:"data"`
	}{MsgType: "card", Data: cardData}
	contentBytes, _ := json.Marshal(contentMap)
	msg, _ := msgRepo.Create(convID, "agent", agentID, contentBytes)
	a, _ := repo.Create(model.Approval{
		MessageID: msg.ID, ConversationID: convID, AgentID: agentID, UserID: userID,
		CardType: model.CardTypeCommand, Actions: cardData.Actions,
		ExpiresAt:  time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "k",
	})

	hnd := NewApprovalHandler(repo, msgRepo, repository.NewConversationRepo(db),
		repository.NewAgentRepo(db), hub.NewHub(nil, repository.NewAgentRepo(db)), nil)

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("GET", "/api/approvals/"+a.ID, nil)
	c.Params = gin.Params{{Key: "id", Value: a.ID}}
	c.Set("userID", userID)
	c.Set("role", "user")

	hnd.Get(c)
	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	var resp map[string]any
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["id"] != a.ID {
		t.Fatalf("id mismatch: %v", resp["id"])
	}
}

// TestGetApprovalNotFound 不存在的 ID 返回 404。
func TestGetApprovalNotFound(t *testing.T) {
	db := repository.SetupTestDB(t)
	hnd := NewApprovalHandler(repository.NewApprovalRepo(db), repository.NewMessageRepo(db),
		repository.NewConversationRepo(db), repository.NewAgentRepo(db),
		hub.NewHub(nil, repository.NewAgentRepo(db)), nil)

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("GET", "/api/approvals/nonexistent", nil)
	c.Params = gin.Params{{Key: "id", Value: "nonexistent"}}

	hnd.Get(c)
	if w.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", w.Code)
	}
}
