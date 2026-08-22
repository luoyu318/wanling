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

	user, err := userRepo.Create(t.Context(), shortName(t, "u"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	agent, err := agentRepo.Create(t.Context(), user.ID, shortName(t, "a"), "secret", "")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}
	conv, err := convRepo.FindOrCreateDM(t.Context(), "dm_user_agent", repository.DMMembers{
		Initiator: repository.ParticipantInput{MemberID: user.ID, MemberType: "user", Role: "owner"},
		Other:     repository.ParticipantInput{MemberID: agent.ID, MemberType: "agent", Role: "member"},
	})
	if err != nil {
		t.Fatalf("create conv: %v", err)
	}
	return user.ID, agent.ID, conv.ID
}

// newTestHub 构造测试用 Hub(不启动 Run),统一带 participantRepo 依赖。
// approval handler 测试用例较多,抽出 helper 避免每个 case 重复构造。
func newTestHub(db *sql.DB) *hub.Hub {
	return hub.NewHub(nil, repository.NewAgentRepo(db), repository.NewParticipantRepo(db), nil)
}

// TestCreateApprovalSuccess agent 发起审批卡片，返回 approval_id + state=pending，
// DB 落了 message + approval，actions 数量按 card_type 决定。
func TestCreateApprovalSuccess(t *testing.T) {
	db := repository.SetupTestDB(t)
	_, agentID, convID := setupApprovalFixture(t, db)
	repo := repository.NewApprovalRepo(db)
	agentRepo := repository.NewAgentRepo(db)
	// 不启动 hub.Run(测试不需真实广播)，SendToConv 对没注册的 client 是 noop。
	h := newTestHub(db)
	hnd := NewApprovalHandler(
		repo, repository.NewMessageRepo(db),
		repository.NewConversationRepo(db), agentRepo,
		repository.NewParticipantRepo(db),
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

	data := AssertOk(t, w, http.StatusOK)
	if data["approval_id"] == nil || data["state"] != "pending" {
		t.Fatalf("unexpected resp: %v", data)
	}

	// 验证 DB 落了 message + approval
	approvalID := data["approval_id"].(string)
	a, _ := repo.GetByID(t.Context(), approvalID)
	if a == nil || a.State != model.ApprovalStatePending {
		t.Fatalf("approval wrong: %+v", a)
	}
	if len(a.Actions) != 3 { // command = 3 按钮 (allow_once / allow_always / deny)
		t.Fatalf("expected 3 actions, got %d", len(a.Actions))
	}
	if a.InitiatorType != "agent" || a.InitiatorID != agentID {
		t.Errorf("approval.Initiator = (%q,%q), want (agent,%q)", a.InitiatorType, a.InitiatorID, agentID)
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
		repository.NewParticipantRepo(db),
		newTestHub(db), nil,
	)

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/", bytes.NewReader([]byte(`{}`)))
	c.Params = gin.Params{{Key: "id", Value: convID}}
	c.Set("userID", "u-1")
	c.Set("role", "user") // 非 agent

	hnd.CreateApproval(c)
	AssertErr(t, w, http.StatusForbidden, "forbidden")
}

// TestCreateApprovalRejectsWrongAgent 会话的 agent_id 与当前 agent 不匹配，返回 403。
func TestCreateApprovalRejectsWrongAgent(t *testing.T) {
	db := repository.SetupTestDB(t)
	_, _, convID := setupApprovalFixture(t, db)
	agentRepo := repository.NewAgentRepo(db)
	hnd := NewApprovalHandler(
		repository.NewApprovalRepo(db), repository.NewMessageRepo(db),
		repository.NewConversationRepo(db), agentRepo,
		repository.NewParticipantRepo(db),
		newTestHub(db), nil,
	)

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/", bytes.NewReader([]byte(`{"card_type":"command","title":"t","session_key":"k"}`)))
	c.Params = gin.Params{{Key: "id", Value: convID}}
	// participants 模型走 participantRepo.Exists 查询,member_id 列为 UUID 类型,
	// 必须用合法 UUID(任意非该会话 agent 的 UUID 即可触发 not member 分支)。
	c.Set("userID", "00000000-0000-0000-0000-000000000000")
	c.Set("role", "agent")

	hnd.CreateApproval(c)
	AssertErr(t, w, http.StatusForbidden, "forbidden")
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
		MsgType string            `json:"msg_type"`
		Data    model.CardContent `json:"data"`
	}{MsgType: "card", Data: cardData}
	contentBytes, _ := json.Marshal(contentMap)
	msg, _ := msgRepo.Create(t.Context(), convID, "agent", agentID, json.RawMessage(contentBytes))

	a, _ := repo.Create(t.Context(), model.Approval{
		MessageID: msg.ID, ConversationID: convID,
		InitiatorType: "agent", InitiatorID: agentID,
		CardType: model.CardTypeCommand, Actions: cardData.Actions,
		ExpiresAt:  time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "exec:1",
	})

	// service 用真 repo + 真 hub（但 hub 不开 Run，noop 广播）
	h := newTestHub(db)
	svc := approval.NewService(repo, h, repo)
	hnd := NewApprovalHandler(repo, msgRepo, convRepo, agentRepo,
		repository.NewParticipantRepo(db), h, svc)

	body, _ := json.Marshal(map[string]string{"action_id": "allow_once"})
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/api/approvals/"+a.ID+"/decide", bytes.NewReader(body))
	c.Params = gin.Params{{Key: "id", Value: a.ID}}
	c.Set("userID", userID)
	c.Set("role", "user")

	hnd.Decide(c)
	AssertOk(t, w, http.StatusOK)

	got, _ := repo.GetByID(t.Context(), a.ID)
	if got.State != model.ApprovalStateApproved {
		t.Fatalf("expected approved state, got %s", got.State)
	}
}

