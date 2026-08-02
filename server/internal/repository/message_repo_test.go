package repository

import (
	"database/sql"
	"encoding/json"
	"errors"
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
	conv, err := convRepo.FindOrCreateDM(t.Context(), "dm_user_agent", DMMembers{
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

// softDeleteViaTx 走 SoftDeleteTx + 事务撤回消息,与 production handler 一致。
// MessageRepo.SoftDelete(非 Tx)已删,测试只能通过 SoftDeleteTx 触发撤回状态。
func softDeleteViaTx(t *testing.T, repo *MessageRepo, msgID string) {
	t.Helper()
	tx, err := repo.queryExecutor.db.BeginTx(t.Context(), nil)
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	if err := repo.SoftDeleteTx(t.Context(), tx, msgID); err != nil {
		_ = tx.Rollback()
		t.Fatalf("SoftDeleteTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit 失败: %v", err)
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
	userMsg, err := repo.Create(t.Context(), seed.convID, "user", seed.userID, content)
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
	agentMsg, err := repo.Create(t.Context(), seed.convID, "agent", seed.agentID, content)
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
	conv, _ := convRepo.FindOrCreateDM(t.Context(), "dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: convSeed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: convSeed.agentID, MemberType: "agent"},
	})

	content := json.RawMessage(`{"msg_type":"text","data":{"text":"tx"}}`)
	tx, err := db.Begin()
	if err != nil {
		t.Fatalf("Begin 失败: %v", err)
	}
	m, err := msgRepo.CreateTx(t.Context(), tx, conv.ID, "user", convSeed.userID, content)
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
		m, err := repo.Create(t.Context(), seed.convID, "user", seed.userID, content)
		if err != nil {
			t.Fatalf("Create m%d 失败: %v", i, err)
		}
		msgs = append(msgs, m)
		// 错开时间戳避免边界
		time.Sleep(2 * time.Millisecond)
	}

	// before 为空 → 返回最新 limit=3 条, 应为 [m5, m4, m3]
	got, err := repo.ListBefore(t.Context(), seed.convID, seed.userID, "user", time.Now(), 3)
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
	got, err = repo.ListBefore(t.Context(), seed.convID, seed.userID, "user", msgs[2].CreatedAt, 50)
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
	softDeleteViaTx(t, repo, msgs[0].ID)
	got, err = repo.ListBefore(t.Context(), seed.convID, seed.userID, "user", msgs[2].CreatedAt, 50)
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
		m, _ := repo.Create(t.Context(), seed.convID, "user", seed.userID, content)
		msgs = append(msgs, m)
		time.Sleep(2 * time.Millisecond)
	}
	// m3 之前的消息数应为 2(m1 + m2)
	n, err := repo.CountBefore(t.Context(), seed.convID, seed.userID, "user", msgs[2].CreatedAt)
	if err != nil {
		t.Fatalf("CountBefore 失败: %v", err)
	}
	if n != 2 {
		t.Errorf("CountBefore(m3) 期望 2, 实际 %d", n)
	}

	// 软删 m1 → CountBefore(m3) 应返 1
	softDeleteViaTx(t, repo, msgs[0].ID)
	n, _ = repo.CountBefore(t.Context(), seed.convID, seed.userID, "user", msgs[2].CreatedAt)
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
		m, err := repo.Create(t.Context(), seed.convID, "user", seed.userID, content)
		if err != nil {
			t.Fatalf("Create m%d 失败: %v", i, err)
		}
		msgs = append(msgs, m)
		time.Sleep(2 * time.Millisecond)
	}

	// after = m2.createdAt - 1ms → 包含 m2 + 之后的([m2, m3, m4, m5] ASC)
	after := msgs[1].CreatedAt.Add(-time.Millisecond)
	got, err := repo.ListAfter(t.Context(), seed.convID, seed.userID, "user", after, 10)
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
	got, err = repo.ListAfter(t.Context(), seed.convID, seed.userID, "user", after, 2)
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
	softDeleteViaTx(t, repo, msgs[2].ID)
	got, err = repo.ListAfter(t.Context(), seed.convID, seed.userID, "user", after, 10)
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
	got, err := repo.Get(t.Context(), "00000000-0000-0000-0000-000000000001")
	if err != nil {
		t.Errorf("不存在应返 nil err, 实际 %v", err)
	}
	if got != nil {
		t.Errorf("不存在应返 nil, 实际 %+v", got)
	}
}

