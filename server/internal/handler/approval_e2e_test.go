package handler

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/approval"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// TestApprovalE2ECommandHappyPath 完整跑命令审批的 happy path：
// agent 创建审批 → user allow_once → 状态机推进 → DB 终态 + content 双写
func TestApprovalE2ECommandHappyPath(t *testing.T) {
	db := repository.SetupTestDB(t)
	userID, agentID, convID := setupApprovalFixture(t, db)
	repo := repository.NewApprovalRepo(db)
	agentRepo := repository.NewAgentRepo(db)
	h := newTestHub(db)
	svc := approval.NewService(repo, h, repo)
	hnd := NewApprovalHandler(
		repo, repository.NewMessageRepo(db),
		repository.NewConversationRepo(db), agentRepo,
		repository.NewParticipantRepo(db),
		h, svc,
	)

	// 1. agent 创建审批
	createBody, _ := json.Marshal(map[string]any{
		"card_type": "command", "title": "命令审批", "preview": "rm -rf /tmp",
		"session_key": "exec:1", "timeout_sec": 300,
	})
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/api/conversations/"+convID+"/approvals", bytes.NewReader(createBody))
	c.Params = gin.Params{{Key: "id", Value: convID}}
	c.Set("userID", agentID)
	c.Set("role", "agent")
	hnd.CreateApproval(c)
	if w.Code != http.StatusOK {
		t.Fatalf("CreateApproval: %d %s", w.Code, w.Body.String())
	}
	var createResp map[string]any
	json.Unmarshal(w.Body.Bytes(), &createResp)
	approvalID := createResp["approval_id"].(string)
	if createResp["state"] != "pending" {
		t.Fatalf("expected pending state, got %v", createResp["state"])
	}

	// 2. user 决策 allow_once
	decideBody, _ := json.Marshal(map[string]string{"action_id": "allow_once"})
	w2 := httptest.NewRecorder()
	c2, _ := gin.CreateTestContext(w2)
	c2.Request = httptest.NewRequest("POST", "/api/approvals/"+approvalID+"/decide", bytes.NewReader(decideBody))
	c2.Params = gin.Params{{Key: "id", Value: approvalID}}
	c2.Set("userID", userID)
	c2.Set("role", "user")
	hnd.Decide(c2)
	if w2.Code != http.StatusOK {
		t.Fatalf("Decide: %d %s", w2.Code, w2.Body.String())
	}

	// 3. 验证 DB 终态
	got, _ := repo.GetByID(approvalID)
	if got.State != model.ApprovalStateApproved {
		t.Fatalf("expected approved, got %s", got.State)
	}
	if got.DecidedAction == nil || *got.DecidedAction != "allow_once" {
		t.Fatalf("decided_action wrong: %v", got.DecidedAction)
	}
	if got.DecidedBy == nil || *got.DecidedBy != userID {
		t.Fatalf("decided_by wrong: %v", got.DecidedBy)
	}

	// 4. 验证 message content 双写
	var contentRaw []byte
	err := db.QueryRow(`SELECT content FROM messages WHERE id = $1`, got.MessageID).Scan(&contentRaw)
	if err != nil {
		t.Fatalf("read msg content: %v", err)
	}
	var wrapper struct {
		Data struct {
			State         string  `json:"state"`
			DecidedAction *string `json:"decided_action"`
		} `json:"data"`
	}
	if err := json.Unmarshal(contentRaw, &wrapper); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if wrapper.Data.State != "approved" {
		t.Fatalf("content.state wrong: %s", wrapper.Data.State)
	}
	if wrapper.Data.DecidedAction == nil || *wrapper.Data.DecidedAction != "allow_once" {
		t.Fatalf("content.decided_action wrong: %v", wrapper.Data.DecidedAction)
	}
}

// TestApprovalE2ECommandAllowAlways 命令审批 allow_always 后，同类命令自动 approved
func TestApprovalE2ECommandAllowAlways(t *testing.T) {
	db := repository.SetupTestDB(t)
	userID, agentID, convID := setupApprovalFixture(t, db)
	repo := repository.NewApprovalRepo(db)
	agentRepo := repository.NewAgentRepo(db)
	h := newTestHub(db)
	svc := approval.NewService(repo, h, repo)
	hnd := NewApprovalHandler(
		repo, repository.NewMessageRepo(db),
		repository.NewConversationRepo(db), agentRepo,
		repository.NewParticipantRepo(db),
		h, svc,
	)

	pattern := "rm -rf *"
	// 1. agent 创建审批（带 allow_pattern）
	createBody, _ := json.Marshal(map[string]any{
		"card_type": "command", "title": "t", "preview": "rm -rf /tmp",
		"session_key": "k1", "allow_pattern": pattern,
	})
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/", bytes.NewReader(createBody))
	c.Params = gin.Params{{Key: "id", Value: convID}}
	c.Set("userID", agentID)
	c.Set("role", "agent")
	hnd.CreateApproval(c)
	if w.Code != http.StatusOK {
		t.Fatalf("create: %d %s", w.Code, w.Body.String())
	}
	var createResp map[string]any
	json.Unmarshal(w.Body.Bytes(), &createResp)
	approvalID := createResp["approval_id"].(string)

	// 2. user 决策 allow_always
	decideBody, _ := json.Marshal(map[string]string{"action_id": "allow_always"})
	w2 := httptest.NewRecorder()
	c2, _ := gin.CreateTestContext(w2)
	c2.Request = httptest.NewRequest("POST", "/", bytes.NewReader(decideBody))
	c2.Params = gin.Params{{Key: "id", Value: approvalID}}
	c2.Set("userID", userID)
	c2.Set("role", "user")
	hnd.Decide(c2)
	if w2.Code != http.StatusOK {
		t.Fatalf("decide allow_always: %d %s", w2.Code, w2.Body.String())
	}

	// 3. agent 再次创建同类命令 → 应直接 auto-approved
	createBody2, _ := json.Marshal(map[string]any{
		"card_type": "command", "title": "t2", "preview": "rm -rf /var/cache",
		"session_key": "k2", "allow_pattern": pattern,
	})
	w3 := httptest.NewRecorder()
	c3, _ := gin.CreateTestContext(w3)
	c3.Request = httptest.NewRequest("POST", "/", bytes.NewReader(createBody2))
	c3.Params = gin.Params{{Key: "id", Value: convID}}
	c3.Set("userID", agentID)
	c3.Set("role", "agent")
	hnd.CreateApproval(c3)
	if w3.Code != http.StatusOK {
		t.Fatalf("second create: %d %s", w3.Code, w3.Body.String())
	}
	var resp2 map[string]any
	json.Unmarshal(w3.Body.Bytes(), &resp2)
	if resp2["state"] != "approved" || resp2["auto_approved"] != true {
		t.Fatalf("expected auto-approved, got %v", resp2)
	}
}
