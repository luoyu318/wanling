package approval

// 审批链路 e2e 回归测试（真库 testcontainers）：
//   - TestCancelStateConsistency   缺陷 A：cancel 决策后 approvals 表与 content 双写状态一致 denied
//   - TestRejectStateConsistency   question 卡 reject 决策后表与 content 双写一致 denied
//   - TestAllowPatternNarrowing    缺陷 B：allow_once 不进白名单 / allow_always 进
//   - TestExpiredWritesContent     缺陷 C：expired 双写 content + 广播 MESSAGE_UPDATE

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// e2eFixture 建真库 + user/agent/conv + 各 repo，三条缺陷测试共用。
func e2eFixture(t *testing.T) (approvalRepo *repository.ApprovalRepo, msgRepo *repository.MessageRepo, userID, agentID, convID string) {
	t.Helper()
	db := repository.SetupTestDB(t)
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
	return repository.NewApprovalRepo(db), repository.NewMessageRepo(db), user.ID, agent.ID, conv.ID
}

// e2eCreateCard 直接连库建一条审批卡（message + approval），返回 approval ID 与 message ID。
func e2eCreateCard(t *testing.T, approvalRepo *repository.ApprovalRepo, msgRepo *repository.MessageRepo,
	cardData model.CardContent, agentID, convID, sessionKey string, allowPattern *string) (approvalID, msgID string) {
	t.Helper()
	contentMap := struct {
		MsgType string            `json:"msg_type"`
		Data    model.CardContent `json:"data"`
	}{MsgType: "card", Data: cardData}
	contentBytes, err := json.Marshal(contentMap)
	if err != nil {
		t.Fatalf("marshal content: %v", err)
	}
	msg, err := msgRepo.Create(t.Context(), convID, "agent", agentID, contentBytes)
	if err != nil {
		t.Fatalf("create msg: %v", err)
	}
	a, err := approvalRepo.Create(t.Context(), model.Approval{
		MessageID: msg.ID, ConversationID: convID,
		InitiatorType: "agent", InitiatorID: agentID,
		CardType: cardData.CardType, Actions: cardData.Actions,
		ExpiresAt:  cardData.ExpiresAt,
		SessionKey: sessionKey, AllowPattern: allowPattern,
		ConfirmID: cardData.ConfirmID,
	})
	if err != nil {
		t.Fatalf("create approval: %v", err)
	}
	return a.ID, msg.ID
}

// e2eContentState 读 message content 的 CardContent（校验双写用）。
func e2eContentState(t *testing.T, msgRepo *repository.MessageRepo, msgID string) model.CardContent {
	t.Helper()
	msg, err := msgRepo.Get(t.Context(), msgID)
	if err != nil {
		t.Fatalf("get msg: %v", err)
	}
	var wrapper struct {
		Data model.CardContent `json:"data"`
	}
	if err := json.Unmarshal(msg.Content, &wrapper); err != nil {
		t.Fatalf("unmarshal content: %v", err)
	}
	return wrapper.Data
}

// TestCancelStateConsistency slash_confirm decide cancel 后，
// approvals.state 与 messages.content.data.state 必须一致为 denied（缺陷 A）。
func TestCancelStateConsistency(t *testing.T) {
	approvalRepo, msgRepo, userID, agentID, convID := e2eFixture(t)
	confirmID := "cf-1"
	cardData := model.CardContent{
		CardType: model.CardTypeSlashConfirm, Title: "确认执行",
		Actions: []model.ApprovalAction{
			{ID: "once", Label: "执行一次"}, {ID: "always", Label: "不再询问"}, {ID: "cancel", Label: "取消"},
		},
		State:     model.ApprovalStatePending,
		ExpiresAt: time.Now().Add(5 * time.Minute).UTC(),
		ConfirmID: &confirmID,
	}
	aID, msgID := e2eCreateCard(t, approvalRepo, msgRepo, cardData, agentID, convID, "slash:1", nil)

	svc := NewService(approvalRepo, &mockHub{}, approvalRepo)
	if _, err := svc.Decide(t.Context(), aID, "cancel", "", nil, "user", userID); err != nil {
		t.Fatalf("Decide cancel: %v", err)
	}

	got, _ := approvalRepo.GetByID(t.Context(), aID)
	if got.State != model.ApprovalStateDenied {
		t.Fatalf("approvals.state=%s, want denied", got.State)
	}
	content := e2eContentState(t, msgRepo, msgID)
	if content.State != model.ApprovalStateDenied {
		t.Fatalf("content.state=%s, want denied", content.State)
	}
}

// TestRejectStateConsistency question 卡 decide reject 后，
// approvals.state 与 messages.content.data.state 必须一致为 denied
// （reject 与 deny/cancel 同为「未通过」，原实现缺映射导致落库 approved）。
func TestRejectStateConsistency(t *testing.T) {
	approvalRepo, msgRepo, userID, agentID, convID := e2eFixture(t)
	cardData := model.CardContent{
		CardType: model.CardTypeQuestion, Title: "部署到哪个环境？",
		Options: []model.ApprovalOption{
			{ID: "prod", Label: "生产"}, {ID: "dev", Label: "开发"},
		},
		Actions: []model.ApprovalAction{
			{ID: "answer", Label: "提交答案", Style: "primary"},
			{ID: "reject", Label: "拒绝", Style: "danger"},
		},
		State:     model.ApprovalStatePending,
		ExpiresAt: time.Now().Add(5 * time.Minute).UTC(),
	}
	aID, msgID := e2eCreateCard(t, approvalRepo, msgRepo, cardData, agentID, convID, "question:reject:1", nil)

	svc := NewService(approvalRepo, &mockHub{}, approvalRepo)
	if _, err := svc.Decide(t.Context(), aID, "reject", "", nil, "user", userID); err != nil {
		t.Fatalf("Decide reject: %v", err)
	}

	got, _ := approvalRepo.GetByID(t.Context(), aID)
	if got.State != model.ApprovalStateDenied {
		t.Fatalf("approvals.state=%s, want denied", got.State)
	}
	content := e2eContentState(t, msgRepo, msgID)
	if content.State != model.ApprovalStateDenied {
		t.Fatalf("content.state=%s, want denied", content.State)
	}
}

