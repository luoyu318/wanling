package repository

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/lib/pq"
	"github.com/wanling/server/internal/model"
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

// TestMessageRepo_FirstUnread 校验 FirstUnread：
//   - 有未读 → 返回最早的未读消息；
//   - 全部已读 → 返回 (nil, nil)；
//   - 未读消息软删后自动跳过。
func TestMessageRepo_FirstUnread(t *testing.T) {
	db := SetupTestDB(t)
	userRepo := NewUserRepo(db)
	agentRepo := NewAgentRepo(db)
	convRepo := NewConversationRepo(db)
	msgRepo := NewMessageRepo(db)

	user, err := userRepo.Create(uniqueShortName(t, "fu_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	agent, err := agentRepo.Create(user.ID, "FU-Agent", "secret")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}
	conv, err := convRepo.FindOrCreate(user.ID, agent.ID)
	if err != nil {
		t.Fatalf("FindOrCreate 失败: %v", err)
	}

	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`)

	// 没消息时返回 nil
	got, err := msgRepo.FirstUnread(conv.ID)
	if err != nil {
		t.Fatalf("FirstUnread 空会话失败: %v", err)
	}
	if got != nil {
		t.Errorf("空会话 FirstUnread 应为 nil，实际 %+v", got)
	}

	// 造 3 条消息：m1（user 发，已读）、m2（agent 发，未读）、m3（agent 发，未读）
	// is_read 列默认值 false，user 发的消息 is_read 不影响未读判定（仍按 is_read=false）
	// 这里 MarkRead 后所有消息都置 true，再单独 Insert 一条 is_read=false 的来制造"第一条未读"
	m1, err := msgRepo.Create(conv.ID, "user", user.ID, content)
	if err != nil {
		t.Fatalf("Create m1 失败: %v", err)
	}
	m2, err := msgRepo.Create(conv.ID, "agent", agent.ID, content)
	if err != nil {
		t.Fatalf("Create m2 失败: %v", err)
	}
	m3, err := msgRepo.Create(conv.ID, "agent", agent.ID, content)
	if err != nil {
		t.Fatalf("Create m3 失败: %v", err)
	}
	_ = m1
	_ = m3

	// 标记会话已读 → 全部消息 is_read=true
	if err := convRepo.MarkRead(conv.ID, user.ID); err != nil {
		t.Fatalf("MarkRead 失败: %v", err)
	}

	// 再插一条 is_read=false 的（DirectSQL 制造"第一条未读"）
	m4, err := msgRepo.Create(conv.ID, "agent", agent.ID, content)
	if err != nil {
		t.Fatalf("Create m4 失败: %v", err)
	}
	// 创建时默认 is_read=false，但为了不被 m1~m3 干扰（它们也是 false），
	// 我们手动把 m1~m3 设为 true
	if _, err := db.Exec(
		`UPDATE messages SET is_read = TRUE WHERE id = ANY($1)`,
		pq.Array([]string{m1.ID, m2.ID, m3.ID}),
	); err != nil {
		t.Fatalf("UPDATE m1~m3 is_read 失败: %v", err)
	}

	// 期望 FirstUnread 返回 m4
	got, err = msgRepo.FirstUnread(conv.ID)
	if err != nil {
		t.Fatalf("FirstUnread 失败: %v", err)
	}
	if got == nil || got.ID != m4.ID {
		t.Errorf("期望 m4，实际 %+v", got)
	}

	// 软删 m4 → FirstUnread 返回 nil（无未读）
	if err := msgRepo.SoftDelete(m4.ID); err != nil {
		t.Fatalf("SoftDelete m4 失败: %v", err)
	}
	got, err = msgRepo.FirstUnread(conv.ID)
	if err != nil {
		t.Fatalf("SoftDelete 后 FirstUnread 失败: %v", err)
	}
	if got != nil {
		t.Errorf("未读已软删应返回 nil，实际 %+v", got)
	}
}

// TestMessageRepo_ListBefore 校验游标分页：
//   - before 为空 → 返回最新 limit 条（newest first）；
//   - before 有值 → 返回 created_at < before 的消息（newest first）；
//   - 排除软删消息。
func TestMessageRepo_ListBefore(t *testing.T) {
	db := SetupTestDB(t)
	userRepo := NewUserRepo(db)
	agentRepo := NewAgentRepo(db)
	convRepo := NewConversationRepo(db)
	msgRepo := NewMessageRepo(db)

	user, err := userRepo.Create(uniqueShortName(t, "lb_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	agent, err := agentRepo.Create(user.ID, "LB-Agent", "secret")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}
	conv, err := convRepo.FindOrCreate(user.ID, agent.ID)
	if err != nil {
		t.Fatalf("FindOrCreate 失败: %v", err)
	}

	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`)

	// 造 5 条消息（m1 最早，m5 最新）
	var msgs []*model.Message
	for i := 0; i < 5; i++ {
		m, err := msgRepo.Create(conv.ID, "user", user.ID, content)
		if err != nil {
			t.Fatalf("Create m%d 失败: %v", i, err)
		}
		msgs = append(msgs, m)
		// 错开时间戳避免边界
		time.Sleep(2 * time.Millisecond)
	}

	// before 为空 → 返回最新 limit=3 条，应为 [m5, m4, m3]
	got, err := msgRepo.ListBefore(conv.ID, time.Time{}, 3)
	if err != nil {
		t.Fatalf("ListBefore 空 cursor 失败: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("期望 3 条，实际 %d", len(got))
	}
	if got[0].ID != msgs[4].ID || got[1].ID != msgs[3].ID || got[2].ID != msgs[2].ID {
		t.Errorf("空 cursor 期望 [m5,m4,m3]，实际 %s,%s,%s", got[0].ID, got[1].ID, got[2].ID)
	}

	// before = m3.created_at → 返回 created_at < m3 的消息，应为 [m2, m1]
	got, err = msgRepo.ListBefore(conv.ID, msgs[2].CreatedAt, 10)
	if err != nil {
		t.Fatalf("ListBefore m3 失败: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("期望 2 条，实际 %d", len(got))
	}
	if got[0].ID != msgs[1].ID || got[1].ID != msgs[0].ID {
		t.Errorf("cursor=m3 期望 [m2,m1]，实际 %s,%s", got[0].ID, got[1].ID)
	}

	// 软删 m1 → ListBefore 应排除
	if err := msgRepo.SoftDelete(msgs[0].ID); err != nil {
		t.Fatalf("SoftDelete m1 失败: %v", err)
	}
	got, err = msgRepo.ListBefore(conv.ID, msgs[2].CreatedAt, 10)
	if err != nil {
		t.Fatalf("SoftDelete 后 ListBefore 失败: %v", err)
	}
	if len(got) != 1 || got[0].ID != msgs[1].ID {
		t.Errorf("软删 m1 后期望 [m2]，实际 %+v", got)
	}
}

// TestMessageRepo_ListAfter 校验"未读方向"游标分页：
//   - after 有值 → 返回 created_at > after 的消息（ASC，最老在前）；
//   - 排除软删消息；
//   - 用于进入会话定位第一条未读（firstUnread + 之后的 N-1 条）。
func TestMessageRepo_ListAfter(t *testing.T) {
	db := SetupTestDB(t)
	userRepo := NewUserRepo(db)
	agentRepo := NewAgentRepo(db)
	convRepo := NewConversationRepo(db)
	msgRepo := NewMessageRepo(db)

	user, err := userRepo.Create(uniqueShortName(t, "la_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	agent, err := agentRepo.Create(user.ID, "LA-Agent", "secret")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}
	conv, err := convRepo.FindOrCreate(user.ID, agent.ID)
	if err != nil {
		t.Fatalf("FindOrCreate 失败: %v", err)
	}

	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`)

	// 造 5 条消息（m1 最早，m5 最新）
	var msgs []*model.Message
	for i := 0; i < 5; i++ {
		m, err := msgRepo.Create(conv.ID, "user", user.ID, content)
		if err != nil {
			t.Fatalf("Create m%d 失败: %v", i, err)
		}
		msgs = append(msgs, m)
		time.Sleep(2 * time.Millisecond)
	}

	// after = m2.createdAt - 1ms → 包含 m2 + 之后的（[m2, m3, m4, m5] ASC）
	after := msgs[1].CreatedAt.Add(-time.Millisecond)
	got, err := msgRepo.ListAfter(conv.ID, after, 10)
	if err != nil {
		t.Fatalf("ListAfter 失败: %v", err)
	}
	if len(got) != 4 {
		t.Fatalf("期望 4 条（m2~m5），实际 %d", len(got))
	}
	// ASC 顺序：第一条 m2，最后一条 m5
	if got[0].ID != msgs[1].ID {
		t.Errorf("ASC 第一条期望 m2，实际 %s", got[0].ID)
	}
	if got[3].ID != msgs[4].ID {
		t.Errorf("ASC 最后一条期望 m5，实际 %s", got[3].ID)
	}

	// limit 截断：limit=2 → 返回 [m2, m3]
	got, err = msgRepo.ListAfter(conv.ID, after, 2)
	if err != nil {
		t.Fatalf("ListAfter limit=2 失败: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("limit=2 期望 2 条，实际 %d", len(got))
	}
	if got[0].ID != msgs[1].ID || got[1].ID != msgs[2].ID {
		t.Errorf("limit=2 期望 [m2,m3]，实际 %s,%s", got[0].ID, got[1].ID)
	}

	// 软删 m3 → ListAfter 排除
	if err := msgRepo.SoftDelete(msgs[2].ID); err != nil {
		t.Fatalf("SoftDelete m3 失败: %v", err)
	}
	got, err = msgRepo.ListAfter(conv.ID, after, 10)
	if err != nil {
		t.Fatalf("SoftDelete 后 ListAfter 失败: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("软删 m3 后期望 3 条，实际 %d", len(got))
	}
	if got[0].ID != msgs[1].ID || got[1].ID != msgs[3].ID || got[2].ID != msgs[4].ID {
		t.Errorf("软删后期望 [m2,m4,m5]，实际 %s,%s,%s", got[0].ID, got[1].ID, got[2].ID)
	}
}
