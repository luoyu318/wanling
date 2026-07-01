package repository

import (
	"database/sql"
	"testing"
	"time"
)

// migration015Path / ExecMigration015 已抽到 testhelpers_test.go 作为公共 helper,
// 让其他 repo 测试(participants/deliveries/friendship)共用,避免每个测试文件 copy 一份。

// columnExists 查 information_schema.columns 判断列是否存在。
func columnExists(t *testing.T, db *sql.DB, table, column string) bool {
	t.Helper()
	var n int
	err := db.QueryRow(`
		SELECT COUNT(*) FROM information_schema.columns
		WHERE table_schema = 'public' AND table_name = $1 AND column_name = $2
	`, table, column).Scan(&n)
	if err != nil {
		t.Fatalf("查 information_schema.columns 失败 (%s.%s): %v", table, column, err)
	}
	return n > 0
}

// indexExists 查 pg_indexes 判断索引是否存在。
func indexExists(t *testing.T, db *sql.DB, indexName string) bool {
	t.Helper()
	var n int
	err := db.QueryRow(`
		SELECT COUNT(*) FROM pg_indexes
		WHERE schemaname = 'public' AND indexname = $1
	`, indexName).Scan(&n)
	if err != nil {
		t.Fatalf("查 pg_indexes 失败 (%s): %v", indexName, err)
	}
	return n > 0
}

