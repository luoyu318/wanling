package repository

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/wanling/server/internal/model"
)

// === 测试 fixture ===
//
// participants 模型重构后,messages 表去掉了 is_read 字段。本测试包所有 seed
// 都在 015 新 schema 上做。createMessage 不再写 is_read,改由 DeliveryRepo 维护
// per-recipient 投递状态。

// msgTestSeed 起 DB + seed 1 user + 1 agent + 1 conversation(dm_user_agent)。
// conversation 用 FindOrCreateDM 创建,带 2 个 participants。
type msgTestSeed struct {
	userID  string
	agentID string
	convID  string
}

func seedMsgFixture(t *testing.T) (*MessageRepo, msgTestSeed) {
	t.Helper()
	db := SetupTestDB(t)
	convSeed := seedConvFixture(t, db)
	convRepo := NewConversationRepo(db)
	conv, err := convRepo.FindOrCreateDM("dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: convSeed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: convSeed.agentID, MemberType: "agent"},
	})
	if err != nil {
		t.Fatalf("FindOrCreateDM 失败: %v", err)
	}
	return NewMessageRepo(db), msgTestSeed{
		userID:  convSeed.userID,
		agentID: convSeed.agentID,
		convID:  conv.ID,
	}
}

// === Create / CreateTx 测试 ===

