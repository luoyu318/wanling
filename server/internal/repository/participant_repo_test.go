package repository

import (
	"database/sql"
	"encoding/json"
	"testing"
	"time"

	"github.com/lib/pq"
	"github.com/wanling/server/internal/model"
)

// === 测试公共 seed helper ===

// participantTestSeed 在已跑过 015 的 DB 上 seed 一组测试数据。
// 返回的 ids 供后续测试调用 ParticipantRepo 用。
//
// 注意:测试库 SetupTestDB 默认跑到 014(老 schema 含 user_id/agent_id),本测试在
// SetupTestDB 之后手动调 ExecMigration015 把 schema 切到 participants 模型。
type participantTestSeed struct {
	userAID  string // 第一个 user(owner 候选)
	userBID  string // 第二个 user(多人会话测试用)
	agentID  string // agent(owner = userA)
	convID   string // 一个空 conversation(无 participants, 测试自行 AddParticipants)
	conv2ID  string // 第二个 conversation(测 ListByMember 跨会话用)
}

// seedParticipantsTestDB 起 DB + 跑 015 + seed 基础数据。
// userA/userB 必填,agent owner 设为 userA(满足 agents.owner_id 外键约束)。
// 两个 conversation 都不绑 user_id/agent_id(015 后这俩字段已删),由测试自行 AddParticipants。
func seedParticipantsTestDB(t *testing.T) (*sql.DB, *ParticipantRepo, participantTestSeed) {
	t.Helper()
	db := SetupTestDB(t)
	ExecMigration015(t, db) // 015 默认被 SetupTestDB 跳过,这里手动跑切到 participants 模型
	repo := NewParticipantRepo(db)

	var seed participantTestSeed
	now := time.Now().UTC().Truncate(time.Microsecond)

	// userA
	if err := db.QueryRow(`
		INSERT INTO users (username, password_hash, avatar_url, created_at)
		VALUES ($1, $2, '', $3) RETURNING id
	`, uniqueShortName(t, "pa_"), "hash", now).Scan(&seed.userAID); err != nil {
		t.Fatalf("seed userA 失败: %v", err)
	}
	// userB
	if err := db.QueryRow(`
		INSERT INTO users (username, password_hash, avatar_url, created_at)
		VALUES ($1, $2, '', $3) RETURNING id
	`, uniqueShortName(t, "pb_"), "hash", now).Scan(&seed.userBID); err != nil {
		t.Fatalf("seed userB 失败: %v", err)
	}
	// agent(owner = userA,满足 agents.owner_id 外键)
	if err := db.QueryRow(`
		INSERT INTO agents (owner_id, name, avatar_url, secret_key, status, created_at)
		VALUES ($1, $2, '', $3, 'offline', $4) RETURNING id
	`, seed.userAID, "PAgent", "sk-p-test", now).Scan(&seed.agentID); err != nil {
		t.Fatalf("seed agent 失败: %v", err)
	}
	// 两个 conversation(默认 type=dm_user_agent)
	if err := db.QueryRow(`
		INSERT INTO conversations (last_message_at, created_at) VALUES ($1, $1) RETURNING id
	`, now).Scan(&seed.convID); err != nil {
		t.Fatalf("seed conv1 失败: %v", err)
	}
	if err := db.QueryRow(`
		INSERT INTO conversations (last_message_at, created_at) VALUES ($1, $1) RETURNING id
	`, now).Scan(&seed.conv2ID); err != nil {
		t.Fatalf("seed conv2 失败: %v", err)
	}
	return db, repo, seed
}

// beginTx helper:避免每个测试重复写 err 检查。
func beginTx(t *testing.T, db *sql.DB) *sql.Tx {
	t.Helper()
	tx, err := db.Begin()
	if err != nil {
		t.Fatalf("Begin 失败: %v", err)
	}
	t.Cleanup(func() {
		// 测试中途 fail 时回滚,避免污染后续测试
		_ = tx.Rollback()
	})
	return tx
}

