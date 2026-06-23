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
