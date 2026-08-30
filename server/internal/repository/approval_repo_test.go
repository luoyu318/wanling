package repository

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/wanling/server/internal/model"
)

// approvalTestFixture 创建一条 user + agent + conversation + message 准备审批用。
// participants 模型重构后,conv 用 FindOrCreateDM 创建(带 2 个 participants)。
func approvalTestFixture(t *testing.T) (*ApprovalRepo, *MessageRepo, string, string, string, string) {
	t.Helper()
	db := SetupTestDB(t)

	userRepo := NewUserRepo(db)
	agentRepo := NewAgentRepo(db)
	convRepo := NewConversationRepo(db)
	msgRepo := NewMessageRepo(db)
	approvalRepo := NewApprovalRepo(db)

	user, err := userRepo.Create(t.Context(), uniqueShortName(t, "u_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	agent, err := agentRepo.Create(t.Context(), user.ID, "Agent", "secret", "")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}
	// participants 模型:用 FindOrCreateDM 创建 dm_user_agent 会话
	conv, err := convRepo.FindOrCreateDM(t.Context(), "dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: user.ID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: agent.ID, MemberType: "agent"},
	})
	if err != nil {
		t.Fatalf("create conv: %v", err)
	}
	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`)
	msg, err := msgRepo.Create(t.Context(), conv.ID, "agent", agent.ID, content)
	if err != nil {
		t.Fatalf("create msg: %v", err)
	}
	return approvalRepo, msgRepo, user.ID, agent.ID, conv.ID, msg.ID
}

func TestApprovalCreateAndGets(t *testing.T) {
	repo, _, _, agentID, convID, msgID := approvalTestFixture(t)
	actions := []model.ApprovalAction{
		{ID: "allow_once", Label: "允许", Icon: "check", Style: "primary"},
		{ID: "deny", Label: "拒绝", Icon: "x", Style: "danger"},
	}
	expires := time.Now().Add(5 * time.Minute).UTC()

	created, err := repo.Create(t.Context(), model.Approval{
		ID:        uuid.New().String(),
		MessageID: msgID, ConversationID: convID,
		InitiatorType: "agent", InitiatorID: agentID,
		CardType: model.CardTypeTool, Actions: actions,
		ExpiresAt: expires, SessionKey: "exec:test:1",
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if created.ID == "" || created.State != model.ApprovalStatePending {
		t.Fatalf("unexpected initial state: %+v", created)
	}

	got, err := repo.GetByID(t.Context(), created.ID)
	if err != nil || got == nil {
		t.Fatalf("GetByID: %v %v", got, err)
	}
	if got.CardType != model.CardTypeTool || len(got.Actions) != 2 {
		t.Fatalf("unexpected: %+v", got)
	}

	byMsg, err := repo.GetByMessageID(t.Context(), msgID)
	if err != nil || byMsg == nil || byMsg.ID != created.ID {
		t.Fatalf("GetByMessageID: %v %v", byMsg, err)
	}
}

func TestApprovalFindExpired(t *testing.T) {
	repo, _, _, agentID, convID, msgID := approvalTestFixture(t)
	// 创建一条已过期的 pending
	_, err := repo.Create(t.Context(), model.Approval{
		ID:        uuid.New().String(),
		MessageID: msgID, ConversationID: convID,
		InitiatorType: "agent", InitiatorID: agentID,
		CardType:   model.CardTypeCommand,
		Actions:    []model.ApprovalAction{{ID: "deny", Label: "拒绝", Icon: "x", Style: "danger"}},
		ExpiresAt:  time.Now().Add(-1 * time.Minute).UTC(), // 已过期
		SessionKey: "exec:expired:1",
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	pending, err := repo.FindExpired(t.Context(), time.Now().UTC())
	if err != nil {
		t.Fatalf("FindExpired: %v", err)
	}
	if len(pending) != 1 {
		t.Fatalf("expected 1 expired, got %d", len(pending))
	}
}

func TestApprovalMarkDecidedAllowAlways(t *testing.T) {
	repo, _, userID, agentID, convID, msgID := approvalTestFixture(t)
	pattern := "rm -rf *"
	created, err := repo.Create(t.Context(), model.Approval{
		ID:        uuid.New().String(),
		MessageID: msgID, ConversationID: convID,
		InitiatorType: "agent", InitiatorID: agentID,
		CardType: model.CardTypeCommand,
		Actions: []model.ApprovalAction{
			{ID: "allow_once", Label: "允许", Icon: "check", Style: "primary"},
			{ID: "allow_always", Label: "始终", Icon: "shield", Style: "info"},
			{ID: "deny", Label: "拒绝", Icon: "x", Style: "danger"},
		},
		ExpiresAt:    time.Now().Add(5 * time.Minute).UTC(),
		SessionKey:   "exec:cmd:1",
		AllowPattern: &pattern,
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	actionID := "allow_always"
	if err := repo.MarkDecided(t.Context(), created.ID, actionID, "user", userID, "", &pattern, nil); err != nil {
		t.Fatalf("MarkDecided: %v", err)
	}
	got, _ := repo.GetByID(t.Context(), created.ID)
	if got.State != model.ApprovalStateApproved || *got.DecidedAction != "allow_always" {
		t.Fatalf("state/action wrong: %+v", got)
	}
	if got.AllowPattern == nil || *got.AllowPattern != pattern {
		t.Fatalf("allow_pattern not saved: %v", got.AllowPattern)
	}

	// 后续同类命令应被 MatchAllowPattern 命中
	matched, err := repo.MatchAllowPattern(t.Context(), convID, agentID, "rm -rf /tmp/cache")
	if err != nil {
		t.Fatalf("MatchAllowPattern: %v", err)
	}
	if !matched {
		t.Fatal("expected pattern match")
	}

	// 不匹配的命令应返回 false
	matched2, _ := repo.MatchAllowPattern(t.Context(), convID, agentID, "ls /")
	if matched2 {
		t.Fatal("unexpected pattern match for ls")
	}
}

func TestApprovalMarkDecidedDenyWithReason(t *testing.T) {
	repo, _, userID, agentID, convID, msgID := approvalTestFixture(t)
	created, err := repo.Create(t.Context(), model.Approval{
		ID:        uuid.New().String(),
		MessageID: msgID, ConversationID: convID,
		InitiatorType: "agent", InitiatorID: agentID,
		CardType:   model.CardTypeTool,
		Actions:    []model.ApprovalAction{{ID: "deny", Label: "拒绝", Icon: "x", Style: "danger"}},
		ExpiresAt:  time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "tool:1",
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	reason := "操作不可逆"
	if err := repo.MarkDecided(t.Context(), created.ID, "deny", "user", userID, reason, nil, nil); err != nil {
		t.Fatalf("MarkDecided: %v", err)
	}
	got, _ := repo.GetByID(t.Context(), created.ID)
	if got.State != model.ApprovalStateDenied {
		t.Fatalf("state wrong: %+v", got)
	}
	if got.DecidedReason == nil || *got.DecidedReason != reason {
		t.Fatalf("reason not saved: %v", got.DecidedReason)
	}
}

func TestApprovalMarkDecidedNotPendingFails(t *testing.T) {
	repo, _, userID, agentID, convID, msgID := approvalTestFixture(t)
	created, _ := repo.Create(t.Context(), model.Approval{
		ID:        uuid.New().String(),
		MessageID: msgID, ConversationID: convID,
		InitiatorType: "agent", InitiatorID: agentID,
		CardType:   model.CardTypeTool,
		Actions:    []model.ApprovalAction{{ID: "deny", Label: "拒绝", Icon: "x", Style: "danger"}},
		ExpiresAt:  time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "tool:1",
	})
	// 先 decide 一次
	if err := repo.MarkDecided(t.Context(), created.ID, "deny", "user", userID, "", nil, nil); err != nil {
		t.Fatalf("first MarkDecided: %v", err)
	}
	// 再次 decide 应失败（已是非 pending）
	err := repo.MarkDecided(t.Context(), created.ID, "allow_once", "user", userID, "", nil, nil)
	if err == nil {
		t.Fatal("expected error on second MarkDecided")
	}
}

// question 决策的 answers 落 decided_answers 后，GetByID 必须能读回
// （agent 重连 resync 依赖 GET /api/approvals/:id 返回 decided_answers 恢复决议）。
func TestApprovalDecidedAnswersRoundTrip(t *testing.T) {
	repo, _, userID, agentID, convID, msgID := approvalTestFixture(t)
	created, err := repo.Create(t.Context(), model.Approval{
		ID:        uuid.New().String(),
		MessageID: msgID, ConversationID: convID,
		InitiatorType: "agent", InitiatorID: agentID,
		CardType: model.CardTypeQuestion,
		Actions: []model.ApprovalAction{
			{ID: "answer", Label: "提交答案", Style: "primary"},
			{ID: "reject", Label: "拒绝", Style: "danger"},
		},
		ExpiresAt:  time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "question:1",
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	answers := []string{"opt_a", "opt_c"}
	if err := repo.MarkDecided(t.Context(), created.ID, "answer", "user", userID, "", nil, answers); err != nil {
		t.Fatalf("MarkDecided: %v", err)
	}

	got, err := repo.GetByID(t.Context(), created.ID)
	if err != nil || got == nil {
		t.Fatalf("GetByID: %v %v", got, err)
	}
	if len(got.DecidedAnswers) != 2 || got.DecidedAnswers[0] != "opt_a" || got.DecidedAnswers[1] != "opt_c" {
		t.Fatalf("decided_answers not read back: %v", got.DecidedAnswers)
	}

	// 非 question 决策（无 answers）读回应为 nil，不报错
	created2, _ := repo.Create(t.Context(), model.Approval{
		ID:        uuid.New().String(),
		MessageID: msgID, ConversationID: convID,
		InitiatorType: "agent", InitiatorID: agentID,
		CardType: model.CardTypeTool,
		Actions: []model.ApprovalAction{
			{ID: "allow_once", Label: "允许", Icon: "check", Style: "primary"},
			{ID: "deny", Label: "拒绝", Icon: "x", Style: "danger"},
		},
		ExpiresAt:  time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "tool:2",
	})
	if err := repo.MarkDecided(t.Context(), created2.ID, "allow_once", "user", userID, "", nil, nil); err != nil {
		t.Fatalf("MarkDecided tool: %v", err)
	}
	got2, err := repo.GetByID(t.Context(), created2.ID)
	if err != nil || got2 == nil {
		t.Fatalf("GetByID tool: %v %v", got2, err)
	}
	if got2.DecidedAnswers != nil {
		t.Fatalf("expected nil decided_answers for tool approval, got %v", got2.DecidedAnswers)
	}
}

func TestApprovalMarkExpired(t *testing.T) {
	repo, _, _, agentID, convID, msgID := approvalTestFixture(t)
	created, _ := repo.Create(t.Context(), model.Approval{
		ID:        uuid.New().String(),
		MessageID: msgID, ConversationID: convID,
		InitiatorType: "agent", InitiatorID: agentID,
		CardType:   model.CardTypeCommand,
		Actions:    []model.ApprovalAction{{ID: "deny", Label: "拒绝", Icon: "x", Style: "danger"}},
		ExpiresAt:  time.Now().Add(-time.Minute).UTC(),
		SessionKey: "exec:1",
	})
	if err := repo.MarkExpired(t.Context(), created.ID); err != nil {
		t.Fatalf("MarkExpired: %v", err)
	}
	got, _ := repo.GetByID(t.Context(), created.ID)
	if got.State != model.ApprovalStateExpired {
		t.Fatalf("state wrong: %+v", got)
	}
}

func TestApprovalGetForDecision(t *testing.T) {
	repo, msgRepo, _, agentID, convID, msgID := approvalTestFixture(t)
	cardData := model.CardContent{
		ApprovalID: "pending-id", CardType: model.CardTypeCommand, Title: "命令审批", Preview: "rm -rf x",
		Actions: []model.ApprovalAction{{ID: "allow_once", Label: "允许"}, {ID: "deny", Label: "拒绝"}},
		State:   model.ApprovalStatePending, ExpiresAt: time.Now().Add(5 * time.Minute).UTC(),
	}
	contentMap := struct {
		MsgType string            `json:"msg_type"`
		Data    model.CardContent `json:"data"`
	}{MsgType: "card", Data: cardData}
	contentBytes, _ := json.Marshal(contentMap)
	// MessageRepo 无 UpdateContent，直接 SQL UPDATE
	if _, err := repo.db.Exec("UPDATE messages SET content = $1 WHERE id = $2", contentBytes, msgID); err != nil {
		t.Fatalf("update msg content: %v", err)
	}
	_ = msgRepo // 避免未用警告

	pattern := "rm -rf *"
	a, err := repo.Create(t.Context(), model.Approval{
		ID:        uuid.New().String(),
		MessageID: msgID, ConversationID: convID,
		InitiatorType: "agent", InitiatorID: agentID,
		CardType: model.CardTypeCommand, Actions: cardData.Actions,
		ExpiresAt:  time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "exec:1", AllowPattern: &pattern,
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	ctx, err := repo.GetForDecision(t.Context(), a.ID)
	if err != nil || ctx == nil {
		t.Fatalf("GetForDecision: %v %v", ctx, err)
	}
	if ctx.CardContent.Title != "命令审批" || len(ctx.CardContent.Actions) != 2 {
		t.Fatalf("CardContent wrong: %+v", ctx.CardContent)
	}
	if ctx.AllowPattern == nil || *ctx.AllowPattern != pattern {
		t.Fatalf("AllowPattern wrong: %v", ctx.AllowPattern)
	}
}

func TestApprovalUpdateMessageContent(t *testing.T) {
	repo, _, _, agentID, convID, msgID := approvalTestFixture(t)
	_, err := repo.Create(t.Context(), model.Approval{
		ID:        uuid.New().String(),
		MessageID: msgID, ConversationID: convID,
		InitiatorType: "agent", InitiatorID: agentID,
		CardType:   model.CardTypeCommand,
		Actions:    []model.ApprovalAction{{ID: "deny"}},
		ExpiresAt:  time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "k",
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	newContent := []byte(`{"msg_type":"card","data":{"state":"approved"}}`)
	if err := repo.UpdateMessageContent(t.Context(), msgID, newContent); err != nil {
		t.Fatalf("UpdateMessageContent: %v", err)
	}
	var raw []byte
	err = repo.db.QueryRow(`SELECT content FROM messages WHERE id = $1`, msgID).Scan(&raw)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}
	// JSONB 读出来 key 顺序会变 + 加空格，比较解析后语义而非字节
	var got, want struct {
		MsgType string `json:"msg_type"`
		Data    struct {
			State string `json:"state"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("unmarshal got: %v", err)
	}
	if err := json.Unmarshal(newContent, &want); err != nil {
		t.Fatalf("unmarshal want: %v", err)
	}
	if got != want {
		t.Fatalf("content mismatch: %+v vs %+v", got, want)
	}
}