// === GetMessageContextTx 测试 ===
//
// GetMessageContextTx 服务于「跨页跳转」场景:用户点击引用块,客户端需要拿到
// target 消息 + 前后各 N 条,在 ChatPage 里把这段上下文单独渲染出来。
// 与 ListBefore/ListAfter 的关键差异:本方法**过滤软删除消息**(撤回的消息在跳转
// 视图里没意义,用户不需要看到「该消息已被撤回」占位)。target 自身仍按 Get 语义
// 不过滤 deleted_at(handler 层若需要禁止跳转到已撤回消息,自行判断)。
//
// tx 参数是为了让上层 handler 把「读取上下文」与其他操作(如更新跳转锚点)绑同一
// 事务;若不需要事务,传 nil tx 走 r.db 即可。本测试只验 repo 行为,tx 用法见
// TestGetMessageContextTx_UsesTx。

// createNMsgs 在指定 conv 内连发 n 条消息,每条间隔 2ms 错开 created_at。
// 返回的消息按创建顺序排列(msgs[0] 最早, msgs[n-1] 最新)。
func createNMsgs(t *testing.T, repo *MessageRepo, convID, senderID string, n int) []*model.Message {
	t.Helper()
	content := json.RawMessage(`{"msg_type":"text","data":{"text":"m"}}`)
	var msgs []*model.Message
	for i := 0; i < n; i++ {
		m, err := repo.Create(t.Context(), convID, "user", senderID, content)
		if err != nil {
			t.Fatalf("Create m%d 失败: %v", i, err)
		}
		msgs = append(msgs, m)
		time.Sleep(2 * time.Millisecond)
	}
	return msgs
}

// TestGetMessageContextHappyPath 校验:
//   - target 拿到正确的消息;
//   - before 返回 N 条(最近在前,DESC),严格 < target.CreatedAt;
//   - after 返回 N 条(最老在前,ASC),严格 > target.CreatedAt;
//   - 软删除的消息不在结果里(由 TestGetMessageContextSoftDeleted 单独覆盖)。
func TestGetMessageContextHappyPath(t *testing.T) {
	repo, seed := seedMsgFixture(t)
	msgs := createNMsgs(t, repo, seed.convID, seed.userID, 25)
	target := msgs[12] // 第 13 条(0-indexed 12),前后各 5 条充足

	tx, err := repo.queryExecutor.beginTx(t.Context())
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	defer func() { _ = tx.Rollback() }()

	gotTarget, before, after, err := repo.GetMessageContextTx(t.Context(), tx, target.ID, 5, 5)
	if err != nil {
		t.Fatalf("GetMessageContextTx 失败: %v", err)
	}
	if gotTarget == nil || gotTarget.ID != target.ID {
		t.Fatalf("target 期望 %s, 实际 %+v", target.ID, gotTarget)
	}

	// before 应是 [m12, m11, m10, m9, m8](DESC,最近在前)
	if len(before) != 5 {
		t.Fatalf("before 期望 5 条, 实际 %d", len(before))
	}
	for i, want := range []*model.Message{msgs[11], msgs[10], msgs[9], msgs[8], msgs[7]} {
		if before[i].ID != want.ID {
			t.Errorf("before[%d] 期望 %s, 实际 %s", i, want.ID, before[i].ID)
		}
	}

	// after 应是 [m13, m14, m15, m16, m17](ASC,最老在前)
	if len(after) != 5 {
		t.Fatalf("after 期望 5 条, 实际 %d", len(after))
	}
	for i, want := range []*model.Message{msgs[13], msgs[14], msgs[15], msgs[16], msgs[17]} {
		if after[i].ID != want.ID {
			t.Errorf("after[%d] 期望 %s, 实际 %s", i, want.ID, after[i].ID)
		}
	}
}