// TestDecideApprovalRejectsAgent 非 user role 调用返回 403。
func TestDecideApprovalRejectsAgent(t *testing.T) {
	db := repository.SetupTestDB(t)
	_, agentID, _ := setupApprovalFixture(t, db)
	repo := repository.NewApprovalRepo(db)
	h := newTestHub(db)
	svc := approval.NewService(repo, h, repo)
	hnd := NewApprovalHandler(repo, repository.NewMessageRepo(db),
		repository.NewConversationRepo(db), repository.NewAgentRepo(db),
		repository.NewParticipantRepo(db), h, svc)

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/", bytes.NewReader([]byte(`{"action_id":"deny"}`)))
	c.Params = gin.Params{{Key: "id", Value: "x"}}
	c.Set("userID", agentID)
	c.Set("role", "agent") // 非 user

	hnd.Decide(c)
	AssertErr(t, w, http.StatusForbidden, "forbidden")
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
		MsgType string            `json:"msg_type"`
		Data    model.CardContent `json:"data"`
	}{MsgType: "card", Data: cardData}
	contentBytes, _ := json.Marshal(contentMap)
	msg, _ := msgRepo.Create(t.Context(), convID, "agent", agentID, json.RawMessage(contentBytes))

	a, _ := repo.Create(t.Context(), model.Approval{
		MessageID: msg.ID, ConversationID: convID,
		InitiatorType: "agent", InitiatorID: agentID,
		CardType: model.CardTypeCommand, Actions: cardData.Actions,
		ExpiresAt:  time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "k",
	})
	// 推到 approved
	repo.MarkDecided(t.Context(), a.ID, "allow_once", "user", userID, "", nil, nil)

	h := newTestHub(db)
	svc := approval.NewService(repo, h, repo)
	hnd := NewApprovalHandler(repo, msgRepo, convRepo, agentRepo,
		repository.NewParticipantRepo(db), h, svc)

	body, _ := json.Marshal(map[string]string{"action_id": "deny"})
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/", bytes.NewReader(body))
	c.Params = gin.Params{{Key: "id", Value: a.ID}}
	c.Set("userID", userID)
	c.Set("role", "user")

	hnd.Decide(c)
	respBody := AssertErrBody(t, w, http.StatusConflict, "invalid_state")
	// 业务字段 state 必须保留在 error 子对象内
	errObj, _ := respBody["error"].(map[string]any)
	if errObj["state"] != string(model.ApprovalStateApproved) {
		t.Fatalf("expected error.state=%s, got %v", model.ApprovalStateApproved, errObj["state"])
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
		Actions: []model.ApprovalAction{{ID: "allow_once"}},
		State:   model.ApprovalStatePending, ExpiresAt: time.Now().Add(5 * time.Minute).UTC(),
	}
	contentMap := struct {
		MsgType string            `json:"msg_type"`
		Data    model.CardContent `json:"data"`
	}{MsgType: "card", Data: cardData}
	contentBytes, _ := json.Marshal(contentMap)
	msg, _ := msgRepo.Create(t.Context(), convID, "agent", agentID, json.RawMessage(contentBytes))
	a, _ := repo.Create(t.Context(), model.Approval{
		MessageID: msg.ID, ConversationID: convID,
		InitiatorType: "agent", InitiatorID: agentID,
		CardType: model.CardTypeCommand, Actions: cardData.Actions,
		ExpiresAt:  time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "k",
	})

	hnd := NewApprovalHandler(repo, msgRepo, repository.NewConversationRepo(db),
		repository.NewAgentRepo(db), repository.NewParticipantRepo(db), newTestHub(db), nil)

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("GET", "/api/approvals/"+a.ID, nil)
	c.Params = gin.Params{{Key: "id", Value: a.ID}}
	c.Set("userID", userID)
	c.Set("role", "user")

	hnd.Get(c)
	data := AssertOk(t, w, http.StatusOK)
	if data["id"] != a.ID {
		t.Fatalf("id mismatch: %v", data["id"])
	}
}

