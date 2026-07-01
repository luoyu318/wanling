package repository

import (
	"testing"
	"time"
)

// === 测试场景 ===

// TestDeliveryRepo_CreateBatch 验证 CreateBatchTx:
//   - seed 1 条 message + 3 个 participant(user_a owner, user_b member, agent member)
//   - CreateBatchTx(message, [user_a, user_b, agent])
//   - 校验 message_deliveries 表有 3 行,read_at 全部 NULL
//   - 重复调(传重叠 recipients)不报错不重复(ON CONFLICT DO NOTHING)
//   - 空 recipients slice 直接返 nil 不报错
func TestDeliveryRepo_CreateBatch(t *testing.T) {
	db, pRepo, seed := seedParticipantsTestDB(t)
	dRepo := NewDeliveryRepo(db)

	// 加 3 个 participant
	tx := beginTx(t, db)
	if err := pRepo.AddParticipantsTx(tx, seed.convID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
		{MemberID: seed.userBID, MemberType: "user", Role: "member"},
		{MemberID: seed.agentID, MemberType: "agent", Role: "member"},
	}); err != nil {
		t.Fatalf("AddParticipants 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// 查 participants(走 repo 而非裸 SQL,得到 ConversationParticipant 切片喂给 CreateBatchTx)
	participants, err := pRepo.ListByConversation(seed.convID)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(participants) != 3 {
		t.Fatalf("ListByConversation 行数错误: 期望 3, 实际 %d", len(participants))
	}

	// 插一条 message(sender 假装是 user_a)
	msgID := insertMessage(t, db, seed.convID, "user", seed.userAID)

	// 调 CreateBatchTx:把 3 个 participant 都作为 recipient(实际场景应排除 sender,
	// 但本测试只验 CRUD 行为,不关心 sender 过滤逻辑)
	tx = beginTx(t, db)
	if err := dRepo.CreateBatchTx(tx, msgID, participants); err != nil {
		t.Fatalf("CreateBatchTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// 校验 deliveries 表有 3 行,read_at 全部 NULL
	var (
		dCnt      int
		nullCnt   int
	)
	err = db.QueryRow(`
		SELECT COUNT(*), COUNT(*) FILTER (WHERE read_at IS NULL)
		FROM message_deliveries WHERE message_id = $1
	`, msgID).Scan(&dCnt, &nullCnt)
	if err != nil {
		t.Fatalf("查 deliveries 失败: %v", err)
	}
	if dCnt != 3 {
		t.Errorf("deliveries 行数错误: 期望 3, 实际 %d", dCnt)
	}
	if nullCnt != 3 {
		t.Errorf("read_at 全 NULL 错误: 期望 3, 实际 %d", nullCnt)
	}

	// 幂等:重复调(传重叠 recipients)不报错不重复
	tx = beginTx(t, db)
	if err := dRepo.CreateBatchTx(tx, msgID, participants); err != nil {
		t.Fatalf("CreateBatchTx 重复调失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
	err = db.QueryRow(`SELECT COUNT(*) FROM message_deliveries WHERE message_id = $1`, msgID).Scan(&dCnt)
	if err != nil {
		t.Fatalf("查 deliveries 失败: %v", err)
	}
	if dCnt != 3 {
		t.Errorf("幂等后 deliveries 行数错误: 期望 3, 实际 %d", dCnt)
	}

	// 空数组调 CreateBatchTx 不应报错
	tx = beginTx(t, db)
	if err := dRepo.CreateBatchTx(tx, msgID, nil); err != nil {
		t.Errorf("CreateBatchTx 空 recipients 报错: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
}

// TestDeliveryRepo_MarkReadBatch 验证 MarkReadBatchTx:
//   - seed 5 条 message 全部 delivery 给 user_a 未读
//   - MarkReadBatchTx([msg1, msg2, msg3], user_a) 返回 3
//   - 再 MarkReadBatchTx([msg2, msg3, msg4], user_a) 返回 1(msg2/msg3 已读过)
//   - 越权场景:user_b 调 MarkReadBatchTx([msg1..msg5]) 应返 0(不是 user_b 的 delivery)
//   - 空 messageIDs 直接返 (0, nil)
func TestDeliveryRepo_MarkReadBatch(t *testing.T) {
	db, pRepo, seed := seedParticipantsTestDB(t)
	dRepo := NewDeliveryRepo(db)

	// 加 user_a 为 conv1 participant
	tx := beginTx(t, db)
	if err := pRepo.AddParticipantsTx(tx, seed.convID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
		{MemberID: seed.userBID, MemberType: "user", Role: "member"},
	}); err != nil {
		t.Fatalf("AddParticipants 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// seed:5 条 message + 5 条 delivery 给 user_a(全部未读)
	msgIDs := make([]string, 5)
	for i := 0; i < 5; i++ {
		msgIDs[i] = insertMessage(t, db, seed.convID, "agent", seed.agentID)
		insertDelivery(t, db, msgIDs[i], seed.userAID, "user", nil)
	}

	// 1. MarkReadBatchTx([msg1, msg2, msg3], user_a) 应返 3
	tx = beginTx(t, db)
	affected, err := dRepo.MarkReadBatchTx(tx, msgIDs[:3], seed.userAID, "user")
	if err != nil {
		t.Fatalf("MarkReadBatchTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
	if affected != 3 {
		t.Errorf("MarkReadBatchTx 影响行数错误: 期望 3, 实际 %d", affected)
	}

	// 2. 再 MarkReadBatchTx([msg2, msg3, msg4], user_a) 应返 1(msg2/msg3 已读过,read_at IS NULL 守卫)
	tx = beginTx(t, db)
	affected2, err := dRepo.MarkReadBatchTx(tx, msgIDs[1:4], seed.userAID, "user")
	if err != nil {
		t.Fatalf("MarkReadBatchTx 第二次失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
	if affected2 != 1 {
		t.Errorf("MarkReadBatchTx 第二次影响行数错误: 期望 1(仅 msg4), 实际 %d", affected2)
	}

	// 3. 越权场景:user_b 调 MarkReadBatchTx([msg1..msg5], user_b) 应返 0
	//    (msg1..msg5 的 delivery recipient 是 user_a,user_b 无 delivery 行)
	tx = beginTx(t, db)
	affected3, err := dRepo.MarkReadBatchTx(tx, msgIDs, seed.userBID, "user")
	if err != nil {
		t.Fatalf("MarkReadBatchTx user_b 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
	if affected3 != 0 {
		t.Errorf("越权 MarkReadBatchTx 影响行数错误: 期望 0, 实际 %d", affected3)
	}

	// 4. 空 messageIDs 直接返 (0, nil)
	tx = beginTx(t, db)
	affected4, err := dRepo.MarkReadBatchTx(tx, nil, seed.userAID, "user")
	if err != nil {
		t.Errorf("MarkReadBatchTx 空 messageIDs 报错: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
	if affected4 != 0 {
		t.Errorf("空 MarkReadBatchTx 影响行数错误: 期望 0, 实际 %d", affected4)
	}
}

// TestDeliveryRepo_FirstUnread 验证 FirstUnread:
//   - seed:1 conv + 5 messages,user_a 是 recipient,全部未读
//   - 标 msg1/msg2 已读 → FirstUnread 应返回 msg3(按 created_at ASC 排序的首条未读)
//   - 全部标已读 → FirstUnread 返 nil
//   - 软删场景:msg4 软删后,即使它原本是首条未读,FirstUnread 应跳过(过滤 deleted_at IS NULL)
//   - FirstUnreadTx 同样验证一次
func TestDeliveryRepo_FirstUnread(t *testing.T) {
	db, pRepo, seed := seedParticipantsTestDB(t)
	dRepo := NewDeliveryRepo(db)

	tx := beginTx(t, db)
	if err := pRepo.AddParticipantsTx(tx, seed.convID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
	}); err != nil {
		t.Fatalf("AddParticipants 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// seed:5 条 message + 5 条 delivery 给 user_a(全部未读)。sleep 确保 created_at 单调递增。
	msgIDs := make([]string, 5)
	for i := 0; i < 5; i++ {
		msgIDs[i] = insertMessage(t, db, seed.convID, "agent", seed.agentID)
		insertDelivery(t, db, msgIDs[i], seed.userAID, "user", nil)
		time.Sleep(2 * time.Millisecond)
	}

	// 1. 初始 FirstUnread 应返回 msg1(最早未读)
	m, err := dRepo.FirstUnread(seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("FirstUnread 失败: %v", err)
	}
	if m == nil {
		t.Fatalf("FirstUnread 返 nil, 期望 msg1")
	}
	if m.ID != msgIDs[0] {
		t.Errorf("FirstUnread 返回 id 错误: 期望 %s(msg1), 实际 %s", msgIDs[0], m.ID)
	}

	// 2. 标 msg1/msg2 已读 → FirstUnread 应返回 msg3
	tx = beginTx(t, db)
	if _, err := dRepo.MarkReadBatchTx(tx, msgIDs[:2], seed.userAID, "user"); err != nil {
		t.Fatalf("MarkReadBatchTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
	m, err = dRepo.FirstUnread(seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("FirstUnread 失败: %v", err)
	}
	if m == nil {
		t.Fatalf("标 msg1/msg2 后 FirstUnread 返 nil, 期望 msg3")
	}
	if m.ID != msgIDs[2] {
		t.Errorf("FirstUnread 返回 id 错误: 期望 %s(msg3), 实际 %s", msgIDs[2], m.ID)
	}

	// 3. FirstUnreadTx 同样验证一次(Tx 版本走通)
	tx = beginTx(t, db)
	mTx, err := dRepo.FirstUnreadTx(tx, seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("FirstUnreadTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
	if mTx == nil {
		t.Fatalf("FirstUnreadTx 返 nil, 期望 msg3")
	}
	if mTx.ID != msgIDs[2] {
		t.Errorf("FirstUnreadTx 返回 id 错误: 期望 %s(msg3), 实际 %s", msgIDs[2], mTx.ID)
	}

	// 4. 软删 msg3 → FirstUnread 应跳过,返回 msg4
	if _, err := db.Exec(`UPDATE messages SET deleted_at = NOW() WHERE id = $1`, msgIDs[2]); err != nil {
		t.Fatalf("软删 msg3 失败: %v", err)
	}
	m, err = dRepo.FirstUnread(seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("软删后 FirstUnread 失败: %v", err)
	}
	if m == nil {
		t.Fatalf("软删 msg3 后 FirstUnread 返 nil, 期望 msg4")
	}
	if m.ID != msgIDs[3] {
		t.Errorf("软删 msg3 后 FirstUnread 错误: 期望 %s(msg4), 实际 %s", msgIDs[3], m.ID)
	}

	// 5. 标 msg4/msg5 已读 → 全部已读,FirstUnread 返 nil
	tx = beginTx(t, db)
	if _, err := dRepo.MarkReadBatchTx(tx, msgIDs[3:], seed.userAID, "user"); err != nil {
		t.Fatalf("MarkReadBatchTx msg4/msg5 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
	m, err = dRepo.FirstUnread(seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("全部已读后 FirstUnread 失败: %v", err)
	}
	if m != nil {
		t.Errorf("全部已读后 FirstUnread 应返 nil, 实际 %+v", m)
	}
}

// TestDeliveryRepo_GetUnreadCount 验证 GetUnreadCount / GetUnreadCountTx:
//   - seed 5 条未读 + 标 2 条已读 → 应返 3
//   - 软删 1 条未读 → 应返 2(JOIN messages 过滤 deleted_at)
//   - 越权场景:查 user_b 未读应返 0(user_b 无 delivery)
//   - 跨会话不污染:conv2 的 delivery 不应计入 conv1 的计数
func TestDeliveryRepo_GetUnreadCount(t *testing.T) {
	db, pRepo, seed := seedParticipantsTestDB(t)
	dRepo := NewDeliveryRepo(db)

	tx := beginTx(t, db)
	if err := pRepo.AddParticipantsTx(tx, seed.convID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
	}); err != nil {
		t.Fatalf("AddParticipants conv1 失败: %v", err)
	}
	// conv2 也加 user_a,seed 1 条 conv2 的 delivery 测跨会话不污染
	if err := pRepo.AddParticipantsTx(tx, seed.conv2ID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
	}); err != nil {
		t.Fatalf("AddParticipants conv2 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// seed conv1:5 条 message + 5 条未读 delivery 给 user_a
	msgIDs := make([]string, 5)
	for i := 0; i < 5; i++ {
		msgIDs[i] = insertMessage(t, db, seed.convID, "agent", seed.agentID)
		insertDelivery(t, db, msgIDs[i], seed.userAID, "user", nil)
	}
	// seed conv2:1 条未读 delivery(测跨会话不污染)
	conv2Msg := insertMessage(t, db, seed.conv2ID, "agent", seed.agentID)
	insertDelivery(t, db, conv2Msg, seed.userAID, "user", nil)

	// 1. 初始 GetUnreadCount(conv1, user_a) = 5
	cnt, err := dRepo.GetUnreadCount(seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("GetUnreadCount 失败: %v", err)
	}
	if cnt != 5 {
		t.Errorf("GetUnreadCount 错误: 期望 5, 实际 %d", cnt)
	}
	// conv2 的计数应独立(=1)
	cnt2, err := dRepo.GetUnreadCount(seed.conv2ID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("GetUnreadCount conv2 失败: %v", err)
	}
	if cnt2 != 1 {
		t.Errorf("GetUnreadCount conv2 错误: 期望 1, 实际 %d", cnt2)
	}

	// 2. 标 msg1/msg2 已读 → conv1 计数 = 3
	tx = beginTx(t, db)
	if _, err := dRepo.MarkReadBatchTx(tx, msgIDs[:2], seed.userAID, "user"); err != nil {
		t.Fatalf("MarkReadBatchTx 失败: %v", err)
	}
	// 同事务调 GetUnreadCountTx 验证(Tx 版本走通)
	cntTx, err := dRepo.GetUnreadCountTx(tx, seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("GetUnreadCountTx 失败: %v", err)
	}
	if cntTx != 3 {
		t.Errorf("GetUnreadCountTx 错误: 期望 3, 实际 %d", cntTx)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// 3. 软删 msg3(未读) → conv1 计数 = 2(JOIN messages 过滤 deleted_at)
	if _, err := db.Exec(`UPDATE messages SET deleted_at = NOW() WHERE id = $1`, msgIDs[2]); err != nil {
		t.Fatalf("软删 msg3 失败: %v", err)
	}
	cnt, err = dRepo.GetUnreadCount(seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("软删后 GetUnreadCount 失败: %v", err)
	}
	if cnt != 2 {
		t.Errorf("软删后 GetUnreadCount 错误: 期望 2, 实际 %d", cnt)
	}

	// 4. 越权场景:查 user_b 在 conv1 的未读应返 0(user_b 无 delivery)
	cntB, err := dRepo.GetUnreadCount(seed.convID, seed.userBID, "user")
	if err != nil {
		t.Fatalf("GetUnreadCount user_b 失败: %v", err)
	}
	if cntB != 0 {
		t.Errorf("越权 GetUnreadCount user_b 错误: 期望 0, 实际 %d", cntB)
	}
}

// TestDeliveryRepo_NoParticipantsEdgeCase 验证无 recipient 时的边界:
//   - GetUnreadCount 对无 delivery 的 recipient 返 0 不报错
//   - FirstUnread 对无 delivery 的 recipient 返 nil 不报错
func TestDeliveryRepo_NoParticipantsEdgeCase(t *testing.T) {
	db, _, seed := seedParticipantsTestDB(t)
	dRepo := NewDeliveryRepo(db)

	// 一个未加入任何 participant 的 fake user
	fakeUserID := "00000000-0000-0000-0000-000000000099"

	// GetUnreadCount 对无 delivery 的 recipient 应返 0
	cnt, err := dRepo.GetUnreadCount(seed.convID, fakeUserID, "user")
	if err != nil {
		t.Errorf("GetUnreadCount 无 delivery 报错: %v", err)
	}
	if cnt != 0 {
		t.Errorf("GetUnreadCount 无 delivery 错误: 期望 0, 实际 %d", cnt)
	}

	// FirstUnread 对无 delivery 的 recipient 应返 (nil, nil)
	m, err := dRepo.FirstUnread(seed.convID, fakeUserID, "user")
	if err != nil {
		t.Errorf("FirstUnread 无 delivery 报错: %v", err)
	}
	if m != nil {
		t.Errorf("FirstUnread 无 delivery 应返 nil, 实际 %+v", m)
	}
}