// TestMessageRepo_Create_NoIsReadField 验证 createMessage 不再写 is_read 字段。
// participants 模型重构后,is_read 字段已从 messages 表 DROP,所有 createMessage
// 入参不再带 is_read;返回的 Message struct 也没有 IsRead 字段。
func TestMessageRepo_Create_NoIsReadField(t *testing.T) {
	repo, seed := seedMsgFixture(t)
	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`)

	// user 发的消息:createMessage 应成功(不写 is_read)
	userMsg, err := repo.Create(seed.convID, "user", seed.userID, content)
	if err != nil {
		t.Fatalf("Create user 消息失败: %v", err)
	}
	if userMsg.ID == "" {
		t.Errorf("应返回非空 message id")
	}
	if userMsg.ConversationID != seed.convID {
		t.Errorf("conversation_id 不匹配: got=%s want=%s", userMsg.ConversationID, seed.convID)
	}

	// agent 发的消息:createMessage 应成功(不写 is_read)
	agentMsg, err := repo.Create(seed.convID, "agent", seed.agentID, content)
	if err != nil {
		t.Fatalf("Create agent 消息失败: %v", err)
	}
	if agentMsg.ID == "" {
		t.Errorf("应返回非空 message id")
	}
}

// TestMessageRepo_CreateTx 验证 CreateTx 在外部事务中工作。
func TestMessageRepo_CreateTx(t *testing.T) {
	db := SetupTestDB(t)
	convSeed := seedConvFixture(t, db)
	convRepo := NewConversationRepo(db)
	msgRepo := NewMessageRepo(db)
	conv, _ := convRepo.FindOrCreateDM("dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: convSeed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: convSeed.agentID, MemberType: "agent"},
	})

	content := json.RawMessage(`{"msg_type":"text","data":{"text":"tx"}}`)
	tx, err := db.Begin()
	if err != nil {
		t.Fatalf("Begin 失败: %v", err)
	}
	m, err := msgRepo.CreateTx(tx, conv.ID, "user", convSeed.userID, content)
	if err != nil {
		t.Fatalf("CreateTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit 失败: %v", err)
	}
	if m.ID == "" {
		t.Errorf("应返回非空 message id")
	}
}

// === SoftDelete / LastNonDeleted / ListByConversation 测试 ===

// TestMessageRepo_SoftDelete_LastNonDeleted_ListByConversation 过软删除全链路:
//  1. Create 两条消息
//  2. ListByConversation 能看到两条
//  3. SoftDelete 第一条
//  4. ListByConversation 仍返 2 条(撤回消息保留,spec §1,DB 完整保留)
//  5. LastNonDeleted 返回未删的那条(过滤 deleted_at)
//  6. SoftDelete 剩余那条后 LastNonDeleted 返回 nil
func TestMessageRepo_SoftDelete_LastNonDeleted_ListByConversation(t *testing.T) {
	repo, seed := seedMsgFixture(t)

	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`)
	m1, err := repo.Create(seed.convID, "user", seed.userID, content)
	if err != nil {
		t.Fatalf("Create m1 失败: %v", err)
	}
	m2, err := repo.Create(seed.convID, "agent", seed.agentID, content)
	if err != nil {
		t.Fatalf("Create m2 失败: %v", err)
	}

	// 两条都能查到
	list, err := repo.ListByConversation(seed.convID, seed.userID, "user", 50, 0)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(list) != 2 {
		t.Fatalf("应有 2 条消息, 实际 %d", len(list))
	}

	// 软删 m1
	if err := repo.SoftDelete(m1.ID); err != nil {
		t.Fatalf("SoftDelete m1 失败: %v", err)
	}
	list, _ = repo.ListByConversation(seed.convID, seed.userID, "user", 50, 0)
	if len(list) != 2 {
		t.Fatalf("软删后仍应列出 2 条(含撤回占位), 实际 %d", len(list))
	}
	// 找到 m1(被撤回的),校验 DeletedAt.Valid=true
	var recalled *model.Message
	for i := range list {
		if list[i].ID == m1.ID {
			recalled = &list[i]
			break
		}
	}
	if recalled == nil {
		t.Fatal("撤回的 m1 应仍在列表中")
	}
	if !recalled.DeletedAt.Valid {
		t.Error("撤回的 m1 DeletedAt.Valid 应为 true")
	}

	// LastNonDeleted 返回 m2(最新未删)
	last, err := repo.LastNonDeleted(seed.convID)
	if err != nil {
		t.Fatalf("LastNonDeleted 失败: %v", err)
	}
	if last == nil || last.ID != m2.ID {
		t.Errorf("LastNonDeleted 应为 m2, 实际 %v", last)
	}

	// Get 能查到已删的吗?设计上 Get 不过滤 deleted_at(权限校验需要知道消息存在与否),
	// 这里只断言能查到(id 存在)。
	got, err := repo.Get(m1.ID)
	if err != nil {
		t.Fatalf("Get m1 失败: %v", err)
	}
	if got == nil {
		t.Fatal("Get 应返回消息(即使已软删), 实际 nil")
	}

	// 软删 m2 后 LastNonDeleted 返回 nil
	if err := repo.SoftDelete(m2.ID); err != nil {
		t.Fatalf("SoftDelete m2 失败: %v", err)
	}
	last, err = repo.LastNonDeleted(seed.convID)
	if err != nil {
		t.Fatalf("LastNonDeleted 全删后失败: %v", err)
	}
	if last != nil {
		t.Errorf("全删后 LastNonDeleted 应为 nil, 实际 %v", last)
	}
}

