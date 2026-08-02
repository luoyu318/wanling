package repository

import (
	"encoding/json"
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
	if err := pRepo.AddParticipantsTx(t.Context(), tx, seed.convID, []ParticipantInput{
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
	participants, err := pRepo.ListByConversation(t.Context(), seed.convID)
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
	if err := dRepo.CreateBatchTx(t.Context(), tx, msgID, participants); err != nil {
		t.Fatalf("CreateBatchTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// 校验 deliveries 表有 3 行,read_at 全部 NULL
	var (
		dCnt    int
		nullCnt int
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
	if err := dRepo.CreateBatchTx(t.Context(), tx, msgID, participants); err != nil {
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
	if err := dRepo.CreateBatchTx(t.Context(), tx, msgID, nil); err != nil {
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
	if err := pRepo.AddParticipantsTx(t.Context(), tx, seed.convID, []ParticipantInput{
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
	affected, err := dRepo.MarkReadBatchTx(t.Context(), tx, msgIDs[:3], seed.userAID, "user")
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
	affected2, err := dRepo.MarkReadBatchTx(t.Context(), tx, msgIDs[1:4], seed.userAID, "user")
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
	affected3, err := dRepo.MarkReadBatchTx(t.Context(), tx, msgIDs, seed.userBID, "user")
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
	affected4, err := dRepo.MarkReadBatchTx(t.Context(), tx, nil, seed.userAID, "user")
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
func TestDeliveryRepo_FirstUnread(t *testing.T) {
	db, pRepo, seed := seedParticipantsTestDB(t)
	dRepo := NewDeliveryRepo(db)

	tx := beginTx(t, db)
	if err := pRepo.AddParticipantsTx(t.Context(), tx, seed.convID, []ParticipantInput{
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
	m, err := dRepo.FirstUnread(t.Context(), seed.convID, seed.userAID, "user")
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
	if _, err := dRepo.MarkReadBatchTx(t.Context(), tx, msgIDs[:2], seed.userAID, "user"); err != nil {
		t.Fatalf("MarkReadBatchTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
	m, err = dRepo.FirstUnread(t.Context(), seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("FirstUnread 失败: %v", err)
	}
	if m == nil {
		t.Fatalf("标 msg1/msg2 后 FirstUnread 返 nil, 期望 msg3")
	}
	if m.ID != msgIDs[2] {
		t.Errorf("FirstUnread 返回 id 错误: 期望 %s(msg3), 实际 %s", msgIDs[2], m.ID)
	}

	// 3. 软删 msg3 → FirstUnread 应跳过,返回 msg4
	if _, err := db.Exec(`UPDATE messages SET deleted_at = NOW() WHERE id = $1`, msgIDs[2]); err != nil {
		t.Fatalf("软删 msg3 失败: %v", err)
	}
	m, err = dRepo.FirstUnread(t.Context(), seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("软删后 FirstUnread 失败: %v", err)
	}
	if m == nil {
		t.Fatalf("软删 msg3 后 FirstUnread 返 nil, 期望 msg4")
	}
	if m.ID != msgIDs[3] {
		t.Errorf("软删 msg3 后 FirstUnread 错误: 期望 %s(msg4), 实际 %s", msgIDs[3], m.ID)
	}

	// 4. 标 msg4/msg5 已读 → 全部已读,FirstUnread 返 nil
	tx = beginTx(t, db)
	if _, err := dRepo.MarkReadBatchTx(t.Context(), tx, msgIDs[3:], seed.userAID, "user"); err != nil {
		t.Fatalf("MarkReadBatchTx msg4/msg5 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
	m, err = dRepo.FirstUnread(t.Context(), seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("全部已读后 FirstUnread 失败: %v", err)
	}
	if m != nil {
		t.Errorf("全部已读后 FirstUnread 应返 nil, 实际 %+v", m)
	}
}

// TestDeliveryRepo_FirstUnread_FilterChildMessages 验证 FirstUnread 与 ListBefore 一致,
// 过滤子 agent 事件(parent_msg_id IS NOT NULL),避免子事件成为未读锚点。
// 场景(按 created_at 升序):
//   - rootMsg:正常消息(parent=NULL),会被标已读,同时作为子事件的 parent/root
//   - childMsg:子 agent 事件(parent=rootMsg, root=rootMsg),未读 —— 早于 normalUnread 创建
//   - normalUnread:正常未读消息(parent=NULL)
//
// 期望:标 rootMsg 已读后,FirstUnread 返回 normalUnread(而非时间更早的 childMsg),
// 证明子事件被过滤。若无过滤,ORDER BY created_at ASC 会返回 childMsg,与
// ListBefore(过滤子事件)产生空锚点不一致。
func TestDeliveryRepo_FirstUnread_FilterChildMessages(t *testing.T) {
	db, pRepo, seed := seedParticipantsTestDB(t)
	dRepo := NewDeliveryRepo(db)
	mRepo := NewMessageRepo(db)

	tx := beginTx(t, db)
	if err := pRepo.AddParticipantsTx(t.Context(), tx, seed.convID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
	}); err != nil {
		t.Fatalf("AddParticipants 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// rootMsg:正常消息(parent=NULL),作为子事件的 parent/root,后续标已读
	rootID := insertMessage(t, db, seed.convID, "agent", seed.agentID)
	insertDelivery(t, db, rootID, seed.userAID, "user", nil)
	time.Sleep(2 * time.Millisecond)

	// childMsg:子 agent 事件(parent=rootID, root=rootID),未读 —— 早于 normalUnread
	childContent, _ := json.Marshal(map[string]interface{}{
		"msg_type": "reasoning",
		"data":     map[string]string{"text": "子事件"},
	})
	childMsg, err := mRepo.CreateWithParent(t.Context(), seed.convID, "agent", seed.agentID, childContent, rootID, rootID)
	if err != nil {
		t.Fatalf("CreateWithParent 失败: %v", err)
	}
	insertDelivery(t, db, childMsg.ID, seed.userAID, "user", nil)
	time.Sleep(2 * time.Millisecond)

	// normalUnread:正常未读消息(parent=NULL),晚于 childMsg 创建
	normalUnreadID := insertMessage(t, db, seed.convID, "agent", seed.agentID)
	insertDelivery(t, db, normalUnreadID, seed.userAID, "user", nil)

	// 标 rootID 已读,剩下候选未读:childMsg(早) + normalUnread(晚)
	tx = beginTx(t, db)
	if _, err := dRepo.MarkReadBatchTx(t.Context(), tx, []string{rootID}, seed.userAID, "user"); err != nil {
		t.Fatalf("MarkReadBatchTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// FirstUnread 应返回 normalUnread(过滤子事件),而非时间更早的 childMsg
	m, err := dRepo.FirstUnread(t.Context(), seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("FirstUnread 失败: %v", err)
	}
	if m == nil {
		t.Fatalf("FirstUnread 返 nil, 期望 %s(normalUnread)", normalUnreadID)
	}
	if m.ID != normalUnreadID {
		t.Errorf("FirstUnread 应跳过子事件返回 %s(normalUnread), 实际 %s", normalUnreadID, m.ID)
	}
}

// TestDeliveryRepo_FirstUnread_FilterSilent 验证 FirstUnread 跳过 silent 消息
// (与 IncrUnreadTx 跳过 silent 一致,与 client _filterDisplayable 过滤 step_finish 对齐)。
// 场景(按 created_at 升序):
//   - silentMsg:content.silent=true 的 step_finish(process 类消息),delivery 未读
//   - normalMsg:正常 text 消息(content 不含 silent 或 silent=false),delivery 未读
//
// 期望:FirstUnread 返回 normalMsg(跳过时间更早的 silentMsg)。
// 反证(无 silent 过滤时):ORDER BY created_at ASC 会返回 silentMsg,client 端
// _filterDisplayable 把 step_finish 过滤掉 → messages 为空 → 定位/markRead 都不触发 → 徽章残留。
func TestDeliveryRepo_FirstUnread_FilterSilent(t *testing.T) {
	db, pRepo, seed := seedParticipantsTestDB(t)
	dRepo := NewDeliveryRepo(db)

	tx := beginTx(t, db)
	if err := pRepo.AddParticipantsTx(t.Context(), tx, seed.convID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
	}); err != nil {
		t.Fatalf("AddParticipants 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// silentMsg:content.silent=true(step_finish),delivery 未读 —— 早于 normalMsg
	silentContent, _ := json.Marshal(map[string]interface{}{
		"msg_type": "step_finish",
		"silent":   true,
		"data":     map[string]interface{}{"reason": "stop", "duration": 1.2},
	})
	var silentID string
	if err := db.QueryRow(`
		INSERT INTO messages (conversation_id, sender_type, sender_id, content)
		VALUES ($1, 'agent', $2, $3::jsonb) RETURNING id
	`, seed.convID, seed.agentID, silentContent).Scan(&silentID); err != nil {
		t.Fatalf("insert silent message 失败: %v", err)
	}
	insertDelivery(t, db, silentID, seed.userAID, "user", nil)
	time.Sleep(2 * time.Millisecond)

	// normalMsg:正常 text 消息,delivery 未读 —— 晚于 silentMsg
	normalID := insertMessage(t, db, seed.convID, "agent", seed.agentID)
	insertDelivery(t, db, normalID, seed.userAID, "user", nil)

	// FirstUnread 应返回 normalID(过滤 silent),而非时间更早的 silentID
	m, err := dRepo.FirstUnread(t.Context(), seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("FirstUnread 失败: %v", err)
	}
	if m == nil {
		t.Fatalf("FirstUnread 返 nil, 期望 %s(normalMsg)", normalID)
	}
	if m.ID != normalID {
		t.Errorf("FirstUnread 应跳过 silent 消息返回 %s(normalMsg), 实际 %s(silentMsg 被选作锚点)", normalID, m.ID)
	}
}

// TestDeliveryRepo_FirstUnread_OnlySilent 验证只有 silent 消息未读时,FirstUnread 返 nil。
// 场景:conv 中只有 silent 消息 delivery 未读(read_at=NULL),无正常消息未读。
// 期望:FirstUnread 返 (nil, nil)——silent 不应作未读锚点。
// 这种状态在生产中是过渡态(下一次 IncrUnreadTx 不会 +1,unread_count 仍是 0,
// UnreadInfo handler 在 unread_count=0 时不调 FirstUnread,本测直接验证 repo 层语义)。
func TestDeliveryRepo_FirstUnread_OnlySilent(t *testing.T) {
	db, pRepo, seed := seedParticipantsTestDB(t)
	dRepo := NewDeliveryRepo(db)

	tx := beginTx(t, db)
	if err := pRepo.AddParticipantsTx(t.Context(), tx, seed.convID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
	}); err != nil {
		t.Fatalf("AddParticipants 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// 只插一条 silent 消息,delivery 未读
	silentContent, _ := json.Marshal(map[string]interface{}{
		"msg_type": "step_finish",
		"silent":   true,
		"data":     map[string]interface{}{"reason": "stop"},
	})
	var silentID string
	if err := db.QueryRow(`
		INSERT INTO messages (conversation_id, sender_type, sender_id, content)
		VALUES ($1, 'agent', $2, $3::jsonb) RETURNING id
	`, seed.convID, seed.agentID, silentContent).Scan(&silentID); err != nil {
		t.Fatalf("insert silent message 失败: %v", err)
	}
	insertDelivery(t, db, silentID, seed.userAID, "user", nil)

	// 只有 silent 未读 → FirstUnread 应返 nil
	m, err := dRepo.FirstUnread(t.Context(), seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("FirstUnread 失败: %v", err)
	}
	if m != nil {
		t.Errorf("FirstUnread 只剩 silent 未读时应返 nil, 实际 %+v", m)
	}
}

// TestDeliveryRepo_ListUnreadMessageIDsByConv 验证 ListUnreadMessageIDsByConv:
//   - seed 3 条 message:user_a 是 recipient,前 2 条未读,第 3 条已读
//   - 调 ListUnreadMessageIDsByConv 应返前 2 条 message_id
//   - 软删 msg1 后再查应只返 msg2(JOIN messages 过滤 deleted_at)
//   - 越权:user_b 在该 conv 无 delivery,返空 slice 不报错
//   - 跨会话不污染:conv2 的未读不应计入 conv1
func TestDeliveryRepo_ListUnreadMessageIDsByConv(t *testing.T) {
	db, pRepo, seed := seedParticipantsTestDB(t)
	dRepo := NewDeliveryRepo(db)

	tx := beginTx(t, db)
	if err := pRepo.AddParticipantsTx(t.Context(), tx, seed.convID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
	}); err != nil {
		t.Fatalf("AddParticipants conv1 失败: %v", err)
	}
	if err := pRepo.AddParticipantsTx(t.Context(), tx, seed.conv2ID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
	}); err != nil {
		t.Fatalf("AddParticipants conv2 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// seed conv1:3 条 message + 3 条 delivery 给 user_a
	msgIDs := make([]string, 3)
	for i := 0; i < 3; i++ {
		msgIDs[i] = insertMessage(t, db, seed.convID, "agent", seed.agentID)
		insertDelivery(t, db, msgIDs[i], seed.userAID, "user", nil)
		time.Sleep(2 * time.Millisecond)
	}
	// seed conv2:1 条未读 delivery(测跨会话不污染)
	conv2Msg := insertMessage(t, db, seed.conv2ID, "agent", seed.agentID)
	insertDelivery(t, db, conv2Msg, seed.userAID, "user", nil)

	// 标 msg3 已读(msgIDs[2])→ 剩 msg1/msg2 未读
	tx = beginTx(t, db)
	if _, err := dRepo.MarkReadBatchTx(t.Context(), tx, msgIDs[2:], seed.userAID, "user"); err != nil {
		t.Fatalf("MarkReadBatchTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// 1. ListUnreadMessageIDsByConv(conv1, user_a) 应返 {msg1, msg2}(顺序按 INSERT 顺序)
	tx = beginTx(t, db)
	got, err := dRepo.ListUnreadMessageIDsByConv(t.Context(), tx, seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("ListUnreadMessageIDsByConv 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("返 slice 长度错误: 期望 2, 实际 %d (%v)", len(got), got)
	}
	// 校验集合等于 {msg1, msg2}(SQL 无 ORDER BY,只校验集合)
	gotSet := map[string]bool{got[0]: true, got[1]: true}
	if !gotSet[msgIDs[0]] || !gotSet[msgIDs[1]] {
		t.Errorf("返 message_id 集合错误: 期望 {%s, %s}, 实际 %v", msgIDs[0], msgIDs[1], got)
	}

	// 2. 软删 msg1 → 应只返 msg2(JOIN messages 过滤 deleted_at)
	if _, err := db.Exec(`UPDATE messages SET deleted_at = NOW() WHERE id = $1`, msgIDs[0]); err != nil {
		t.Fatalf("软删 msg1 失败: %v", err)
	}
	tx = beginTx(t, db)
	got, err = dRepo.ListUnreadMessageIDsByConv(t.Context(), tx, seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("软删后 ListUnreadMessageIDsByConv 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
	if len(got) != 1 || got[0] != msgIDs[1] {
		t.Errorf("软删后返错误: 期望 [%s], 实际 %v", msgIDs[1], got)
	}

	// 3. 越权:user_b 在 conv1 无 delivery → 返空 slice 不报错
	tx = beginTx(t, db)
	gotB, err := dRepo.ListUnreadMessageIDsByConv(t.Context(), tx, seed.convID, seed.userBID, "user")
	if err != nil {
		t.Errorf("user_b 调用报错: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
	if len(gotB) != 0 {
		t.Errorf("越权返非空: 期望 [], 实际 %v", gotB)
	}

	// 4. 全部标已读 → 返空 slice
	tx = beginTx(t, db)
	if _, err := dRepo.MarkReadBatchTx(t.Context(), tx, msgIDs[1:2], seed.userAID, "user"); err != nil {
		t.Fatalf("MarkReadBatchTx msg2 失败: %v", err)
	}
	got, err = dRepo.ListUnreadMessageIDsByConv(t.Context(), tx, seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("全部已读后 ListUnreadMessageIDsByConv 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("全部已读后返非空: 期望 [], 实际 %v", got)
	}
}

// TestDeliveryRepo_NoParticipantsEdgeCase 验证无 recipient 时的边界:
//   - FirstUnread 对无 delivery 的 recipient 返 nil 不报错
func TestDeliveryRepo_NoParticipantsEdgeCase(t *testing.T) {
	db, _, seed := seedParticipantsTestDB(t)
	dRepo := NewDeliveryRepo(db)

	// 一个未加入任何 participant 的 fake user
	fakeUserID := "00000000-0000-0000-0000-000000000099"

	// FirstUnread 对无 delivery 的 recipient 应返 (nil, nil)
	m, err := dRepo.FirstUnread(t.Context(), seed.convID, fakeUserID, "user")
	if err != nil {
		t.Errorf("FirstUnread 无 delivery 报错: %v", err)
	}
	if m != nil {
		t.Errorf("FirstUnread 无 delivery 应返 nil, 实际 %+v", m)
	}
}

// TestDeliveryRepo_FirstUnread_ApprovalCardVisible 验证:子 agent 审批卡
// (permission_card,带 parent/root,未读)豁免 FirstUnread 过滤(is_main_stream),
// 成为未读锚点。对比 FilterChildMessages:普通子事件仍被排除。
func TestDeliveryRepo_FirstUnread_ApprovalCardVisible(t *testing.T) {
	db, pRepo, seed := seedParticipantsTestDB(t)
	dRepo := NewDeliveryRepo(db)
	mRepo := NewMessageRepo(db)

	tx := beginTx(t, db)
	if err := pRepo.AddParticipantsTx(t.Context(), tx, seed.convID, []ParticipantInput{
		{MemberID: seed.userAID, MemberType: "user", Role: "owner"},
	}); err != nil {
		t.Fatalf("AddParticipants 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// rootMsg:顶层消息(parent=NULL),已读
	rootID := insertMessage(t, db, seed.convID, "agent", seed.agentID)
	insertDelivery(t, db, rootID, seed.userAID, "user", nil)
	time.Sleep(2 * time.Millisecond)

	// 子 agent 审批卡(parent=root, root=root,未读):应作未读锚点
	permContent, _ := json.Marshal(map[string]interface{}{
		"msg_type": "permission_card",
		"data":     map[string]interface{}{"status": "pending"},
	})
	permMsg, err := mRepo.CreateWithParent(t.Context(), seed.convID, "agent", seed.agentID, permContent, rootID, rootID)
	if err != nil {
		t.Fatalf("CreateWithParent 审批卡失败: %v", err)
	}
	insertDelivery(t, db, permMsg.ID, seed.userAID, "user", nil)

	// 标 rootID 已读,剩下未读:permMsg
	tx = beginTx(t, db)
	if _, err := dRepo.MarkReadBatchTx(t.Context(), tx, []string{rootID}, seed.userAID, "user"); err != nil {
		t.Fatalf("MarkReadBatchTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("commit 失败: %v", err)
	}

	// FirstUnread 应返回 permMsg(审批卡豁免过滤),而非 nil
	m, err := dRepo.FirstUnread(t.Context(), seed.convID, seed.userAID, "user")
	if err != nil {
		t.Fatalf("FirstUnread 失败: %v", err)
	}
	if m == nil {
		t.Fatalf("FirstUnread 返 nil, 期望审批卡 %s", permMsg.ID)
	}
	if m.ID != permMsg.ID {
		t.Errorf("FirstUnread 应返回审批卡 %s, 实际 %s", permMsg.ID, m.ID)
	}
}