// TestGetApprovalNotFound 不存在的 ID 返回 404。
func TestGetApprovalNotFound(t *testing.T) {
	db := repository.SetupTestDB(t)
	hnd := NewApprovalHandler(repository.NewApprovalRepo(db), repository.NewMessageRepo(db),
		repository.NewConversationRepo(db), repository.NewAgentRepo(db),
		repository.NewParticipantRepo(db), newTestHub(db), nil)

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("GET", "/api/approvals/nonexistent", nil)
	c.Params = gin.Params{{Key: "id", Value: "nonexistent"}}

	hnd.Get(c)
	AssertErr(t, w, http.StatusNotFound, "not_found")
}

// TestCreateApprovalQuestion question 卡创建：缺 options / id 重复返回 400，
// 正常创建落 options + multi_select 双写到 message content，actions = answer/reject。
func TestCreateApprovalQuestion(t *testing.T) {
	db := repository.SetupTestDB(t)
	_, agentID, convID := setupApprovalFixture(t, db)
	repo := repository.NewApprovalRepo(db)
	msgRepo := repository.NewMessageRepo(db)
	hnd := NewApprovalHandler(
		repo, msgRepo,
		repository.NewConversationRepo(db), repository.NewAgentRepo(db),
		repository.NewParticipantRepo(db),
		newTestHub(db), nil,
	)

	post := func(body map[string]any) *httptest.ResponseRecorder {
		bodyBytes, _ := json.Marshal(body)
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Request = httptest.NewRequest("POST", "/api/conversations/"+convID+"/approvals", bytes.NewReader(bodyBytes))
		c.Params = gin.Params{{Key: "id", Value: convID}}
		c.Set("userID", agentID)
		c.Set("role", "agent")
		hnd.CreateApproval(c)
		return w
	}

	// 缺 options → 400
	w := post(map[string]any{
		"card_type": "question", "title": "选环境", "session_key": "sk1",
	})
	AssertErr(t, w, http.StatusBadRequest, "bad_request")

	// options id 重复 → 400
	w = post(map[string]any{
		"card_type": "question", "title": "选环境", "session_key": "sk1",
		"options": []map[string]string{{"id": "dev", "label": "测试"}, {"id": "dev", "label": "重复"}},
	})
	AssertErr(t, w, http.StatusBadRequest, "bad_request")

	// 正常创建
	w = post(map[string]any{
		"card_type":    "question",
		"title":        "选环境",
		"session_key":  "sk1",
		"options":      []map[string]string{{"id": "dev", "label": "测试"}, {"id": "staging", "label": "预发"}},
		"multi_select": true,
	})
	data := AssertOk(t, w, http.StatusOK)
	approvalID, _ := data["approval_id"].(string)
	if approvalID == "" {
		t.Fatalf("missing approval_id: %v", data)
	}

	a, _ := repo.GetByID(t.Context(), approvalID)
	if a == nil || a.CardType != model.CardTypeQuestion || a.State != model.ApprovalStatePending {
		t.Fatalf("approval wrong: %+v", a)
	}
	if len(a.Actions) != 2 || a.Actions[0].ID != "answer" || a.Actions[1].ID != "reject" {
		t.Fatalf("question actions wrong: %+v", a.Actions)
	}

	// options + multi_select 双写验证：messages.content.data.options 含两项
	msg, err := msgRepo.Get(t.Context(), a.MessageID)
	if err != nil {
		t.Fatalf("get msg: %v", err)
	}
	var wrapper struct {
		Data model.CardContent `json:"data"`
	}
	if err := json.Unmarshal(msg.Content, &wrapper); err != nil {
		t.Fatalf("unmarshal content: %v", err)
	}
	if len(wrapper.Data.Options) != 2 || wrapper.Data.Options[0].ID != "dev" || wrapper.Data.Options[1].ID != "staging" {
		t.Fatalf("options not persisted: %+v", wrapper.Data.Options)
	}
	if !wrapper.Data.MultiSelect {
		t.Fatal("multi_select not persisted")
	}
}