// TestMessageRepo_SoftDeleteByIDs_GetByIDs 验证批量软删 + 批量查询。
func TestMessageRepo_SoftDeleteByIDs_GetByIDs(t *testing.T) {
	repo, seed := seedMsgFixture(t)

	content := json.RawMessage(`{"msg_type":"text","data":{"text":"x"}}`)
	m1, _ := repo.Create(seed.convID, "user", seed.userID, content)
	m2, _ := repo.Create(seed.convID, "user", seed.userID, content)
	m3, _ := repo.Create(seed.convID, "user", seed.userID, content)

	// GetByIDs 返回 3 条
	got, err := repo.GetByIDs([]string{m1.ID, m2.ID, m3.ID})
	if err != nil {
		t.Fatalf("GetByIDs 失败: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("GetByIDs 应返回 3 条, 实际 %d", len(got))
	}

	// 批量软删 m1 + m2, 返回受影响 2 行
	n, err := repo.SoftDeleteByIDs([]string{m1.ID, m2.ID})
	if err != nil {
		t.Fatalf("SoftDeleteByIDs 失败: %v", err)
	}
	if n != 2 {
		t.Errorf("受影响行数应为 2, 实际 %d", n)
	}

	// ListByConversation 仍返 3 条(spec §1:撤回消息不过滤)
	list, _ := repo.ListByConversation(seed.convID, seed.userID, "user", 50, 0)
	if len(list) != 3 {
		t.Errorf("批量软删后仍应列出 3 条(含撤回占位), 实际 %d", len(list))
	}
	// m1/m2 应有 DeletedAt.Valid=true,m3 仍 false
	deleted := map[string]bool{m1.ID: true, m2.ID: true}
	for i := range list {
		if deleted[list[i].ID] {
			if !list[i].DeletedAt.Valid {
				t.Errorf("撤回的 %s DeletedAt.Valid 应为 true", list[i].ID)
			}
		} else {
			if list[i].DeletedAt.Valid {
				t.Errorf("未撤回的 %s DeletedAt.Valid 应为 false", list[i].ID)
			}
		}
	}
}

// === ListBefore / ListAfter / CountBefore 测试 ===

// TestMessageRepo_ListBefore 校验游标分页:
//   - before 为空 → 返回最新 limit 条(newest first);
//   - before 有值 → 返回 created_at < before 的消息(newest first);
//   - 包含软删消息(spec §1:撤回消息不过滤,DB 完整保留)。
func TestMessageRepo_ListBefore(t *testing.T) {
	repo, seed := seedMsgFixture(t)
	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`)

	// 造 5 条消息(m1 最早, m5 最新)
	var msgs []*model.Message
	for i := 0; i < 5; i++ {
		m, err := repo.Create(seed.convID, "user", seed.userID, content)
		if err != nil {
			t.Fatalf("Create m%d 失败: %v", i, err)
		}
		msgs = append(msgs, m)
		// 错开时间戳避免边界
		time.Sleep(2 * time.Millisecond)
	}

	// before 为空 → 返回最新 limit=3 条, 应为 [m5, m4, m3]
	got, err := repo.ListBefore(seed.convID, seed.userID, "user", time.Now(), 3)
	if err != nil {
		t.Fatalf("ListBefore 空 cursor 失败: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("期望 3 条, 实际 %d", len(got))
	}
	if got[0].ID != msgs[4].ID || got[1].ID != msgs[3].ID || got[2].ID != msgs[2].ID {
		t.Errorf("空 cursor 期望 [m5,m4,m3], 实际 %s,%s,%s", got[0].ID, got[1].ID, got[2].ID)
	}

	// before = m3.created_at → 返回 created_at < m3 的消息, 应为 [m2, m1]
	got, err = repo.ListBefore(seed.convID, seed.userID, "user", msgs[2].CreatedAt, 50)
	if err != nil {
		t.Fatalf("ListBefore m3 失败: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("期望 2 条, 实际 %d", len(got))
	}
	if got[0].ID != msgs[1].ID || got[1].ID != msgs[0].ID {
		t.Errorf("cursor=m3 期望 [m2,m1], 实际 %s,%s", got[0].ID, got[1].ID)
	}

	// 软删 m1 → ListBefore 仍返 m1(spec §1:撤回消息保留,DB 完整保留)
	if err := repo.SoftDelete(msgs[0].ID); err != nil {
		t.Fatalf("SoftDelete m1 失败: %v", err)
	}
	got, err = repo.ListBefore(seed.convID, seed.userID, "user", msgs[2].CreatedAt, 50)
	if err != nil {
		t.Fatalf("SoftDelete 后 ListBefore 失败: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("软删 m1 后仍应列出 2 条(含撤回 m1), 实际 %d", len(got))
	}
	if got[0].ID != msgs[1].ID || got[1].ID != msgs[0].ID {
		t.Errorf("期望 [m2, m1(撤回)], 实际 %s,%s", got[0].ID, got[1].ID)
	}
	// 校验 m1(撤回)的 DeletedAt.Valid=true
	if !got[1].DeletedAt.Valid {
		t.Error("撤回的 m1 DeletedAt.Valid 应为 true")
	}
}

// TestMessageRepo_CountBefore 校验 CountBefore 返回 created_at < before 的未删消息数。
func TestMessageRepo_CountBefore(t *testing.T) {
	repo, seed := seedMsgFixture(t)
	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`)

	var msgs []*model.Message
	for i := 0; i < 3; i++ {
		m, _ := repo.Create(seed.convID, "user", seed.userID, content)
		msgs = append(msgs, m)
		time.Sleep(2 * time.Millisecond)
	}
	// m3 之前的消息数应为 2(m1 + m2)
	n, err := repo.CountBefore(seed.convID, seed.userID, "user", msgs[2].CreatedAt)
	if err != nil {
		t.Fatalf("CountBefore 失败: %v", err)
	}
	if n != 2 {
		t.Errorf("CountBefore(m3) 期望 2, 实际 %d", n)
	}

	// 软删 m1 → CountBefore(m3) 应返 1
	if err := repo.SoftDelete(msgs[0].ID); err != nil {
		t.Fatalf("SoftDelete m1 失败: %v", err)
	}
	n, _ = repo.CountBefore(seed.convID, seed.userID, "user", msgs[2].CreatedAt)
	if n != 1 {
		t.Errorf("软删 m1 后 CountBefore(m3) 期望 1, 实际 %d", n)
	}
}

