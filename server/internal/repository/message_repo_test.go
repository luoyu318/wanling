package repository

import (
	"encoding/json"
	"testing"
)

// TestMessageRepo_SoftDelete_LastNonDeleted_ListByConversation 过软删除全链路:
//  1. Create 两条消息
//  2. ListByConversation 能看到两条
//  3. SoftDelete 第一条
//  4. ListByConversation 只剩一条
//  5. LastNonDeleted 返回未删的那条
//  6. SoftDelete 剩余那条后 LastNonDeleted 返回 nil
func TestMessageRepo_SoftDelete_LastNonDeleted_ListByConversation(t *testing.T) {
	db := SetupTestDB(t)
	convRepo := NewConversationRepo(db)
	msgRepo := NewMessageRepo(db)
	userRepo := NewUserRepo(db)
	agentRepo := NewAgentRepo(db)

	user, err := userRepo.Create(uniqueShortName(t, "u_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	agent, err := agentRepo.Create(user.ID, "Agent", "secret")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}
	conv, err := convRepo.FindOrCreate(user.ID, agent.ID)
	if err != nil {
		t.Fatalf("FindOrCreate 失败: %v", err)
	}

	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`)
	m1, err := msgRepo.Create(conv.ID, "user", user.ID, content)
	if err != nil {
		t.Fatalf("Create m1 失败: %v", err)
	}
	m2, err := msgRepo.Create(conv.ID, "agent", agent.ID, content)
	if err != nil {
		t.Fatalf("Create m2 失败: %v", err)
	}

	// 两条都能查到
	list, err := msgRepo.ListByConversation(conv.ID, 50, 0)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("应有 2 条消息,实际 %d", len(list))
	}

	// 软删 m1
	if err := msgRepo.SoftDelete(m1.ID); err != nil {
		t.Fatalf("SoftDelete m1 失败: %v", err)
	}
	list, _ = msgRepo.ListByConversation(conv.ID, 50, 0)
	if len(list) != 1 {
		t.Fatalf("软删后应剩 1 条,实际 %d", len(list))
	}
	if list[0].ID != m2.ID {
		t.Errorf("剩余应为 m2,实际 %s", list[0].ID)
	}

	// LastNonDeleted 返回 m2(最新未删)
	last, err := msgRepo.LastNonDeleted(conv.ID)
	if err != nil {
		t.Fatalf("LastNonDeleted 失败: %v", err)
	}
	if last == nil || last.ID != m2.ID {
		t.Errorf("LastNonDeleted 应为 m2,实际 %v", last)
	}

	// Get 能查到已删的吗?设计上 Get 不过滤 deleted_at(权限校验需要知道消息存在与否),
	// 但 Get 返回的消息可用于判断已删状态。这里只断言能查到(id 存在)。
	got, err := msgRepo.Get(m1.ID)
	if err != nil {
		t.Fatalf("Get m1 失败: %v", err)
	}
	if got == nil {
		t.Fatal("Get 应返回消息(即使已软删),实际 nil")
	}

	// 软删 m2 后 LastNonDeleted 返回 nil
	if err := msgRepo.SoftDelete(m2.ID); err != nil {
		t.Fatalf("SoftDelete m2 失败: %v", err)
	}
	last, err = msgRepo.LastNonDeleted(conv.ID)
	if err != nil {
		t.Fatalf("LastNonDeleted 全删后失败: %v", err)
	}
	if last != nil {
		t.Errorf("全删后 LastNonDeleted 应为 nil,实际 %v", last)
	}
}

// TestMessageRepo_SoftDeleteByIDs_GetByIDs 验证批量软删 + 批量查询。
func TestMessageRepo_SoftDeleteByIDs_GetByIDs(t *testing.T) {
	db := SetupTestDB(t)
	convRepo := NewConversationRepo(db)
	msgRepo := NewMessageRepo(db)
	userRepo := NewUserRepo(db)
	agentRepo := NewAgentRepo(db)

	user, _ := userRepo.Create(uniqueShortName(t, "u_"), "$2a$10$hash")
	agent, _ := agentRepo.Create(user.ID, "Agent", "secret")
	conv, _ := convRepo.FindOrCreate(user.ID, agent.ID)

	content := json.RawMessage(`{"msg_type":"text","data":{"text":"x"}}`)
	m1, _ := msgRepo.Create(conv.ID, "user", user.ID, content)
	m2, _ := msgRepo.Create(conv.ID, "user", user.ID, content)
	m3, _ := msgRepo.Create(conv.ID, "user", user.ID, content)

	// GetByIDs 返回 3 条
	got, err := msgRepo.GetByIDs([]string{m1.ID, m2.ID, m3.ID})
	if err != nil {
		t.Fatalf("GetByIDs 失败: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("GetByIDs 应返回 3 条,实际 %d", len(got))
	}

	// 批量软删 m1 + m2,返回受影响 2 行
	n, err := msgRepo.SoftDeleteByIDs([]string{m1.ID, m2.ID})
	if err != nil {
		t.Fatalf("SoftDeleteByIDs 失败: %v", err)
	}
	if n != 2 {
		t.Errorf("受影响行数应为 2,实际 %d", n)
	}

	// ListByConversation 只剩 m3
	list, _ := msgRepo.ListByConversation(conv.ID, 50, 0)
	if len(list) != 1 || list[0].ID != m3.ID {
		t.Errorf("批量软删后应剩 m3,实际 %v", list)
	}
}