// TestMigration015_ParticipantsBackfill 验证 migration 015 跑完后,老数据正确转为新 schema:
//   - 老 conversations.user_id/agent_id → participants 行(user=owner, agent=member)
//   - 老 messages.is_read → deliveries 行(TRUE→read_at, FALSE→NULL)
//   - unread_count 字段下沉到 participants
//   - hidden_at/pinned_at 下沉到 participants
//   - 老字段/索引被 DROP
//
// 测试分阶段执行:
//  1. SetupTestDBSkipping015 跑 001-014(015 不跑,保留老 schema)
//  2. seed 老格式数据:user / agent / conversation(user_id+agent_id+unread_count+hidden_at+pinned_at) /
//     messages(混合 is_read TRUE/FALSE,sender 是 user/agent 各若干)
//  3. 手动执行 015 SQL
//  4. 校验新 schema 数据正确
//
// 见 docs/superpowers/specs/2026-07-02-participants-model-refactor-design.md §2 详细回填逻辑
func TestMigration015_ParticipantsBackfill(t *testing.T) {
	db := SetupTestDBSkipping015(t) // testcontainers 起 PG,跑 001-014(015 被显式跳过)

	// === 1. seed 老格式数据 ===

	var (
		userID            string
		agentID           string
		agentOwnerID      string // agent.owner_id 必须 = user.id(001 表结构约束)
		convID            string
		agentMsgUnreadID  string // is_read=FALSE 的 agent 消息(应被记为 user 未读)
		agentMsgReadID    string // is_read=TRUE 的 agent 消息
		userMsgID         string // user 自发消息(is_read=TRUE,不参与未读)
		agentMsgDeletedID string // 软删的 agent 未读消息(deleted_at 不为 NULL,不应生成 delivery)
	)
	now := time.Now().UTC().Truncate(time.Microsecond)

	// 1.1 user
	if err := db.QueryRow(`
		INSERT INTO users (username, password_hash, avatar_url, created_at)
		VALUES ($1, $2, '', $3) RETURNING id
	`, "m015_user", "hash", now).Scan(&userID); err != nil {
		t.Fatalf("seed user 失败: %v", err)
	}
	agentOwnerID = userID

	// 1.2 agent(owner_id = user.id)
	if err := db.QueryRow(`
		INSERT INTO agents (owner_id, name, avatar_url, secret_key, status, created_at)
		VALUES ($1, $2, '', $3, 'offline', $4) RETURNING id
	`, agentOwnerID, "M015Agent", "sk-test-m015", now).Scan(&agentID); err != nil {
		t.Fatalf("seed agent 失败: %v", err)
	}

	// 1.3 conversation(老格式:user_id + agent_id + unread_count + hidden_at + pinned_at)
	hiddenAt := now.Add(-2 * time.Hour)
	pinnedAt := now.Add(-1 * time.Hour)
	if err := db.QueryRow(`
		INSERT INTO conversations (user_id, agent_id, last_message_at, created_at, unread_count, hidden_at, pinned_at)
		VALUES ($1, $2, $3, $3, 0, $4, $5) RETURNING id
	`, userID, agentID, now, hiddenAt, pinnedAt).Scan(&convID); err != nil {
		t.Fatalf("seed conversation 失败: %v", err)
	}

	// 1.4 messages:4 条
	//  - agent 发,is_read=FALSE(应生成 delivery 给 user,read_at=NULL,参与未读计数)
	//  - agent 发,is_read=TRUE (应生成 delivery 给 user,read_at=created_at,不参与未读计数)
	//  - user 发,is_read=TRUE (按 014 语义 user 自发一律 TRUE;应生成 delivery 给 agent,read_at=created_at)
	//  - agent 发,is_read=FALSE,deleted_at 不为 NULL(软删,不应生成 delivery,不污染未读)
	content := `{"msg_type":"text","data":{"text":"hi"}}`
	if err := db.QueryRow(`
		INSERT INTO messages (conversation_id, sender_type, sender_id, content, is_read, created_at)
		VALUES ($1, 'agent', $2, $3::jsonb, FALSE, $4) RETURNING id
	`, convID, agentID, content, now).Scan(&agentMsgUnreadID); err != nil {
		t.Fatalf("seed agent unread msg 失败: %v", err)
	}
	if err := db.QueryRow(`
		INSERT INTO messages (conversation_id, sender_type, sender_id, content, is_read, created_at)
		VALUES ($1, 'agent', $2, $3::jsonb, TRUE, $4) RETURNING id
	`, convID, agentID, content, now).Scan(&agentMsgReadID); err != nil {
		t.Fatalf("seed agent read msg 失败: %v", err)
	}
	if err := db.QueryRow(`
		INSERT INTO messages (conversation_id, sender_type, sender_id, content, is_read, created_at)
		VALUES ($1, 'user', $2, $3::jsonb, TRUE, $4) RETURNING id
	`, convID, userID, content, now).Scan(&userMsgID); err != nil {
		t.Fatalf("seed user msg 失败: %v", err)
	}
	// 第四条:软删的 agent → user 未读消息(deleted_at 不为 NULL,is_read=FALSE)
	deletedAt := now.Add(-30 * time.Minute)
	if err := db.QueryRow(`
		INSERT INTO messages (conversation_id, sender_type, sender_id, content, is_read, created_at, deleted_at)
		VALUES ($1, 'agent', $2, $3::jsonb, FALSE, $4, $5) RETURNING id
	`, convID, agentID, content, now, deletedAt).Scan(&agentMsgDeletedID); err != nil {
		t.Fatalf("seed agent deleted msg 失败: %v", err)
	}

	// === 2. 手动执行 015 ===
	ExecMigration015(t, db)

	// === 3. 校验 schema:老字段/索引已 DROP,新表已建 ===

	// conversations 表的老字段都 DROP
	for _, col := range []string{"user_id", "agent_id", "unread_count", "hidden_at", "pinned_at"} {
		if columnExists(t, db, "conversations", col) {
			t.Errorf("conversations.%s 应被 DROP,但仍存在", col)
		}
	}
	// conversations 表的新字段已加
	for _, col := range []string{"title", "avatar_url", "type"} {
		if !columnExists(t, db, "conversations", col) {
			t.Errorf("conversations.%s 应已添加,但不存在", col)
		}
	}
	// messages.is_read 已 DROP
	if columnExists(t, db, "messages", "is_read") {
		t.Errorf("messages.is_read 应被 DROP,但仍存在")
	}

	// 老 partial index idx_messages_conv_unread(依赖 is_read)已 DROP
	if indexExists(t, db, "idx_messages_conv_unread") {
		t.Errorf("idx_messages_conv_unread 应被 DROP,但仍存在")
	}
	if indexExists(t, db, "idx_conversations_user_id") {
		t.Errorf("idx_conversations_user_id 应被 DROP,但仍存在")
	}
	if indexExists(t, db, "idx_conversations_agent_id") {
		t.Errorf("idx_conversations_agent_id 应被 DROP,但仍存在")
	}

	// 新表存在
	for _, tbl := range []string{"conversation_participants", "message_deliveries", "friendships"} {
		var n int
		if err := db.QueryRow(`
			SELECT COUNT(*) FROM information_schema.tables
			WHERE table_schema = 'public' AND table_name = $1
		`, tbl).Scan(&n); err != nil {
			t.Fatalf("查 information_schema.tables 失败 (%s): %v", tbl, err)
		}
		if n == 0 {
			t.Errorf("新表 %s 应已创建,但不存在", tbl)
		}
	}

	// 新查询索引 idx_conversations_last_msg_at 已建
	if !indexExists(t, db, "idx_conversations_last_msg_at") {
		t.Errorf("idx_conversations_last_msg_at 应已创建,但不存在")
	}
	if !indexExists(t, db, "idx_participants_member") {
		t.Errorf("idx_participants_member 应已创建,但不存在")
	}
	if !indexExists(t, db, "idx_deliveries_unread") {
		t.Errorf("idx_deliveries_unread 应已创建,但不存在")
	}

	// === 4. 校验 participants 回填 ===
	// 应有 2 行:user(owner)+ agent(member),且 hidden_at/pinned_at 下沉到 user 行
	type participantRow struct {
		Role          string
		MemberID      string
		MemberT       string
		Unread        int
		Hidden        sql.NullTime
		Pinned        sql.NullTime
		LastReadMsgID sql.NullString
	}
	rows, err := db.Query(`
		SELECT role, member_id, member_type, unread_count, hidden_at, pinned_at, last_read_message_id
		FROM conversation_participants WHERE conv_id = $1
		ORDER BY member_type
	`, convID)
	if err != nil {
		t.Fatalf("查 participants 失败: %v", err)
	}
	defer rows.Close()
	got := map[string]participantRow{}
	for rows.Next() {
		var r participantRow
		if err := rows.Scan(&r.Role, &r.MemberID, &r.MemberT, &r.Unread, &r.Hidden, &r.Pinned, &r.LastReadMsgID); err != nil {
			t.Fatalf("scan participant 失败: %v", err)
		}
		got[r.MemberT] = r
	}
	if rows.Err() != nil {
		t.Fatalf("iter participants 失败: %v", rows.Err())
	}
	if len(got) != 2 {
		t.Fatalf("participants 行数错误: 期望 2(user+agent), 实际 %d", len(got))
	}

	// user 应为 owner,且 hidden_at/pinned_at 从老 conversation 下沉过来
	userP, ok := got["user"]
	if !ok {
		t.Fatalf("participants 缺 user 行")
	}
	if userP.Role != "owner" {
		t.Errorf("user role 错误: 期望 owner, 实际 %s", userP.Role)
	}
	if userP.MemberID != userID {
		t.Errorf("user member_id 错误: 期望 %s, 实际 %s", userID, userP.MemberID)
	}
	if !userP.Hidden.Valid {
		t.Errorf("user.hidden_at 应下沉自老 conversation.hidden_at, 但为 NULL")
	} else if !userP.Hidden.Time.Equal(hiddenAt) {
		t.Errorf("user.hidden_at 错误: 期望 %v, 实际 %v", hiddenAt, userP.Hidden.Time)
	}
	if !userP.Pinned.Valid {
		t.Errorf("user.pinned_at 应下沉自老 conversation.pinned_at, 但为 NULL")
	} else if !userP.Pinned.Time.Equal(pinnedAt) {
		t.Errorf("user.pinned_at 错误: 期望 %v, 实际 %v", pinnedAt, userP.Pinned.Time)
	}
	// last_read_message_id 本期不回填,留 NULL(spec §1.1)
	if userP.LastReadMsgID.Valid {
		t.Errorf("user last_read_message_id 应为 NULL, 实际 %v", userP.LastReadMsgID.String)
	}

	// agent 应为 member,hidden_at/pinned_at 为 NULL(没下沉 agent)
	agentP, ok := got["agent"]
	if !ok {
		t.Fatalf("participants 缺 agent 行")
	}
	if agentP.Role != "member" {
		t.Errorf("agent role 错误: 期望 member, 实际 %s", agentP.Role)
	}
	if agentP.MemberID != agentID {
		t.Errorf("agent member_id 错误: 期望 %s, 实际 %s", agentID, agentP.MemberID)
	}
	if agentP.Hidden.Valid || agentP.Pinned.Valid {
		t.Errorf("agent hidden_at/pinned_at 应为 NULL, 实际 hidden=%v pinned=%v",
			agentP.Hidden, agentP.Pinned)
	}
	// last_read_message_id 本期不回填,留 NULL(spec §1.1)
	if agentP.LastReadMsgID.Valid {
		t.Errorf("agent last_read_message_id 应为 NULL, 实际 %v", agentP.LastReadMsgID.String)
	}

	// === 5. 校验 deliveries 回填 ===
	// 应有 3 行(每条未软删消息给 non-sender 一个 delivery):
	//  - agentMsgUnread → delivery 给 user, read_at=NULL
	//  - agentMsgRead   → delivery 给 user, read_at=created_at
	//  - userMsg        → delivery 给 agent, read_at=created_at
	//  - agentMsgDeleted(软删) → 不应生成 delivery
	type deliveryRow struct {
		RecipientID string
		RecipientT  string
		ReadAt      sql.NullTime
	}
	dRows, err := db.Query(`
		SELECT message_id, recipient_id, recipient_type, read_at
		FROM message_deliveries
		WHERE message_id IN ($1, $2, $3)
	`, agentMsgUnreadID, agentMsgReadID, userMsgID)
	if err != nil {
		t.Fatalf("查 deliveries 失败: %v", err)
	}
	defer dRows.Close()
	deliveries := map[string]deliveryRow{} // key = message_id
	for dRows.Next() {
		var (
			r   deliveryRow
			mid string
		)
		if err := dRows.Scan(&mid, &r.RecipientID, &r.RecipientT, &r.ReadAt); err != nil {
			t.Fatalf("scan delivery 失败: %v", err)
		}
		deliveries[mid] = r
	}
	if dRows.Err() != nil {
		t.Fatalf("iter deliveries 失败: %v", dRows.Err())
	}
	if len(deliveries) != 3 {
		t.Fatalf("deliveries 行数错误: 期望 3, 实际 %d (map=%v)", len(deliveries), deliveries)
	}

	// agentMsgUnread → user, read_at NULL
	d, ok := deliveries[agentMsgUnreadID]
	if !ok {
		t.Fatalf("缺 agentMsgUnread 的 delivery")
	}
	if d.RecipientID != userID || d.RecipientT != "user" {
		t.Errorf("agentMsgUnread delivery recipient 错误: 期望 user/%s, 实际 %s/%s",
			userID, d.RecipientT, d.RecipientID)
	}
	if d.ReadAt.Valid {
		t.Errorf("agentMsgUnread delivery read_at 应为 NULL(未读), 实际 %v", d.ReadAt.Time)
	}

	// agentMsgRead → user, read_at = msg.created_at
	d, ok = deliveries[agentMsgReadID]
	if !ok {
		t.Fatalf("缺 agentMsgRead 的 delivery")
	}
	if d.RecipientID != userID || d.RecipientT != "user" {
		t.Errorf("agentMsgRead delivery recipient 错误: 期望 user/%s, 实际 %s/%s",
			userID, d.RecipientT, d.RecipientID)
	}
	if !d.ReadAt.Valid {
		t.Errorf("agentMsgRead delivery read_at 应为 created_at(已读), 但为 NULL")
	}

	// userMsg → agent, read_at = msg.created_at(user 自发按 014 是 TRUE,delivery 给 agent 已读)
	d, ok = deliveries[userMsgID]
	if !ok {
		t.Fatalf("缺 userMsg 的 delivery")
	}
	if d.RecipientID != agentID || d.RecipientT != "agent" {
		t.Errorf("userMsg delivery recipient 错误: 期望 agent/%s, 实际 %s/%s",
			agentID, d.RecipientT, d.RecipientID)
	}
	if !d.ReadAt.Valid {
		t.Errorf("userMsg delivery read_at 应为 created_at(已读), 但为 NULL")
	}

	// agentMsgDeleted(软删的 agent 未读消息) → 不应生成 delivery(避免污染 unread_count)
	var deletedDeliveryCount int
	if err := db.QueryRow(`
		SELECT COUNT(*) FROM message_deliveries WHERE message_id = $1
	`, agentMsgDeletedID).Scan(&deletedDeliveryCount); err != nil {
		t.Fatalf("查 agentMsgDeleted 的 delivery 失败: %v", err)
	}
	if deletedDeliveryCount != 0 {
		t.Errorf("软删消息不应生成 delivery, 实际 %d 行", deletedDeliveryCount)
	}

	// === 6. 校验 unread_count 回填 ===
	// user 的 unread_count:只有 agentMsgUnread 一条 read_at=NULL 的 delivery,期望 1
	if userP.Unread != 1 {
		t.Errorf("user unread_count 错误: 期望 1, 实际 %d", userP.Unread)
	}
	// agent 的 unread_count:userMsg 是 read_at=created_at(已读),agent 没有未读,期望 0
	if agentP.Unread != 0 {
		t.Errorf("agent unread_count 错误: 期望 0, 实际 %d", agentP.Unread)
	}

	// === 7. 校验 conversation.type 默认值 dm_user_agent ===
	var convType string
	if err := db.QueryRow(`SELECT type FROM conversations WHERE id = $1`, convID).Scan(&convType); err != nil {
		t.Fatalf("查 conversation.type 失败: %v", err)
	}
	if convType != "dm_user_agent" {
		t.Errorf("conversation.type 默认值错误: 期望 dm_user_agent, 实际 %s", convType)
	}
}

// TestMigration015_BackfillEmptyDB 验证空库(无 conversation / message)下跑 015 不报错。
// 这是部署到全新环境的回归保护:回填 SQL 用 LEFT/JOIN 时不能因无数据 NPE。
func TestMigration015_BackfillEmptyDB(t *testing.T) {
	db := SetupTestDBSkipping015(t)

	// 不 seed 任何数据,直接跑 015
	ExecMigration015(t, db)

	// 校验:三新表为空但存在,participants/deliveries/unread_count 都为 0
	for _, q := range []struct {
		table string
	}{
		{"conversation_participants"},
		{"message_deliveries"},
		{"friendships"},
	} {
		var n int
		if err := db.QueryRow("SELECT COUNT(*) FROM " + q.table).Scan(&n); err != nil {
			t.Fatalf("查 %s 行数失败: %v", q.table, err)
		}
		if n != 0 {
			t.Errorf("%s 应为空(无老数据回填), 实际 %d 行", q.table, n)
		}
	}
}