// TestGetMessageContextBeforeShort:target 接近会话开头,before=10 但只有 3 条。
// 应返回实际存在的 3 条(DESC),after 仍按请求的 5 条返回。
func TestGetMessageContextBeforeShort(t *testing.T) {
	repo, seed := seedMsgFixture(t)
	msgs := createNMsgs(t, repo, seed.convID, seed.userID, 10)
	target := msgs[2] // 前面只有 m0/m1/m2_target,要 10 条只能给 2 条

	tx, err := repo.queryExecutor.beginTx(t.Context())
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	defer func() { _ = tx.Rollback() }()

	_, before, after, err := repo.GetMessageContextTx(t.Context(), tx, target.ID, 10, 5)
	if err != nil {
		t.Fatalf("GetMessageContextTx 失败: %v", err)
	}
	if len(before) != 2 {
		t.Fatalf("before 期望 2 条(target=m2 前只有 m0,m1), 实际 %d", len(before))
	}
	if before[0].ID != msgs[1].ID || before[1].ID != msgs[0].ID {
		t.Errorf("before 期望 [m1,m0], 实际 %s,%s", before[0].ID, before[1].ID)
	}
	if len(after) != 5 {
		t.Fatalf("after 期望 5 条, 实际 %d", len(after))
	}
	if after[0].ID != msgs[3].ID || after[4].ID != msgs[7].ID {
		t.Errorf("after 期望 [m3..m7], 实际 %s..%s", after[0].ID, after[4].ID)
	}
}

// TestGetMessageContextAfterShort:target 接近会话末尾,after=10 但只有 3 条。
func TestGetMessageContextAfterShort(t *testing.T) {
	repo, seed := seedMsgFixture(t)
	msgs := createNMsgs(t, repo, seed.convID, seed.userID, 10)
	target := msgs[7] // 后面只有 m8/m9,要 10 条只能给 2 条

	tx, err := repo.queryExecutor.beginTx(t.Context())
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	defer func() { _ = tx.Rollback() }()

	_, before, after, err := repo.GetMessageContextTx(t.Context(), tx, target.ID, 5, 10)
	if err != nil {
		t.Fatalf("GetMessageContextTx 失败: %v", err)
	}
	if len(before) != 5 {
		t.Fatalf("before 期望 5 条, 实际 %d", len(before))
	}
	if before[0].ID != msgs[6].ID || before[4].ID != msgs[2].ID {
		t.Errorf("before 期望 [m6..m2], 实际 %s..%s", before[0].ID, before[4].ID)
	}
	if len(after) != 2 {
		t.Fatalf("after 期望 2 条(target=m7 后只有 m8,m9), 实际 %d", len(after))
	}
	if after[0].ID != msgs[8].ID || after[1].ID != msgs[9].ID {
		t.Errorf("after 期望 [m8,m9], 实际 %s,%s", after[0].ID, after[1].ID)
	}
}

// TestGetMessageContextTargetNotFound:target_id 不存在时返回 (nil, nil, nil, nil),
// 与现有 Get 的 not-found 约定一致。
func TestGetMessageContextTargetNotFound(t *testing.T) {
	repo, _ := seedMsgFixture(t)

	tx, err := repo.queryExecutor.beginTx(t.Context())
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	defer func() { _ = tx.Rollback() }()

	gotTarget, before, after, err := repo.GetMessageContextTx(
		t.Context(), tx, "00000000-0000-0000-0000-000000000001", 5, 5,
	)
	if err != nil {
		t.Errorf("target 不存在应返 nil err, 实际 %v", err)
	}
	if gotTarget != nil {
		t.Errorf("target 不存在应返 nil, 实际 %+v", gotTarget)
	}
	if before != nil {
		t.Errorf("before 应为 nil, 实际 %d 条", len(before))
	}
	if after != nil {
		t.Errorf("after 应为 nil, 实际 %d 条", len(after))
	}
}

