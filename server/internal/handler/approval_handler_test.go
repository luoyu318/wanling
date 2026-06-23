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