// insertMessage 插一条 message 并返回 id。sender 是 (sender_type, sender_id) 元组。
func insertMessage(t *testing.T, db *sql.DB, convID, senderType, senderID string) string {
	t.Helper()
	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "hi"},
	})
	var id string
	if err := db.QueryRow(`
		INSERT INTO messages (conversation_id, sender_type, sender_id, content)
		VALUES ($1, $2, $3, $4::jsonb) RETURNING id
	`, convID, senderType, senderID, content).Scan(&id); err != nil {
		t.Fatalf("insert message 失败: %v", err)
	}
	return id
}

// insertDelivery 插一条 message_delivery(recipient + read_at 可空)。
func insertDelivery(t *testing.T, db *sql.DB, msgID, recipientID, recipientType string, readAt *time.Time) {
	t.Helper()
	var err error
	if readAt == nil {
		_, err = db.Exec(`
			INSERT INTO message_deliveries (message_id, recipient_id, recipient_type) VALUES ($1, $2, $3)
		`, msgID, recipientID, recipientType)
	} else {
		_, err = db.Exec(`
			INSERT INTO message_deliveries (message_id, recipient_id, recipient_type, read_at) VALUES ($1, $2, $3, $4)
		`, msgID, recipientID, recipientType, *readAt)
	}
	if err != nil {
		t.Fatalf("insert delivery 失败: %v", err)
	}
}

// assertUnread 校验某 member 的 unread_count 等于期望值,失败时 fail 并打印差异。
func assertUnread(t *testing.T, db *sql.DB, convID, memberID, memberType string, want int) {
	t.Helper()
	var got int
	err := db.QueryRow(`
		SELECT unread_count FROM conversation_participants
		WHERE conv_id = $1 AND member_id = $2 AND member_type = $3
	`, convID, memberID, memberType).Scan(&got)
	if err != nil {
		t.Fatalf("查 unread_count 失败 (%s/%s): %v", memberType, memberID, err)
	}
	if got != want {
		t.Errorf("%s/%s unread_count 错误: 期望 %d, 实际 %d", memberType, memberID, want, got)
	}
}

// === 测试场景 ===