// TestGetMessageContextSoftDeleted:校验 before/after 过滤软删除消息(deleted_at IS NOT NULL)。
// 造 7 条,撤回 m3(在 before 区)和 m5(在 after 区),target=m4,before=3,after=3。
// 期望 before=[m2,m1,m0](跳过 m3),after=[m6](跳过 m5,只剩 1 条非软删的)。
func TestGetMessageContextSoftDeleted(t *testing.T) {
	repo, seed := seedMsgFixture(t)
	msgs := createNMsgs(t, repo, seed.convID, seed.userID, 7)
	// 撤回 m3 和 m5
	softDeleteViaTx(t, repo, msgs[3].ID)
	softDeleteViaTx(t, repo, msgs[5].ID)

	target := msgs[4]
	tx, err := repo.queryExecutor.beginTx(t.Context())
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	defer func() { _ = tx.Rollback() }()

	gotTarget, before, after, err := repo.GetMessageContextTx(t.Context(), tx, target.ID, 3, 3)
	if err != nil {
		t.Fatalf("GetMessageContextTx 失败: %v", err)
	}
	if gotTarget == nil || gotTarget.ID != target.ID {
		t.Fatalf("target 期望 %s, 实际 %+v", target.ID, gotTarget)
	}

	// before: m3(撤回)被过滤,只剩 m2/m1/m0
	if len(before) != 3 {
		t.Fatalf("before 期望 3 条(撤回 m3 被过滤后只剩 m2,m1,m0), 实际 %d", len(before))
	}
	if before[0].ID != msgs[2].ID || before[1].ID != msgs[1].ID || before[2].ID != msgs[0].ID {
		t.Errorf("before 期望 [m2,m1,m0], 实际 %s,%s,%s",
			before[0].ID, before[1].ID, before[2].ID)
	}
	for _, m := range before {
		if m.DeletedAt.Valid {
			t.Errorf("before 不应包含软删消息, %s DeletedAt.Valid=true", m.ID)
		}
	}

	// after: m5(撤回)被过滤,只剩 m6
	if len(after) != 1 {
		t.Fatalf("after 期望 1 条(撤回 m5 被过滤后只剩 m6), 实际 %d", len(after))
	}
	if after[0].ID != msgs[6].ID {
		t.Errorf("after[0] 期望 m6, 实际 %s", after[0].ID)
	}
	if after[0].DeletedAt.Valid {
		t.Errorf("after 不应包含软删消息, %s DeletedAt.Valid=true", after[0].ID)
	}
}

// TestGetMessageContextCrossConv:校验 before/after 只返回同 conv 的消息,不混入其他 conv。
// convA 有 m0..m6(target=m4),convB 也有若干消息;before/after 不应包含 convB 的消息。
func TestGetMessageContextCrossConv(t *testing.T) {
	repo, seed := seedMsgFixture(t)
	// convA: 7 条
	msgsA := createNMsgs(t, repo, seed.convID, seed.userID, 7)

	// convB: 用 insertConvDirect 起一个新 conv(默认 type=dm_user_agent,无 participants
	// 不影响 messages 表的 foreign key,只要 convID 存在即可)。再造 5 条。
	db := repo.queryExecutor.db
	convBID := insertConvDirect(t, db)
	msgsB := createNMsgs(t, repo, convBID, seed.userID, 5)

	// 用一些 convB 的消息填在 convA target 的「时间窗口」附近:由于 msgsB 是在 msgsA 之后
	// 创建的,它们的 created_at 都 > msgsA 的最后一条。所以即使没 conv 过滤,convB 消息也
	// 只会出现在 after 区。target = msgsA[4](m4),before=3,after=10(故意大,看是否会拉到 convB)。
	target := msgsA[4]
	tx, err := repo.queryExecutor.beginTx(t.Context())
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	defer func() { _ = tx.Rollback() }()

	gotTarget, before, after, err := repo.GetMessageContextTx(t.Context(), tx, target.ID, 3, 10)
	if err != nil {
		t.Fatalf("GetMessageContextTx 失败: %v", err)
	}
	if gotTarget == nil || gotTarget.ID != target.ID {
		t.Fatalf("target 期望 %s, 实际 %+v", target.ID, gotTarget)
	}

	// before 应为 [m3,m2,m1]
	if len(before) != 3 {
		t.Fatalf("before 期望 3 条, 实际 %d", len(before))
	}
	if before[0].ID != msgsA[3].ID || before[1].ID != msgsA[2].ID || before[2].ID != msgsA[1].ID {
		t.Errorf("before 期望 [m3,m2,m1], 实际 %s,%s,%s",
			before[0].ID, before[1].ID, before[2].ID)
	}

	// after 应只含 convA 的 m5/m6(2 条),不含 convB 的任何消息
	if len(after) != 2 {
		t.Fatalf("after 期望 2 条(convA 的 m5,m6,不含 convB), 实际 %d", len(after))
	}
	if after[0].ID != msgsA[5].ID || after[1].ID != msgsA[6].ID {
		t.Errorf("after 期望 [m5,m6], 实际 %s,%s", after[0].ID, after[1].ID)
	}
	// 双重确认:after 里不应出现任何 convB 消息
	bIDs := map[string]bool{msgsB[0].ID: true, msgsB[1].ID: true, msgsB[2].ID: true, msgsB[3].ID: true, msgsB[4].ID: true}
	for _, m := range after {
		if bIDs[m.ID] {
			t.Errorf("after 不应包含 convB 消息, 但出现了 %s", m.ID)
		}
	}
	for _, m := range before {
		if bIDs[m.ID] {
			t.Errorf("before 不应包含 convB 消息, 但出现了 %s", m.ID)
		}
	}
}