// TestAllowPatternNarrowing command 卡 allow_pattern="rm *"：
// allow_once 决策后不进白名单（且列被显式清空），allow_always 决策后命中（缺陷 B）。
func TestAllowPatternNarrowing(t *testing.T) {
	approvalRepo, msgRepo, userID, agentID, convID := e2eFixture(t)
	pattern := "rm *"
	cardData := model.CardContent{
		CardType: model.CardTypeCommand, Title: "命令审批", Preview: "rm -rf /tmp/x",
		Actions: []model.ApprovalAction{
			{ID: "allow_once"}, {ID: "allow_always"}, {ID: "deny"},
		},
		State:     model.ApprovalStatePending,
		ExpiresAt: time.Now().Add(5 * time.Minute).UTC(),
	}
	svc := NewService(approvalRepo, &mockHub{}, approvalRepo)

	// 卡1：allow_once 决策
	a1, _ := e2eCreateCard(t, approvalRepo, msgRepo, cardData, agentID, convID, "exec:1", &pattern)
	if _, err := svc.Decide(t.Context(), a1, "allow_once", "", nil, "user", userID); err != nil {
		t.Fatalf("Decide allow_once: %v", err)
	}
	// 白名单不应命中（旧实现 pattern 被保留 + 无 decided_action 条件会误命中）
	matched, err := approvalRepo.MatchAllowPattern(t.Context(), convID, agentID, "rm -rf /tmp/x")
	if err != nil {
		t.Fatalf("MatchAllowPattern: %v", err)
	}
	if matched {
		t.Fatal("allow_once 决策不应进白名单")
	}
	// allow_pattern 列应被显式清空
	got, _ := approvalRepo.GetByID(t.Context(), a1)
	if got.AllowPattern != nil {
		t.Fatalf("allow_once 后 allow_pattern 应清空, got %q", *got.AllowPattern)
	}

	// 卡2：allow_always 决策 → 命中
	a2, _ := e2eCreateCard(t, approvalRepo, msgRepo, cardData, agentID, convID, "exec:2", &pattern)
	if _, err := svc.Decide(t.Context(), a2, "allow_always", "", nil, "user", userID); err != nil {
		t.Fatalf("Decide allow_always: %v", err)
	}
	matched2, err := approvalRepo.MatchAllowPattern(t.Context(), convID, agentID, "rm -rf /tmp/x")
	if err != nil {
		t.Fatalf("MatchAllowPattern: %v", err)
	}
	if !matched2 {
		t.Fatal("allow_always 决策应进白名单")
	}
	// 不匹配的命令仍不命中
	matched3, _ := approvalRepo.MatchAllowPattern(t.Context(), convID, agentID, "ls /")
	if matched3 {
		t.Fatal("不匹配的命令不应命中白名单")
	}
}

// TestExpiredWritesContent 已超时 pending 卡跑一轮 cleanup 后：
// approvals.state=expired + content.state=expired 双写 + MESSAGE_UPDATE/APPROVAL_EXPIRED 广播（缺陷 C）。
func TestExpiredWritesContent(t *testing.T) {
	approvalRepo, msgRepo, _, agentID, convID := e2eFixture(t)
	cardData := model.CardContent{
		CardType: model.CardTypeCommand, Title: "命令审批", Preview: "rm -rf x",
		Actions:   []model.ApprovalAction{{ID: "allow_once"}, {ID: "deny"}},
		State:     model.ApprovalStatePending,
		ExpiresAt: time.Now().Add(-time.Minute).UTC(), // 已超时
	}
	aID, msgID := e2eCreateCard(t, approvalRepo, msgRepo, cardData, agentID, convID, "exec:expired:1", nil)

	// svc 同时满足 ExpiredFinder + Marker，真库跑一轮 cleanup 逻辑
	hubMock := &mockHub{}
	svc := NewService(approvalRepo, hubMock, approvalRepo)
	cleanupOnce(t.Context(), svc, svc, hubMock, time.Now())

	got, _ := approvalRepo.GetByID(t.Context(), aID)
	if got.State != model.ApprovalStateExpired {
		t.Fatalf("approvals.state=%s, want expired", got.State)
	}
	content := e2eContentState(t, msgRepo, msgID)
	if content.State != model.ApprovalStateExpired {
		t.Fatalf("content.state=%s, want expired", content.State)
	}
	if len(hubMock.messageUpdates) != 1 {
		t.Fatalf("expected 1 MESSAGE_UPDATE broadcast, got %d", len(hubMock.messageUpdates))
	}
	if len(hubMock.expired) != 1 {
		t.Fatalf("expected 1 APPROVAL_EXPIRED broadcast, got %d", len(hubMock.expired))
	}
}