// TestParticipantRepo_AddAndList 验证 AddParticipantsTx + ListByConversation + ListByMember:
//   - 批量加 3 个 participant(user_a owner, user_b member, agent member)
//   - ListByConversation 返回 3 行
//   - ListByMember(user_a) 返回该 user 参与的所有会话(含 conv1 + conv2)
//   - ON CONFLICT DO NOTHING 幂等:重复加同 member 不报错且不重复行
func TestParticipantRepo_AddAndList(t *testing.T) {
	db, repo, seed := seedParticipantsTestDB(t)

	// 让 user_a 也加入 conv2(测 ListByMember 多会话)
	tx := beginTx(t, db)
	if err := repo.AddParticipantsTx(tx, seed.conv2ID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
	}); err != nil {
		t.Fatalf("AddParticipants conv2 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit conv2 失败: %v", err)
	}

	// 1. 批量加 conv1 的 3 个 participant
	tx = beginTx(t, db)
	if err := repo.AddParticipantsTx(tx, seed.convID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
		{MemberID: seed.userBID, MemberType: "user", Role: "member"},
		{MemberID: seed.agentID, MemberType: "agent", Role: "member"},
	}); err != nil {
		t.Fatalf("AddParticipants conv1 失败: %v", err)
	}
	// 幂等:重复加 user_a 不报错且不重复
	if err := repo.AddParticipantsTx(tx, seed.convID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
	}); err != nil {
		t.Fatalf("AddParticipants 重复加 user_a 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit conv1 失败: %v", err)
	}

	// 2. ListByConversation 应返回 3 行(幂等加不重复)
	got, err := repo.ListByConversation(seed.convID)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("ListByConversation 行数错误: 期望 3, 实际 %d", len(got))
	}
	// 校验 role 字段:owner 应为 user_a
	roleOf := map[string]string{}
	for _, p := range got {
		roleOf[p.MemberType+":"+p.MemberID] = p.Role
	}
	if roleOf["user:"+seed.userAID] != "owner" {
		t.Errorf("user_a role 错误: 期望 owner, 实际 %s", roleOf["user:"+seed.userAID])
	}
	if roleOf["user:"+seed.userBID] != "member" {
		t.Errorf("user_b role 错误: 期望 member, 实际 %s", roleOf["user:"+seed.userBID])
	}
	if roleOf["agent:"+seed.agentID] != "member" {
		t.Errorf("agent role 错误: 期望 member, 实际 %s", roleOf["agent:"+seed.agentID])
	}

	// 3. ListByMember(user_a) 应返回 2 行(conv1 + conv2)
	aConvs, err := repo.ListByMember(seed.userAID, "user")
	if err != nil {
		t.Fatalf("ListByMember user_a 失败: %v", err)
	}
	if len(aConvs) != 2 {
		t.Fatalf("user_a 参与会话数错误: 期望 2(conv1+conv2), 实际 %d", len(aConvs))
	}
	// 校验两个 conv_id 都在
	convSet := map[string]bool{}
	for _, p := range aConvs {
		convSet[p.ConvID] = true
	}
	if !convSet[seed.convID] || !convSet[seed.conv2ID] {
		t.Errorf("user_a 参与会话错误: 期望 {%s, %s}, 实际 %v", seed.convID, seed.conv2ID, convSet)
	}

	// 4. Exists 校验
	exists, err := repo.Exists(seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("Exists 失败: %v", err)
	}
	if !exists {
		t.Errorf("Exists(user_a in conv1) 期望 true, 实际 false")
	}
	// user_a 不在 conv2 的非 owner 行(实际上 owner 也算 in),换一个不存在场景测:
	// 让我们用一个未加入 conv1 的"假 user id"测 Exists=false
	fakeUserID := "00000000-0000-0000-0000-000000000001"
	exists2, err := repo.Exists(seed.convID, fakeUserID, "user")
	if err != nil {
		t.Fatalf("Exists 失败: %v", err)
	}
	if exists2 {
		t.Errorf("Exists(fake user in conv1) 期望 false, 实际 true")
	}

	// 5. Get 校验完整字段
	p, err := repo.Get(seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("Get 失败: %v", err)
	}
	if p == nil {
		t.Fatalf("Get 返回 nil")
	}
	if p.Role != "owner" {
		t.Errorf("Get Role 错误: 期望 owner, 实际 %s", p.Role)
	}
	if p.UnreadCount != 0 {
		t.Errorf("Get UnreadCount 错误: 期望 0, 实际 %d", p.UnreadCount)
	}
	if p.LastReadMessageID != nil {
		t.Errorf("Get LastReadMessageID 期望 nil, 实际 %v", p.LastReadMessageID)
	}
	if p.HiddenAt != nil || p.PinnedAt != nil {
		t.Errorf("Get HiddenAt/PinnedAt 期望 nil, 实际 hidden=%v pinned=%v", p.HiddenAt, p.PinnedAt)
	}

	// 6. Get 不存在返 nil 不报错
	notExist, err := repo.Get(seed.convID, fakeUserID, "user")
	if err != nil {
		t.Fatalf("Get 不存在返 error: %v", err)
	}
	if notExist != nil {
		t.Errorf("Get 不存在期望 nil, 实际 %+v", notExist)
	}
}