// TestGetMessageContextTx_NilTx: tx=nil 走 r.db 路径(handler 不需要事务包裹时用此重载)。
// 之前所有测试都用真实 tx,Task 4 reviewer 指出 r.db fallback 路径无单测覆盖。
// 本测试补齐:不用 tx,直接传 nil,验 happy path 的 target + before + after。
func TestGetMessageContextTx_NilTx(t *testing.T) {
	repo, seed := seedMsgFixture(t)
	msgs := createNMsgs(t, repo, seed.convID, seed.userID, 5) // m0..m4,target = m2
	target := msgs[2]

	gotTarget, before, after, err := repo.GetMessageContextTx(t.Context(), nil, target.ID, 2, 2)
	if err != nil {
		t.Fatalf("GetMessageContextTx nil-tx 失败: %v", err)
	}
	if gotTarget == nil || gotTarget.ID != target.ID {
		t.Fatalf("target 期望 %s, 实际 %+v", target.ID, gotTarget)
	}
	// before=[m1, m0](DESC),after=[m3, m4](ASC)
	if len(before) != 2 || before[0].ID != msgs[1].ID || before[1].ID != msgs[0].ID {
		var got []string
		for _, m := range before {
			got = append(got, m.ID)
		}
		t.Errorf("before 期望 [%s, %s], 实际 %v", msgs[1].ID, msgs[0].ID, got)
	}
	if len(after) != 2 || after[0].ID != msgs[3].ID || after[1].ID != msgs[4].ID {
		var got []string
		for _, m := range after {
			got = append(got, m.ID)
		}
		t.Errorf("after 期望 [%s, %s], 实际 %v", msgs[3].ID, msgs[4].ID, got)
	}
}

// M1 防御性 limit 检查(listMessageContextRange 内)无单测直接覆盖:
// 该方法是包私有,GetMessageContextTx 用 `if before > 0` / `if after > 0` 短路了
// 负数入参,负数永远到不了 listMessageContextRange。该检查仅作为 defense-in-depth
// 兜底防未来其他调用方直接调本方法误传负数,handler 层已 clamp(本 task)更可靠。

// === UpdateContent 测试 ===
//
// UpdateContent 服务于「交互卡片状态变更」:plugin PATCH 原 card 消息的 status
// (permission_card / question_card 从 pending → 终态),触发 MESSAGE_UPDATE 广播
// 让 APP 重渲染卡片。只允许 sender 本人改自己发的消息(sender_id 写进 WHERE 兜底防 IDOR)。