// TestMessageRepo_ListAfter 校验"未读方向"游标分页:
//   - after 有值 → 返回 created_at > after 的消息(ASC, 最老在前);
//   - 包含软删消息(spec §1:撤回消息不过滤,DB 完整保留)。
func TestMessageRepo_ListAfter(t *testing.T) {
	repo, seed := seedMsgFixture(t)
	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`)

	var msgs []*model.Message
	for i := 0; i < 5; i++ {
		m, err := repo.Create(seed.convID, "user", seed.userID, content)
		if err != nil {
			t.Fatalf("Create m%d 失败: %v", i, err)
		}
		msgs = append(msgs, m)
		time.Sleep(2 * time.Millisecond)
	}

	// after = m2.createdAt - 1ms → 包含 m2 + 之后的([m2, m3, m4, m5] ASC)
	after := msgs[1].CreatedAt.Add(-time.Millisecond)
	got, err := repo.ListAfter(seed.convID, seed.userID, "user", after, 10)
	if err != nil {
		t.Fatalf("ListAfter 失败: %v", err)
	}
	if len(got) != 4 {
		t.Fatalf("期望 4 条(m2~m5), 实际 %d", len(got))
	}
	if got[0].ID != msgs[1].ID {
		t.Errorf("ASC 第一条期望 m2, 实际 %s", got[0].ID)
	}
	if got[3].ID != msgs[4].ID {
		t.Errorf("ASC 最后一条期望 m5, 实际 %s", got[3].ID)
	}

	// limit 截断:limit=2 → 返回 [m2, m3]
	got, err = repo.ListAfter(seed.convID, seed.userID, "user", after, 2)
	if err != nil {
		t.Fatalf("ListAfter limit=2 失败: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("limit=2 期望 2 条, 实际 %d", len(got))
	}
	if got[0].ID != msgs[1].ID || got[1].ID != msgs[2].ID {
		t.Errorf("limit=2 期望 [m2,m3], 实际 %s,%s", got[0].ID, got[1].ID)
	}

	// 软删 m3 → ListAfter 仍返 m3(spec §1:撤回消息保留,DB 完整保留)
	if err := repo.SoftDelete(msgs[2].ID); err != nil {
		t.Fatalf("SoftDelete m3 失败: %v", err)
	}
	got, err = repo.ListAfter(seed.convID, seed.userID, "user", after, 10)
	if err != nil {
		t.Fatalf("SoftDelete 后 ListAfter 失败: %v", err)
	}
	if len(got) != 4 {
		t.Fatalf("软删 m3 后仍应列出 4 条(含撤回 m3), 实际 %d", len(got))
	}
	if got[0].ID != msgs[1].ID || got[1].ID != msgs[2].ID || got[2].ID != msgs[3].ID || got[3].ID != msgs[4].ID {
		t.Errorf("期望 [m2, m3(撤回), m4, m5], 实际 %s,%s,%s,%s",
			got[0].ID, got[1].ID, got[2].ID, got[3].ID)
	}
	// 校验 m3(撤回)的 DeletedAt.Valid=true
	if !got[1].DeletedAt.Valid {
		t.Error("撤回的 m3 DeletedAt.Valid 应为 true")
	}
}

// TestMessageRepo_Get_NotExists 验证 Get 不存在返 (nil, nil)。
func TestMessageRepo_Get_NotExists(t *testing.T) {
	repo, _ := seedMsgFixture(t)
	got, err := repo.Get("00000000-0000-0000-0000-000000000001")
	if err != nil {
		t.Errorf("不存在应返 nil err, 实际 %v", err)
	}
	if got != nil {
		t.Errorf("不存在应返 nil, 实际 %+v", got)
	}
}

// TestMessageRepo_LastNonDeleted_NoMessages 验证空会话(无消息/全删)LastNonDeleted 返 nil。
func TestMessageRepo_LastNonDeleted_NoMessages(t *testing.T) {
	repo, seed := seedMsgFixture(t)
	last, err := repo.LastNonDeleted(seed.convID)
	if err != nil {
		t.Fatalf("LastNonDeleted 空会话失败: %v", err)
	}
	if last != nil {
		t.Errorf("空会话 LastNonDeleted 应返 nil, 实际 %+v", last)
	}
}

// === Recall(撤回)行为测试 ===

// TestMessageRepo_Recall_StillListed 验证撤回的消息仍出现在 ListByConversation 中(spec §1)。
// 撤回的判定靠 SanitizeForClient 改写 Content(S1.4 handler 出口处),不靠查询过滤。
func TestMessageRepo_Recall_StillListed(t *testing.T) {
	repo, seed := seedMsgFixture(t)
	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hello"}}`)
	m, err := repo.Create(seed.convID, "user", seed.userID, content)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if err := repo.SoftDelete(m.ID); err != nil {
		t.Fatalf("SoftDelete: %v", err)
	}
	list, err := repo.ListByConversation(seed.convID, seed.userID, "user", 50, 0)
	if err != nil {
		t.Fatalf("ListByConversation: %v", err)
	}
	if len(list) != 1 || list[0].ID != m.ID {
		t.Errorf("撤回的消息应仍被列出, 实际 list=%+v", list)
	}
	if !list[0].DeletedAt.Valid {
		t.Errorf("撤回的消息 DeletedAt.Valid 应为 true")
	}
}

// TestMessageRepo_Recall_LastNonDeletedExcluded 验证撤回消息不算 last message。
// LastNonDeleted 保持 deleted_at IS NULL 过滤(spec §1 查询过滤策略表)。
func TestMessageRepo_Recall_LastNonDeletedExcluded(t *testing.T) {
	repo, seed := seedMsgFixture(t)
	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`)
	m1, _ := repo.Create(seed.convID, "user", seed.userID, content)
	m2, _ := repo.Create(seed.convID, "user", seed.userID, content)

	// 撤回最新的 m2
	if err := repo.SoftDelete(m2.ID); err != nil {
		t.Fatalf("SoftDelete: %v", err)
	}
	last, err := repo.LastNonDeleted(seed.convID)
	if err != nil {
		t.Fatalf("LastNonDeleted: %v", err)
	}
	if last == nil || last.ID != m1.ID {
		t.Errorf("LastNonDeleted 应返 m1(次新), 实际 %+v", last)
	}
}