// TestDecideQuestionMultiSelect question 多选决策：非法 answer → 400 invalid_action，
// 合法多选 → approved 且 answers 双写到 messages.content.data.answers。
func TestDecideQuestionMultiSelect(t *testing.T) {
	db := repository.SetupTestDB(t)
	userID, agentID, convID := setupApprovalFixture(t, db)
	repo := repository.NewApprovalRepo(db)
	msgRepo := repository.NewMessageRepo(db)

	// 直接 repo 建 question 多选卡（创建链路由 TestCreateApprovalQuestion 覆盖）
	cardData := model.CardContent{
		CardType: model.CardTypeQuestion, Title: "选环境",
		Options:     []model.ApprovalOption{{ID: "dev", Label: "测试"}, {ID: "staging", Label: "预发"}},
		MultiSelect: true,
		Actions:     buildActions(model.CardTypeQuestion),
		State:       model.ApprovalStatePending,
		ExpiresAt:   time.Now().Add(5 * time.Minute).UTC(),
	}
	contentMap := struct {
		MsgType string            `json:"msg_type"`
		Data    model.CardContent `json:"data"`
	}{MsgType: "card", Data: cardData}
	contentBytes, _ := json.Marshal(contentMap)
	msg, err := msgRepo.Create(t.Context(), convID, "agent", agentID, contentBytes)
	if err != nil {
		t.Fatalf("create msg: %v", err)
	}
	a, err := repo.Create(t.Context(), model.Approval{
		MessageID: msg.ID, ConversationID: convID,
		InitiatorType: "agent", InitiatorID: agentID,
		CardType: model.CardTypeQuestion, Actions: cardData.Actions,
		ExpiresAt:  time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "sk2",
	})
	if err != nil {
		t.Fatalf("create approval: %v", err)
	}

	h := newTestHub(db)
	svc := approval.NewService(repo, h, repo)
	hnd := NewApprovalHandler(repo, msgRepo, repository.NewConversationRepo(db),
		repository.NewAgentRepo(db), repository.NewParticipantRepo(db), h, svc)

	decide := func(body map[string]any) *httptest.ResponseRecorder {
		bodyBytes, _ := json.Marshal(body)
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Request = httptest.NewRequest("POST", "/api/approvals/"+a.ID+"/decide", bytes.NewReader(bodyBytes))
		c.Params = gin.Params{{Key: "id", Value: a.ID}}
		c.Set("userID", userID)
		c.Set("role", "user")
		hnd.Decide(c)
		return w
	}

	// 非法 answer（不在 options 内）→ 400 invalid_action
	w := decide(map[string]any{"action_id": "answer", "answers": []string{"dev", "prod"}})
	AssertErr(t, w, http.StatusBadRequest, "invalid_action")

	// 合法多选 → 200
	w = decide(map[string]any{"action_id": "answer", "answers": []string{"dev", "staging"}})
	AssertOk(t, w, http.StatusOK)

	// content 双写验证：state=approved + answers 含两项
	updated, err := msgRepo.Get(t.Context(), msg.ID)
	if err != nil {
		t.Fatalf("get msg: %v", err)
	}
	var wrapper struct {
		Data model.CardContent `json:"data"`
	}
	if err := json.Unmarshal(updated.Content, &wrapper); err != nil {
		t.Fatalf("unmarshal content: %v", err)
	}
	if wrapper.Data.State != model.ApprovalStateApproved {
		t.Fatalf("content.state=%s, want approved", wrapper.Data.State)
	}
	if len(wrapper.Data.Answers) != 2 || wrapper.Data.Answers[0] != "dev" || wrapper.Data.Answers[1] != "staging" {
		t.Fatalf("answers not double-written: %+v", wrapper.Data.Answers)
	}
}

