package repository

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/wanling/server/internal/model"
)

// approvalTestFixture 创建一条 user + agent + conversation + message 准备审批用。
// 复用 SetupTestDB 跑过的 migration 001-008。
func approvalTestFixture(t *testing.T) (*ApprovalRepo, *MessageRepo, string, string, string, string) {
	t.Helper()
	db := SetupTestDB(t)

	userRepo := NewUserRepo(db)
	agentRepo := NewAgentRepo(db)
	convRepo := NewConversationRepo(db)
	msgRepo := NewMessageRepo(db)
	approvalRepo := NewApprovalRepo(db)

	user, err := userRepo.Create(uniqueShortName(t, "u_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	agent, err := agentRepo.Create(user.ID, "Agent", "secret")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}
	conv, err := convRepo.FindOrCreate(user.ID, agent.ID)
	if err != nil {
		t.Fatalf("create conv: %v", err)
	}
	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`)
	msg, err := msgRepo.Create(conv.ID, "agent", agent.ID, content)
	if err != nil {
		t.Fatalf("create msg: %v", err)
	}
	return approvalRepo, msgRepo, user.ID, agent.ID, conv.ID, msg.ID
}

func TestApprovalCreateAndGets(t *testing.T) {
	repo, _, userID, agentID, convID, msgID := approvalTestFixture(t)
	actions := []model.ApprovalAction{
		{ID: "allow_once", Label: "允许", Icon: "check", Style: "primary"},
		{ID: "deny", Label: "拒绝", Icon: "x", Style: "danger"},
	}
	expires := time.Now().Add(5 * time.Minute).UTC()

	created, err := repo.Create(model.Approval{
		MessageID: msgID, ConversationID: convID, AgentID: agentID, UserID: userID,
		CardType: model.CardTypeTool, Actions: actions,
		ExpiresAt: expires, SessionKey: "exec:test:1",
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if created.ID == "" || created.State != model.ApprovalStatePending {
		t.Fatalf("unexpected initial state: %+v", created)
	}

	got, err := repo.GetByID(created.ID)
	if err != nil || got == nil {
		t.Fatalf("GetByID: %v %v", got, err)
	}
	if got.CardType != model.CardTypeTool || len(got.Actions) != 2 {
		t.Fatalf("unexpected: %+v", got)
	}

	byMsg, err := repo.GetByMessageID(msgID)
	if err != nil || byMsg == nil || byMsg.ID != created.ID {
		t.Fatalf("GetByMessageID: %v %v", byMsg, err)
	}
}

func TestApprovalFindExpired(t *testing.T) {
	repo, _, userID, agentID, convID, msgID := approvalTestFixture(t)
	// 创建一条已过期的 pending
	_, err := repo.Create(model.Approval{
		MessageID: msgID, ConversationID: convID, AgentID: agentID, UserID: userID,
		CardType:   model.CardTypeCommand,
		Actions:    []model.ApprovalAction{{ID: "deny", Label: "拒绝", Icon: "x", Style: "danger"}},
		ExpiresAt:  time.Now().Add(-1 * time.Minute).UTC(), // 已过期
		SessionKey: "exec:expired:1",
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	pending, err := repo.FindExpired(time.Now().UTC())
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
	created, err := repo.Create(model.Approval{
		MessageID: msgID, ConversationID: convID, AgentID: agentID, UserID: userID,
		CardType: model.CardTypeCommand,
		Actions: []model.ApprovalAction{
			{ID: "allow_once", Label: "允许", Icon: "check", Style: "primary"},
			{ID: "allow_always", Label: "始终", Icon: "shield", Style: "info"},
			{ID: "deny", Label: "拒绝", Icon: "x", Style: "danger"},
		},
		ExpiresAt: time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "exec:cmd:1",
		AllowPattern: &pattern,
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	actionID := "allow_always"
	if err := repo.MarkDecided(created.ID, actionID, userID, "", &pattern); err != nil {
		t.Fatalf("MarkDecided: %v", err)
	}
	got, _ := repo.GetByID(created.ID)
	if got.State != model.ApprovalStateApproved || *got.DecidedAction != "allow_always" {
		t.Fatalf("state/action wrong: %+v", got)
	}
	if got.AllowPattern == nil || *got.AllowPattern != pattern {
		t.Fatalf("allow_pattern not saved: %v", got.AllowPattern)
	}

	// 后续同类命令应被 MatchAllowPattern 命中
	matched, err := repo.MatchAllowPattern(convID, agentID, "rm -rf /tmp/cache")
	if err != nil {
		t.Fatalf("MatchAllowPattern: %v", err)
	}
	if !matched {
		t.Fatal("expected pattern match")
	}

	// 不匹配的命令应返回 false
	matched2, _ := repo.MatchAllowPattern(convID, agentID, "ls /")
	if matched2 {
		t.Fatal("unexpected pattern match for ls")
	}
}

func TestApprovalMarkDecidedDenyWithReason(t *testing.T) {
	repo, _, userID, agentID, convID, msgID := approvalTestFixture(t)
	created, err := repo.Create(model.Approval{
		MessageID: msgID, ConversationID: convID, AgentID: agentID, UserID: userID,
		CardType: model.CardTypeTool,
		Actions:  []model.ApprovalAction{{ID: "deny", Label: "拒绝", Icon: "x", Style: "danger"}},
		ExpiresAt: time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "tool:1",
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	reason := "操作不可逆"
	if err := repo.MarkDecided(created.ID, "deny", userID, reason, nil); err != nil {
		t.Fatalf("MarkDecided: %v", err)
	}
	got, _ := repo.GetByID(created.ID)
	if got.State != model.ApprovalStateDenied {
		t.Fatalf("state wrong: %+v", got)
	}
	if got.DecidedReason == nil || *got.DecidedReason != reason {
		t.Fatalf("reason not saved: %v", got.DecidedReason)
	}
}

func TestApprovalMarkDecidedNotPendingFails(t *testing.T) {
	repo, _, userID, agentID, convID, msgID := approvalTestFixture(t)
	created, _ := repo.Create(model.Approval{
		MessageID: msgID, ConversationID: convID, AgentID: agentID, UserID: userID,
		CardType:   model.CardTypeTool,
		Actions:    []model.ApprovalAction{{ID: "deny", Label: "拒绝", Icon: "x", Style: "danger"}},
		ExpiresAt:  time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "tool:1",
	})
	// 先 decide 一次
	if err := repo.MarkDecided(created.ID, "deny", userID, "", nil); err != nil {
		t.Fatalf("first MarkDecided: %v", err)
	}
	// 再次 decide 应失败（已是非 pending）
	err := repo.MarkDecided(created.ID, "allow_once", userID, "", nil)
	if err == nil {
		t.Fatal("expected error on second MarkDecided")
	}
}

func TestApprovalMarkExpired(t *testing.T) {
	repo, _, userID, agentID, convID, msgID := approvalTestFixture(t)
	created, _ := repo.Create(model.Approval{
		MessageID: msgID, ConversationID: convID, AgentID: agentID, UserID: userID,
		CardType:   model.CardTypeCommand,
		Actions:    []model.ApprovalAction{{ID: "deny", Label: "拒绝", Icon: "x", Style: "danger"}},
		ExpiresAt:  time.Now().Add(-time.Minute).UTC(),
		SessionKey: "exec:1",
	})
	if err := repo.MarkExpired(created.ID); err != nil {
		t.Fatalf("MarkExpired: %v", err)
	}
	got, _ := repo.GetByID(created.ID)
	if got.State != model.ApprovalStateExpired {
		t.Fatalf("state wrong: %+v", got)
	}
}
