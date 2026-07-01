package approval

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// mockHub 实现 Hubber 接口，记录所有 dispatch 调用供断言。
type mockHub struct {
	messageUpdates []string // 记录每次 BroadcastMessageUpdate 的 messageID
	decided        []map[string]any
	expired        []map[string]any
}

func (m *mockHub) BroadcastMessageUpdate(convID, messageID string, content json.RawMessage) {
	m.messageUpdates = append(m.messageUpdates, messageID)
}
func (m *mockHub) SendApprovalDecided(agentID string, payload map[string]any) {
	m.decided = append(m.decided, payload)
}
func (m *mockHub) SendApprovalExpired(agentID string, payload map[string]any) {
	m.expired = append(m.expired, payload)
}

// shortName 测试包内独立 helper（repository 包的 uniqueShortName 不导出）。
// 把测试函数名压短避免超出 users.username varchar(64) 限制。
func shortName(t *testing.T, prefix string) string {
	t.Helper()
	name := prefix + t.Name()
	// 只保留字母数字，压长度
	out := make([]byte, 0, len(name))
	for _, c := range name {
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' {
			out = append(out, byte(c))
		}
	}
	if len(out) > 32 {
		out = out[:32]
	}
	return string(out)
}

func TestServiceDecideHappyPath(t *testing.T) {
	db := repository.SetupTestDB(t)
	approvalRepo := repository.NewApprovalRepo(db)
	userRepo := repository.NewUserRepo(db)
	agentRepo := repository.NewAgentRepo(db)
	convRepo := repository.NewConversationRepo(db)
	msgRepo := repository.NewMessageRepo(db)

	user, _ := userRepo.Create(shortName(t, "u"), "$2a$10$hash")
	agent, _ := agentRepo.Create(user.ID, shortName(t, "a"), "secret")
	conv, _ := convRepo.FindOrCreateDM("dm_user_agent", repository.DMMembers{
		Initiator: repository.ParticipantInput{MemberID: user.ID, MemberType: "user", Role: "owner"},
		Other:     repository.ParticipantInput{MemberID: agent.ID, MemberType: "agent", Role: "member"},
	})

	cardData := model.CardContent{
		CardType: model.CardTypeCommand, Title: "命令审批", Preview: "rm -rf x",
		Actions: []model.ApprovalAction{
			{ID: "allow_once", Label: "允许"},
			{ID: "deny", Label: "拒绝"},
		},
		State:     model.ApprovalStatePending,
		ExpiresAt: time.Now().Add(5 * time.Minute).UTC(),
	}
	wrapper := struct {
		MsgType string            `json:"msg_type"`
		Data    model.CardContent `json:"data"`
	}{MsgType: "card", Data: cardData}
	contentBytes, _ := json.Marshal(wrapper)
	msg, err := msgRepo.Create(conv.ID, "agent", agent.ID, contentBytes)
	if err != nil {
		t.Fatalf("create msg: %v", err)
	}

	a, err := approvalRepo.Create(model.Approval{
		MessageID: msg.ID, ConversationID: conv.ID, AgentID: agent.ID, UserID: user.ID,
		CardType:  model.CardTypeCommand, Actions: cardData.Actions,
		ExpiresAt: time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "exec:1",
	})
	if err != nil {
		t.Fatalf("create approval: %v", err)
	}

	hub := &mockHub{}
	svc := NewService(approvalRepo, hub, approvalRepo)

	newContent, err := svc.Decide(a.ID, "allow_once", user.ID, "")
	if err != nil {
		t.Fatalf("Decide: %v", err)
	}

	var got struct {
		Data model.CardContent `json:"data"`
	}
	if err := json.Unmarshal(newContent, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.Data.State != model.ApprovalStateApproved {
		t.Fatalf("expected approved, got %s", got.Data.State)
	}
	if got.Data.DecidedAction == nil || *got.Data.DecidedAction != "allow_once" {
		t.Fatalf("decided_action wrong: %v", got.Data.DecidedAction)
	}
	if len(hub.messageUpdates) != 1 || len(hub.decided) != 1 {
		t.Fatalf("broadcast wrong: updates=%d decided=%d", len(hub.messageUpdates), len(hub.decided))
	}
	if hub.decided[0]["decision"] != "allow_once" {
		t.Fatalf("decision wrong: %v", hub.decided[0]["decision"])
	}

	// 校验 DB 也已落盘
	dbApproval, _ := approvalRepo.GetByID(a.ID)
	if dbApproval.State != model.ApprovalStateApproved {
		t.Fatalf("DB state wrong: %s", dbApproval.State)
	}
}

func TestServiceDecideInvalidActionFails(t *testing.T) {
	db := repository.SetupTestDB(t)
	approvalRepo := repository.NewApprovalRepo(db)
	userRepo := repository.NewUserRepo(db)
	agentRepo := repository.NewAgentRepo(db)
	convRepo := repository.NewConversationRepo(db)
	msgRepo := repository.NewMessageRepo(db)

	user, _ := userRepo.Create(shortName(t, "u"), "$2a$10$hash")
	agent, _ := agentRepo.Create(user.ID, shortName(t, "a"), "secret")
	conv, _ := convRepo.FindOrCreateDM("dm_user_agent", repository.DMMembers{
		Initiator: repository.ParticipantInput{MemberID: user.ID, MemberType: "user", Role: "owner"},
		Other:     repository.ParticipantInput{MemberID: agent.ID, MemberType: "agent", Role: "member"},
	})

	cardData := model.CardContent{
		CardType: model.CardTypeCommand, Title: "t",
		Actions:   []model.ApprovalAction{{ID: "allow_once"}, {ID: "deny"}},
		State:     model.ApprovalStatePending,
		ExpiresAt: time.Now().Add(5 * time.Minute).UTC(),
	}
	wrapper := struct {
		MsgType string            `json:"msg_type"`
		Data    model.CardContent `json:"data"`
	}{MsgType: "card", Data: cardData}
	contentBytes, _ := json.Marshal(wrapper)
	msg, _ := msgRepo.Create(conv.ID, "agent", agent.ID, contentBytes)

	a, _ := approvalRepo.Create(model.Approval{
		MessageID: msg.ID, ConversationID: conv.ID, AgentID: agent.ID, UserID: user.ID,
		CardType:  model.CardTypeCommand, Actions: cardData.Actions,
		ExpiresAt: time.Now().Add(5 * time.Minute).UTC(),
		SessionKey: "exec:1",
	})

	hub := &mockHub{}
	svc := NewService(approvalRepo, hub, approvalRepo)

	_, err := svc.Decide(a.ID, "invalid_action", user.ID, "")
	if err != ErrInvalidAction {
		t.Fatalf("expected ErrInvalidAction, got %v", err)
	}
	// 校验失败时未触发 dispatch
	if len(hub.messageUpdates) != 0 || len(hub.decided) != 0 {
		t.Fatalf("should not dispatch on invalid: updates=%d decided=%d", len(hub.messageUpdates), len(hub.decided))
	}
}