// TestApprovalGet_OwnerCheck 覆盖 IDOR 防护:owner user / owner agent 放行,
// 其他 user 拿 UUID 枚举访问返回 403。
func TestApprovalGet_OwnerCheck(t *testing.T) {
	db := repository.SetupTestDB(t)
	userA, agentID, convID := setupApprovalFixture(t, db)
	// userB 作为攻击者:另起一个 user,与该 approval 毫无关系
	userRepo := repository.NewUserRepo(db)
	userB, err := userRepo.Create(t.Context(), shortName(t, "ub"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create userB: %v", err)
	}

	repo := repository.NewApprovalRepo(db)
	msgRepo := repository.NewMessageRepo(db)

	// 建一条 pending approval,owner = userA / agentID
	cardData := model.CardContent{
		CardType: model.CardTypeCommand, Title: "t",
		Actions: []model.ApprovalAction{{ID: "allow_once"}},
		State:   model.ApprovalStatePending, ExpiresAt: time.Now().Add(5 * time.Minute).UTC(),
	}
	contentMap := struct {
		MsgType string            `json:"msg_type"`
		Data    model.CardContent `json:"data"`
	}{MsgType: "card", Data: cardData}
	contentBytes, _ := json.Marshal(contentMap)
	msg, _ := msgRepo.Create(t.Context(), convID, "agent", agentID, json.RawMessage(contentBytes))
	a, _ := repo.Create(t.Context(), model.Approval{
		MessageID: msg.ID, ConversationID: convID,
		InitiatorType: "agent", InitiatorID: agentID,
		CardType: model.CardTypeCommand, Actions: cardData.Actions,
		ExpiresAt:  time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "k",
	})

	hnd := NewApprovalHandler(repo, msgRepo, repository.NewConversationRepo(db),
		repository.NewAgentRepo(db), repository.NewParticipantRepo(db), newTestHub(db), nil)

	cases := []struct {
		name     string
		userID   string
		role     string
		wantCode int
	}{
		{"owner_user", userA, "user", http.StatusOK},
		{"other_user_idor", userB.ID, "user", http.StatusForbidden},
		{"owner_agent", agentID, "agent", http.StatusOK},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			w := httptest.NewRecorder()
			c, _ := gin.CreateTestContext(w)
			c.Request = httptest.NewRequest("GET", "/api/approvals/"+a.ID, nil)
			c.Params = gin.Params{{Key: "id", Value: a.ID}}
			c.Set("userID", tc.userID)
			c.Set("role", tc.role)

			hnd.Get(c)
			if w.Code != tc.wantCode {
				t.Fatalf("%s: expected %d, got %d: %s", tc.name, tc.wantCode, w.Code, w.Body.String())
			}
			switch tc.wantCode {
			case http.StatusOK:
				AssertOk(t, w, http.StatusOK)
			case http.StatusForbidden:
				AssertErr(t, w, http.StatusForbidden, "forbidden")
			}
		})
	}
}