// TestMessageRepo_UpdateContent 校验:
//   - 正确 sender 更新 content → 成功,DB 原地替换;
//   - 错误 sender_id → sql.ErrNoRows(WHERE 不命中,防越权)。
func TestMessageRepo_UpdateContent(t *testing.T) {
	repo, seed := seedMsgFixture(t)
	content := json.RawMessage(`{"msg_type":"permission_card","data":{"status":"pending"}}`)
	msg, err := repo.Create(t.Context(), seed.convID, "agent", seed.agentID, content)
	if err != nil {
		t.Fatalf("Create 失败: %v", err)
	}

	// 正确 sender 更新 content
	newContent := json.RawMessage(`{"msg_type":"permission_card","data":{"status":"approved","result":"once"}}`)
	if err := repo.UpdateContent(t.Context(), msg.ID, seed.agentID, newContent); err != nil {
		t.Fatalf("UpdateContent 失败: %v", err)
	}

	// 验证 DB 已原地替换
	updated, err := repo.Get(t.Context(), msg.ID)
	if err != nil {
		t.Fatalf("Get 失败: %v", err)
	}
	var got map[string]any
	if err := json.Unmarshal(updated.Content, &got); err != nil {
		t.Fatalf("unmarshal 失败: %v", err)
	}
	data, _ := got["data"].(map[string]any)
	if data["status"] != "approved" {
		t.Errorf("data.status 期望 approved, 实际 %v", data["status"])
	}
	if data["result"] != "once" {
		t.Errorf("data.result 期望 once, 实际 %v", data["result"])
	}

	// 错误 sender_id 不命中 WHERE → sql.ErrNoRows(防越权,与项目既有约定一致)
	err = repo.UpdateContent(t.Context(), msg.ID, seed.userID, newContent)
	if !errors.Is(err, sql.ErrNoRows) {
		t.Errorf("错误 sender 期望 sql.ErrNoRows, 实际 %v", err)
	}
}