// TestParticipantRepo_IncrUnreadExceptSender 验证 IncrUnreadTx 给非 sender 全员 +1,
// sender 不动。
//
// 场景:conv1 有 user_a + user_b + agent 三个 participant。
// user_a 发消息,IncrUnreadTx(conv, user_a, user) → user_b 和 agent 的 unread_count +1,
// user_a 的 unread_count 保持 0。
func TestParticipantRepo_IncrUnreadExceptSender(t *testing.T) {
	db, repo, seed := seedParticipantsTestDB(t)

	// 加 3 个 participant
	tx := beginTx(t, db)
	if err := repo.AddParticipantsTx(tx, seed.convID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
		{MemberID: seed.userBID, MemberType: "user", Role: "member"},
		{MemberID: seed.agentID, MemberType: "agent", Role: "member"},
	}); err != nil {
		t.Fatalf("AddParticipants 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// user_a 发消息(模拟):IncrUnreadTx(conv, user_a, user)
	tx = beginTx(t, db)
	if err := repo.IncrUnreadTx(tx, seed.convID, seed.userAID, "user"); err != nil {
		t.Fatalf("IncrUnreadTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// user_a 不变(0),user_b 和 agent 各 +1
	assertUnread(t, db, seed.convID, seed.userAID, "user", 0)
	assertUnread(t, db, seed.convID, seed.userBID, "user", 1)
	assertUnread(t, db, seed.convID, seed.agentID, "agent", 1)

	// 再发一条(agent 发),IncrUnreadTx(conv, agent, agent)
	// 期望:user_a +1(=1), user_b +1(=2), agent 不动(=1)
	tx = beginTx(t, db)
	if err := repo.IncrUnreadTx(tx, seed.convID, seed.agentID, "agent"); err != nil {
		t.Fatalf("IncrUnreadTx agent 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
	assertUnread(t, db, seed.convID, seed.userAID, "user", 1)
	assertUnread(t, db, seed.convID, seed.userBID, "user", 2)
	assertUnread(t, db, seed.convID, seed.agentID, "agent", 1)
}

// TestParticipantRepo_MarkMessagesRead 验证 MarkMessagesReadTx:
//   - seed 5 条 message 全部 delivery 给 user_a(read_at=NULL 未读)
//   - MarkMessagesReadTx(conv, user_a, [msg1, msg2])
//   - 校验 user_a.unread_count 重算正确(3 未读)
//   - 校验 user_a.last_read_message_id 更新为最新已读(msg2,按 m.created_at DESC)
//   - 校验只重算该 conv 的未读(不污染其他 conv)
func TestParticipantRepo_MarkMessagesRead(t *testing.T) {
	db, repo, seed := seedParticipantsTestDB(t)

	// 加 participant:user_a (conv1 owner),agent (conv1 member)
	tx := beginTx(t, db)
	if err := repo.AddParticipantsTx(tx, seed.convID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
		{MemberID: seed.agentID, MemberType: "agent", Role: "member"},
	}); err != nil {
		t.Fatalf("AddParticipants conv1 失败: %v", err)
	}
	// 也在 conv2 加 user_a,seed 几条 delivery(测跨 conv 不污染)
	if err := repo.AddParticipantsTx(tx, seed.conv2ID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
	}); err != nil {
		t.Fatalf("AddParticipants conv2 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// conv1:5 条 message,全部 delivery 给 user_a 未读(sender=agent,所以 user_a 是收件人)
	msgIDs := make([]string, 5)
	for i := 0; i < 5; i++ {
		msgIDs[i] = insertMessage(t, db, seed.convID, "agent", seed.agentID)
		insertDelivery(t, db, msgIDs[i], seed.userAID, "user", nil) // 未读
		// 让 created_at 单调递增,确保 msg5 是最新(LIMIT 1 取它)
		// 默认 NOW() 精度可能相同,显式 sleep 1us 避免排序歧义
		time.Sleep(2 * time.Millisecond)
	}

	// conv2:seed 2 条未读 delivery 给 user_a。
	// 注意:AddParticipantsTx 不自动重算 unread_count,unread_count 字段实时流靠 IncrUnreadTx
	// 维护。本测试用 IncrUnreadTx 显式给 conv2 的 user_a 累计 2(模拟 user_a 历史 2 条未读),
	// 然后调 MarkMessagesReadTx(conv1, ...) 应不动 conv2 的 unread_count(仍 2)。
	for i := 0; i < 2; i++ {
		mID := insertMessage(t, db, seed.conv2ID, "agent", seed.agentID)
		insertDelivery(t, db, mID, seed.userAID, "user", nil)
	}
	tx = beginTx(t, db)
	if err := repo.IncrUnreadTx(tx, seed.conv2ID, seed.agentID, "agent"); err != nil {
		t.Fatalf("IncrUnreadTx conv2 失败: %v", err)
	}
	// 第二次 IncrUnreadTx 让 conv2 的 user_a 累计 2
	if err := repo.IncrUnreadTx(tx, seed.conv2ID, seed.agentID, "agent"); err != nil {
		t.Fatalf("IncrUnreadTx conv2 第二次失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
	// 校验 conv2 初始 unread = 2
	assertUnread(t, db, seed.conv2ID, seed.userAID, "user", 2)

	// 调 MarkMessagesReadTx(conv1, user_a, [msg1, msg2])
	tx = beginTx(t, db)
	newUnread, err := repo.MarkMessagesReadTx(tx, seed.convID, seed.userAID, "user", msgIDs[:2])
	if err != nil {
		t.Fatalf("MarkMessagesReadTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// 期望 unread_count = 3(conv1 中剩 3 条未读:msg3/4/5)
	if newUnread != 3 {
		t.Errorf("MarkMessagesReadTx 返回 newUnread 错误: 期望 3, 实际 %d", newUnread)
	}
	// DB 中 user_a 在 conv1 的 unread_count 应为 3
	assertUnread(t, db, seed.convID, seed.userAID, "user", 3)
	// user_a 在 conv2 的 unread_count 不应被改(仍 2)
	assertUnread(t, db, seed.conv2ID, seed.userAID, "user", 2)

	// user_a.last_read_message_id 应更新为 msg2(已读 deliveries 中最新,即两个已读里时间靠后那个)
	var lastReadID sql.NullString
	err = db.QueryRow(`
		SELECT last_read_message_id FROM conversation_participants
		WHERE conv_id = $1 AND member_id = $2 AND member_type = $3
	`, seed.convID, seed.userAID, "user").Scan(&lastReadID)
	if err != nil {
		t.Fatalf("查 last_read_message_id 失败: %v", err)
	}
	if !lastReadID.Valid {
		t.Errorf("last_read_message_id 应有值, 实际 NULL")
	} else if lastReadID.String != msgIDs[1] {
		t.Errorf("last_read_message_id 错误: 期望 %s(msg2), 实际 %s", msgIDs[1], lastReadID.String)
	}

	// 再标剩下 3 条全部已读 → unread_count 应归 0
	tx = beginTx(t, db)
	newUnread2, err := repo.MarkMessagesReadTx(tx, seed.convID, seed.userAID, "user", msgIDs[2:])
	if err != nil {
		t.Fatalf("MarkMessagesReadTx 第二次失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
	if newUnread2 != 0 {
		t.Errorf("MarkMessagesReadTx 第二次 newUnread 错误: 期望 0, 实际 %d", newUnread2)
	}
	assertUnread(t, db, seed.convID, seed.userAID, "user", 0)
}

// TestParticipantRepo_MarkMessagesRead_EmptyList 验证空 messageIDs 不报错也不动 unread。
// (APP 端偶尔会传 [] 触发刷新,需要兼容。)
func TestParticipantRepo_MarkMessagesRead_EmptyList(t *testing.T) {
	db, repo, seed := seedParticipantsTestDB(t)

	tx := beginTx(t, db)
	if err := repo.AddParticipantsTx(tx, seed.convID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
	}); err != nil {
		t.Fatalf("AddParticipants 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// 空数组调 MarkMessagesReadTx 不应报错
	tx = beginTx(t, db)
	newUnread, err := repo.MarkMessagesReadTx(tx, seed.convID, seed.userAID, "user", nil)
	if err != nil {
		t.Fatalf("MarkMessagesReadTx 空 messageIDs 报错: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
	if newUnread != 0 {
		t.Errorf("newUnread 期望 0, 实际 %d", newUnread)
	}
}

// TestParticipantRepo_SetPinned_SetHidden 验证个人维度置顶 / 隐藏字段正确更新。
// 重复 SetPinned(true) 应更新时间(刷新),SetPinned(false) 应清空。
func TestParticipantRepo_SetPinned_SetHidden(t *testing.T) {
	db, repo, seed := seedParticipantsTestDB(t)

	tx := beginTx(t, db)
	if err := repo.AddParticipantsTx(tx, seed.convID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
		{MemberID: seed.userBID, MemberType: "user", Role: "member"},
	}); err != nil {
		t.Fatalf("AddParticipants 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// 初始均为 NULL
	p, _ := repo.Get(seed.convID, seed.userAID, "user")
	if p.HiddenAt != nil || p.PinnedAt != nil {
		t.Fatalf("初始 hidden/pinned 应为 nil, 实际 hidden=%v pinned=%v", p.HiddenAt, p.PinnedAt)
	}

	// user_a 置顶
	if err := repo.SetPinned(seed.convID, seed.userAID, "user", true); err != nil {
		t.Fatalf("SetPinned 失败: %v", err)
	}
	p, _ = repo.Get(seed.convID, seed.userAID, "user")
	if p.PinnedAt == nil {
		t.Errorf("SetPinned(true) 后 pinned_at 应有值, 实际 nil")
	}
	// user_b 的 pinned_at 不应受影响(个人维度)
	pB, _ := repo.Get(seed.convID, seed.userBID, "user")
	if pB.PinnedAt != nil {
		t.Errorf("user_b pinned_at 不应被 user_a 的置顶影响, 实际 %v", pB.PinnedAt)
	}

	// user_b 隐藏
	if err := repo.SetHidden(seed.convID, seed.userBID, "user", true); err != nil {
		t.Fatalf("SetHidden 失败: %v", err)
	}
	pB, _ = repo.Get(seed.convID, seed.userBID, "user")
	if pB.HiddenAt == nil {
		t.Errorf("SetHidden(true) 后 hidden_at 应有值, 实际 nil")
	}
	// user_a 的 hidden_at 不应受影响
	p, _ = repo.Get(seed.convID, seed.userAID, "user")
	if p.HiddenAt != nil {
		t.Errorf("user_a hidden_at 不应被 user_b 的隐藏影响, 实际 %v", p.HiddenAt)
	}

	// 取消置顶
	if err := repo.SetPinned(seed.convID, seed.userAID, "user", false); err != nil {
		t.Fatalf("SetPinned(false) 失败: %v", err)
	}
	p, _ = repo.Get(seed.convID, seed.userAID, "user")
	if p.PinnedAt != nil {
		t.Errorf("SetPinned(false) 后 pinned_at 应 nil, 实际 %v", p.PinnedAt)
	}

	// 取消隐藏
	if err := repo.SetHidden(seed.convID, seed.userBID, "user", false); err != nil {
		t.Fatalf("SetHidden(false) 失败: %v", err)
	}
	pB, _ = repo.Get(seed.convID, seed.userBID, "user")
	if pB.HiddenAt != nil {
		t.Errorf("SetHidden(false) 后 hidden_at 应 nil, 实际 %v", pB.HiddenAt)
	}
}

// TestParticipantRepo_RemoveParticipant 验证踢人 / 退群后 participants 行删除,
// 不影响其他 member 和会话本身。
func TestParticipantRepo_RemoveParticipant(t *testing.T) {
	db, repo, seed := seedParticipantsTestDB(t)

	tx := beginTx(t, db)
	if err := repo.AddParticipantsTx(tx, seed.convID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
		{MemberID: seed.userBID, MemberType: "user", Role: "member"},
		{MemberID: seed.agentID, MemberType: "agent", Role: "member"},
	}); err != nil {
		t.Fatalf("AddParticipants 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// 踢 user_b(member 退群)
	tx = beginTx(t, db)
	if err := repo.RemoveParticipantTx(tx, seed.convID, seed.userBID, "user"); err != nil {
		t.Fatalf("RemoveParticipant 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// user_b 应不在
	exists, _ := repo.Exists(seed.convID, seed.userBID, "user")
	if exists {
		t.Errorf("RemoveParticipant 后 user_b 仍存在")
	}
	// user_a 和 agent 应仍在
	existsA, _ := repo.Exists(seed.convID, seed.userAID, "user")
	if !existsA {
		t.Errorf("user_a 应仍在 conv1")
	}
	existsAg, _ := repo.Exists(seed.convID, seed.agentID, "agent")
	if !existsAg {
		t.Errorf("agent 应仍在 conv1")
	}

	// conversation 本身不应被删
	var convCount int
	if err := db.QueryRow(`SELECT COUNT(*) FROM conversations WHERE id = $1`, seed.convID).Scan(&convCount); err != nil {
		t.Fatalf("查 conversation 失败: %v", err)
	}
	if convCount != 1 {
		t.Errorf("conversation 不应被删, 实际 count=%d", convCount)
	}

	// ListByConversation 应只剩 2 行
	list, err := repo.ListByConversation(seed.convID)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(list) != 2 {
		t.Errorf("RemoveParticipant 后 ListByConversation 行数错误: 期望 2, 实际 %d", len(list))
	}
}

// TestParticipantRepo_OwnerLeaveDestroyConversation 验证 owner 退群 → 整个会话 +
// 所有 participants + messages + deliveries 全部删除(级联)。
//
// 设计(spec §1.1):conversations ON DELETE CASCADE 自动级联删:
//   - conversation_participants(conv_id 外键 CASCADE)
//   - messages(conversation_id 外键 CASCADE)
//   - message_deliveries(message_id 外键 CASCADE,通过 messages 中转级联)
func TestParticipantRepo_OwnerLeaveDestroyConversation(t *testing.T) {
	db, repo, seed := seedParticipantsTestDB(t)

	tx := beginTx(t, db)
	if err := repo.AddParticipantsTx(tx, seed.convID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
		{MemberID: seed.userBID, MemberType: "user", Role: "member"},
		{MemberID: seed.agentID, MemberType: "agent", Role: "member"},
	}); err != nil {
		t.Fatalf("AddParticipants 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// seed:3 条 message + 3 条 delivery
	msgIDs := make([]string, 3)
	for i := 0; i < 3; i++ {
		msgIDs[i] = insertMessage(t, db, seed.convID, "agent", seed.agentID)
		insertDelivery(t, db, msgIDs[i], seed.userAID, "user", nil)
		time.Sleep(2 * time.Millisecond)
	}

	// 校验 seed 数据存在
	var (
		partCnt, msgCnt, dCnt int
	)
	_ = db.QueryRow(`SELECT COUNT(*) FROM conversation_participants WHERE conv_id = $1`, seed.convID).Scan(&partCnt)
	_ = db.QueryRow(`SELECT COUNT(*) FROM messages WHERE conversation_id = $1`, seed.convID).Scan(&msgCnt)
	_ = db.QueryRow(`
		SELECT COUNT(*) FROM message_deliveries d
		JOIN messages m ON m.id = d.message_id
		WHERE m.conversation_id = $1
	`, seed.convID).Scan(&dCnt)
	if partCnt != 3 || msgCnt != 3 || dCnt != 3 {
		t.Fatalf("seed 数据错误: partCnt=%d(期望3), msgCnt=%d(期望3), dCnt=%d(期望3)", partCnt, msgCnt, dCnt)
	}

	// 调 DestroyConversationTx(owner 退群触发销毁)
	tx = beginTx(t, db)
	if err := repo.DestroyConversationTx(tx, seed.convID); err != nil {
		t.Fatalf("DestroyConversation 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// 校验级联删除:conversation + participants + messages + deliveries 全删
	var convExist int
	_ = db.QueryRow(`SELECT COUNT(*) FROM conversations WHERE id = $1`, seed.convID).Scan(&convExist)
	if convExist != 0 {
		t.Errorf("conversation 应被删, 实际 count=%d", convExist)
	}

	// participants:虽然 conv_id 外键 CASCADE,但靠 conv_id 查不到了,改查全表确保没残留
	var partRemain int
	_ = db.QueryRow(`SELECT COUNT(*) FROM conversation_participants WHERE conv_id = $1`, seed.convID).Scan(&partRemain)
	if partRemain != 0 {
		t.Errorf("participants 应被级联删, 实际 count=%d", partRemain)
	}

	// messages:靠 conversation_id CASCADE
	var msgRemain int
	_ = db.QueryRow(`SELECT COUNT(*) FROM messages WHERE conversation_id = $1`, seed.convID).Scan(&msgRemain)
	if msgRemain != 0 {
		t.Errorf("messages 应被级联删, 实际 count=%d", msgRemain)
	}

	// deliveries:靠 message_id CASCADE(通过 messages 中转)
	var dRemain int
	_ = db.QueryRow(`
		SELECT COUNT(*) FROM message_deliveries WHERE message_id = ANY($1::uuid[])
	`, pq.Array(msgIDs)).Scan(&dRemain)
	if dRemain != 0 {
		t.Errorf("deliveries 应被级联删, 实际 count=%d", dRemain)
	}
}

// 引用 model.ConversationParticipant 仅供编译期检查 model 字段对齐
var _ = model.ConversationParticipant{}