// TestMessageRepo_ListByRoot 校验子 agent 事件树查询:
//   - Create 创建根消息(parent_msg_id=NULL, root_msg_id=NULL);
//   - CreateWithParent 创建子事件(parent=rootID, root=rootID);
//   - ListByRoot 按 root_msg_id 拉子树,不含根本身(根的 root_msg_id 为 NULL 自然被排除)。
func TestMessageRepo_ListByRoot(t *testing.T) {
	repo, seed := seedMsgFixture(t)

	// 建根 task 卡片(parent=NULL, root=NULL)
	rootContent, _ := json.Marshal(map[string]interface{}{
		"msg_type": "tool_card",
		"data":     map[string]string{"name": "task", "status": "starting"},
	})
	rootMsg, err := repo.Create(t.Context(), seed.convID, "agent", seed.agentID, rootContent)
	if err != nil {
		t.Fatalf("Create root: %v", err)
	}

	// 建子事件(parent=rootMsg.ID, root=rootMsg.ID)
	childContent, _ := json.Marshal(map[string]interface{}{
		"msg_type": "reasoning",
		"data":     map[string]string{"text": "子 agent 思考"},
	})
	if _, err := repo.CreateWithParent(t.Context(), seed.convID, "agent", seed.agentID, childContent, rootMsg.ID, rootMsg.ID); err != nil {
		t.Fatalf("CreateWithParent: %v", err)
	}

	// ListByRoot 应返回 1 条子事件(不含根本身)
	msgs, err := repo.ListByRoot(t.Context(), seed.convID, rootMsg.ID, 50)
	if err != nil {
		t.Fatalf("ListByRoot: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("expected 1 child msg, got %d", len(msgs))
	}
	if msgs[0].RootMsgID == nil || *msgs[0].RootMsgID != rootMsg.ID {
		t.Fatalf("child root_msg_id mismatch: got %v", msgs[0].RootMsgID)
	}
	if msgs[0].ParentMsgID == nil || *msgs[0].ParentMsgID != rootMsg.ID {
		t.Errorf("child parent_msg_id mismatch: got %v", msgs[0].ParentMsgID)
	}
}

// TestMessageRepo_ListXxx_FilterChildMessages 校验默认过滤:
// 主对话流(ListByConversation / ListBefore / ListAfter)必须排除子 agent 事件
// (is_main_stream=false),避免子 agent 的 tool_card / reasoning 等事件
// 污染主聊天列表。子树消息应通过 ListByRoot 单独查询。
// 审批卡豁免(is_main_stream=true)的校验见 TestMessageRepo_ListXxx_ApprovalCardVisible。
//
// 场景:1 条主消息(parent=NULL) + 1 条子事件(parent=root)。
// 期望:三个 List 方法都只返主消息,不含子事件。
func TestMessageRepo_ListXxx_FilterChildMessages(t *testing.T) {
	repo, seed := seedMsgFixture(t)
	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`)

	// 主消息(parent_msg_id=NULL)
	rootMsg, err := repo.Create(t.Context(), seed.convID, "user", seed.userID, content)
	if err != nil {
		t.Fatalf("Create root 失败: %v", err)
	}
	time.Sleep(2 * time.Millisecond)

	// 子事件(parent=rootMsg.ID, root=rootMsg.ID)
	childContent := json.RawMessage(`{"msg_type":"reasoning","data":{"text":"child"}}`)
	childMsg, err := repo.CreateWithParent(
		t.Context(), seed.convID, "agent", seed.agentID, childContent,
		rootMsg.ID, rootMsg.ID,
	)
	if err != nil {
		t.Fatalf("CreateWithParent 失败: %v", err)
	}

	// ListByConversation 应只返主消息,不含子事件
	got, err := repo.ListByConversation(t.Context(), seed.convID, seed.userID, "user", 50, 0)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("ListByConversation 期望 1 条(只含主消息), 实际 %d", len(got))
	}
	if got[0].ID != rootMsg.ID {
		t.Errorf("ListByConversation 返回了错误的消息: 期望 root %s, 实际 %s", rootMsg.ID, got[0].ID)
	}

	// ListBefore(before=零值,即返回最新 limit 条)应只返主消息
	got, err = repo.ListBefore(t.Context(), seed.convID, seed.userID, "user", time.Time{}, 50)
	if err != nil {
		t.Fatalf("ListBefore 失败: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("ListBefore 期望 1 条, 实际 %d", len(got))
	}
	if got[0].ID != rootMsg.ID {
		t.Errorf("ListBefore 返回了错误的消息: 期望 root %s, 实际 %s", rootMsg.ID, got[0].ID)
	}

	// ListAfter(after=rootMsg.CreatedAt - 1ms,窗口覆盖全部)应只返主消息,不含子事件
	after := rootMsg.CreatedAt.Add(-time.Millisecond)
	got, err = repo.ListAfter(t.Context(), seed.convID, seed.userID, "user", after, 50)
	if err != nil {
		t.Fatalf("ListAfter 失败: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("ListAfter 期望 1 条, 实际 %d", len(got))
	}
	if got[0].ID != rootMsg.ID {
		t.Errorf("ListAfter 返回了错误的消息: 期望 root %s, 实际 %s", rootMsg.ID, got[0].ID)
	}

	// 反向校验:子事件确实存在于 DB(通过 ListByRoot 可查到)
	subtree, err := repo.ListByRoot(t.Context(), seed.convID, rootMsg.ID, 50)
	if err != nil {
		t.Fatalf("ListByRoot 失败: %v", err)
	}
	if len(subtree) != 1 || subtree[0].ID != childMsg.ID {
		t.Errorf("ListByRoot 应返子事件 %s, 实际 %+v", childMsg.ID, subtree)
	}
}

// TestMessageRepo_CountBefore_FilterChildMessages 校验 CountBefore 同步过滤子 agent 事件。
// ListBefore/ListAfter/ListByConversation 用 is_main_stream 过滤,
// CountBefore 必须同步,否则 hasMoreBeforeFirstUnread 会因子事件误判为 true →
// APP 显示"上方加载更多"但 ListBefore 实际过滤后返空,UX 不一致。
//
// 场景:1 条主消息(parent=NULL) + 1 条子事件(parent=root),均早于 cutoff。
// 期望:CountBefore 返 1(只数主消息),不数子事件。
func TestMessageRepo_CountBefore_FilterChildMessages(t *testing.T) {
	repo, seed := seedMsgFixture(t)
	content := json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`)

	// 主消息(parent_msg_id=NULL)
	rootMsg, err := repo.Create(t.Context(), seed.convID, "user", seed.userID, content)
	if err != nil {
		t.Fatalf("Create root 失败: %v", err)
	}
	time.Sleep(2 * time.Millisecond)

	// 子事件(parent=rootMsg.ID, root=rootMsg.ID)
	childContent := json.RawMessage(`{"msg_type":"reasoning","data":{"text":"child"}}`)
	if _, err := repo.CreateWithParent(
		t.Context(), seed.convID, "agent", seed.agentID, childContent,
		rootMsg.ID, rootMsg.ID,
	); err != nil {
		t.Fatalf("CreateWithParent 失败: %v", err)
	}
	time.Sleep(2 * time.Millisecond)

	// cutoff 取子事件之后,确保两条都在 cutoff 之前
	cutoff := time.Now().Add(time.Second)

	// CountBefore 应只数主消息(1),不数子事件
	n, err := repo.CountBefore(t.Context(), seed.convID, seed.userID, "user", cutoff)
	if err != nil {
		t.Fatalf("CountBefore 失败: %v", err)
	}
	if n != 1 {
		t.Errorf("CountBefore 过滤子事件后期望 1, 实际 %d (子 agent 事件未被排除)", n)
	}
}

// TestMessageRepo_ListXxx_ApprovalCardVisible 校验:子 agent 审批卡
// (permission_card,带 parent/root)豁免主列表过滤(is_main_stream=true),
// 出现在 ListByConversation / ListBefore / ListAfter 中。
// 对比 FilterChildMessages:普通子事件(reasoning)仍被排除。
func TestMessageRepo_ListXxx_ApprovalCardVisible(t *testing.T) {
	repo, seed := seedMsgFixture(t)
	rootContent := json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`)

	// 主消息(parent=NULL)
	rootMsg, err := repo.Create(t.Context(), seed.convID, "user", seed.userID, rootContent)
	if err != nil {
		t.Fatalf("Create root 失败: %v", err)
	}
	time.Sleep(2 * time.Millisecond)

	// 子 agent 审批卡(parent=root, root=root):应豁免过滤
	permContent := json.RawMessage(`{"msg_type":"permission_card","data":{"status":"pending"}}`)
	permMsg, err := repo.CreateWithParent(
		t.Context(), seed.convID, "agent", seed.agentID, permContent,
		rootMsg.ID, rootMsg.ID,
	)
	if err != nil {
		t.Fatalf("CreateWithParent 审批卡失败: %v", err)
	}

	// ListByConversation 应含 root + 审批卡(2 条),不含普通子事件
	got, err := repo.ListByConversation(t.Context(), seed.convID, seed.userID, "user", 50, 0)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("ListByConversation 期望 2 条(root + 审批卡), 实际 %d", len(got))
	}
	// newest first:审批卡(root 之后创建)在前
	if got[0].ID != permMsg.ID || got[1].ID != rootMsg.ID {
		t.Errorf("ListByConversation 顺序错误:期望 [审批卡, root], 实际 [%s, %s]", got[0].ID, got[1].ID)
	}

	// ListBefore(零值=最新 limit 条)同样含 2 条
	got, err = repo.ListBefore(t.Context(), seed.convID, seed.userID, "user", time.Time{}, 50)
	if err != nil {
		t.Fatalf("ListBefore 失败: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("ListBefore 期望 2 条, 实际 %d", len(got))
	}

	// ListAfter(root 创建前 1ms)含 2 条
	after := rootMsg.CreatedAt.Add(-time.Millisecond)
	got, err = repo.ListAfter(t.Context(), seed.convID, seed.userID, "user", after, 50)
	if err != nil {
		t.Fatalf("ListAfter 失败: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("ListAfter 期望 2 条, 实际 %d", len(got))
	}
}
