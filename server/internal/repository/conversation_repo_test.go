package repository

import (
	"database/sql"
	"encoding/json"
	"testing"
	"time"

	"github.com/wanling/server/internal/model"
)

// === 测试 fixture ===
//
// participants 模型重构后,本测试包所有测试在新 schema(015 已应用)上跑。
// seedConvFixture 起 DB + seed 1 user + 1 agent(归属该 user),供多个测试复用。
type convTestSeed struct {
	userID  string
	agentID string
}

func seedConvFixture(t *testing.T, db *sql.DB) convTestSeed {
	t.Helper()
	now := time.Now().UTC().Truncate(time.Microsecond)
	var s convTestSeed
	if err := db.QueryRow(`
		INSERT INTO users (username, password_hash, avatar_url, created_at)
		VALUES ($1, $2, '', $3) RETURNING id
	`, uniqueShortName(t, "u_"), "hash", now).Scan(&s.userID); err != nil {
		t.Fatalf("seed user 失败: %v", err)
	}
	if err := db.QueryRow(`
		INSERT INTO agents (owner_id, name, avatar_url, secret_key, status, created_at)
		VALUES ($1, $2, '', $3, 'offline', $4) RETURNING id
	`, s.userID, "Agent", "sk-conv-test", now).Scan(&s.agentID); err != nil {
		t.Fatalf("seed agent 失败: %v", err)
	}
	return s
}

// insertConvDirect 用裸 SQL 插一条 conversation(默认 type=dm_user_agent),
// 供测试构造 seed 数据用(绕过 repo 方法,避免循环依赖)。
func insertConvDirect(t *testing.T, db *sql.DB, lastMsgAt time.Time) string {
	t.Helper()
	var id string
	if err := db.QueryRow(`
		INSERT INTO conversations (last_message_at, created_at) VALUES ($1, $1) RETURNING id
	`, lastMsgAt).Scan(&id); err != nil {
		t.Fatalf("insert conversation 失败: %v", err)
	}
	return id
}

// === GetByID 测试 ===

// TestConversationRepo_GetByID_NullLastMessageContent 验证新建会话时
// last_message_content 应为 NULL(NullJSON.Valid=false)。
// 这是 scan NULL JSONB 的关键回归保护:不能 panic、不能报错。
// 直接用 json.RawMessage 会触发 "unsupported Scan, storing driver.Value type <nil>"。
func TestConversationRepo_GetByID_NullLastMessageContent(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seed := seedConvFixture(t, db)

	convID := insertConvDirect(t, db, time.Now().UTC())
	// 用裸 SQL 把 last_message_at 设过去时间,避免 NOW() 与 last_message_content 不同步
	// (这只是 seed,不写 last_message_content 即 NULL)

	got, err := repo.GetByID(convID)
	if err != nil {
		t.Fatalf("GetByID 失败: %v", err)
	}
	if got == nil {
		t.Fatalf("GetByID 返回 nil")
	}
	if got.LastMessageContent.Valid {
		t.Errorf("新会话 last_message_content 应为 NULL(Valid=false), 实际 Valid=true, Raw=%s",
			got.LastMessageContent.RawMessage)
	}
	if got.Type != "dm_user_agent" {
		t.Errorf("默认 type 错误: 期望 dm_user_agent, 实际 %s", got.Type)
	}
	_ = seed // 此用例不需要 user/agent,但保留 fixture 让 schema 初始化一致
}

// TestNullJSON_JSONSerialization 校验 NullJSON 的 JSON 序列化行为符合预期:
//   - NULL → 输出 "null";
//   - 非 NULL → 透传 JSON 内容。
// 避免 handler 层因 JSON 输出格式变化踩坑。
func TestNullJSON_JSONSerialization(t *testing.T) {
	// Valid=false → null
	n := model.NullJSON{}
	out, err := json.Marshal(struct {
		X model.NullJSON `json:"x"`
	}{X: n})
	if err != nil {
		t.Fatalf("Marshal 失败: %v", err)
	}
	if string(out) != `{"x":null}` {
		t.Errorf("NULL 序列化异常: %s (期望 {\"x\":null})", string(out))
	}

	// Valid=true → 透传
	n.Valid = true
	n.RawMessage = json.RawMessage(`{"a":1}`)
	out, err = json.Marshal(struct {
		X model.NullJSON `json:"x"`
	}{X: n})
	if err != nil {
		t.Fatalf("Marshal 失败: %v", err)
	}
	if string(out) != `{"x":{"a":1}}` {
		t.Errorf("非 NULL 序列化异常: %s", string(out))
	}
}

// === UpdateLastMessage / ClearLastMessage / UpdateLastMessageTx 测试 ===

// TestConversationRepo_UpdateLastMessage_WritesCache 验证 UpdateLastMessage:
// 写入后 GetByID 应能读出 LastMessageContent.Valid=true 且内容正确。
func TestConversationRepo_UpdateLastMessage_WritesCache(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seedConvFixture(t, db)
	convID := insertConvDirect(t, db, time.Now().UTC())

	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "cached"},
	})
	if err := repo.UpdateLastMessage(convID, content); err != nil {
		t.Fatalf("UpdateLastMessage 失败: %v", err)
	}

	got, err := repo.GetByID(convID)
	if err != nil || got == nil {
		t.Fatalf("GetByID: %v %v", got, err)
	}
	if !got.LastMessageContent.Valid {
		t.Fatalf("UpdateLastMessage 后 LastMessageContent 应为 Valid")
	}
	var m map[string]interface{}
	if err := json.Unmarshal(got.LastMessageContent.RawMessage, &m); err != nil {
		t.Fatalf("反序列化失败: %v", err)
	}
	data, _ := m["data"].(map[string]interface{})
	if data["text"] != "cached" {
		t.Errorf("内容不匹配: %v", m)
	}
}

// TestConversationRepo_ClearLastMessage 验证 ClearLastMessage 把 last_message_content 置 NULL。
func TestConversationRepo_ClearLastMessage(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seedConvFixture(t, db)
	convID := insertConvDirect(t, db, time.Now().UTC())

	content, _ := json.Marshal(map[string]string{"k": "v"})
	if err := repo.UpdateLastMessage(convID, content); err != nil {
		t.Fatalf("UpdateLastMessage 失败: %v", err)
	}
	if err := repo.ClearLastMessage(convID); err != nil {
		t.Fatalf("ClearLastMessage 失败: %v", err)
	}
	got, _ := repo.GetByID(convID)
	if got.LastMessageContent.Valid {
		t.Errorf("ClearLastMessage 后 LastMessageContent 应为 NULL, 实际 Valid=true Raw=%s",
			got.LastMessageContent.RawMessage)
	}
}

// TestConversationRepo_UpdateLastMessageTx 验证 UpdateLastMessageTx 在外部事务中工作。
func TestConversationRepo_UpdateLastMessageTx(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seedConvFixture(t, db)
	convID := insertConvDirect(t, db, time.Now().UTC())

	content, _ := json.Marshal(map[string]string{"k": "tx"})
	tx, err := repo.BeginTx()
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	if err := repo.UpdateLastMessageTx(tx, convID, content); err != nil {
		t.Fatalf("UpdateLastMessageTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit 失败: %v", err)
	}

	got, _ := repo.GetByID(convID)
	if !got.LastMessageContent.Valid {
		t.Fatalf("UpdateLastMessageTx 后 LastMessageContent 应为 Valid")
	}
}

// === FindOrCreateDM 测试 ===

// TestConversationRepo_FindOrCreateDM_New 验证 FindOrCreateDM 新建 dm:
//   - 首次调用创建新会话 + 2 行 participants
//   - Initiator=owner, Other=member
//   - 返回的 Conversation.type = typeStr
func TestConversationRepo_FindOrCreateDM_New(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seed := seedConvFixture(t, db)

	conv, err := repo.FindOrCreateDM("dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: seed.agentID, MemberType: "agent"},
	})
	if err != nil {
		t.Fatalf("FindOrCreateDM 失败: %v", err)
	}
	if conv == nil || conv.ID == "" {
		t.Fatalf("返回的 conversation 异常: %+v", conv)
	}
	if conv.Type != "dm_user_agent" {
		t.Errorf("type 错误: 期望 dm_user_agent, 实际 %s", conv.Type)
	}

	// 校验 participants 行
	pRepo := NewParticipantRepo(db)
	parts, err := pRepo.ListByConversation(conv.ID)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(parts) != 2 {
		t.Fatalf("participants 行数错误: 期望 2, 实际 %d", len(parts))
	}
	roleOf := map[string]string{}
	for _, p := range parts {
		roleOf[p.MemberType+":"+p.MemberID] = p.Role
	}
	if roleOf["user:"+seed.userID] != "owner" {
		t.Errorf("initiator(user)role 错误: 期望 owner, 实际 %s", roleOf["user:"+seed.userID])
	}
	if roleOf["agent:"+seed.agentID] != "member" {
		t.Errorf("other(agent)role 错误: 期望 member, 实际 %s", roleOf["agent:"+seed.agentID])
	}
}

// TestConversationRepo_FindOrCreateDM_Existing 验证 FindOrCreateDM 命中已存在:
//   - 首次创建一个 dm
//   - 二次 FindOrCreateDM 同 (type, members) → 返回同一 conv, 不重复加 participants
//   - 二次 FindOrCreateDM 同 members 但 Initiator/Other 互换 → 仍返回同一 conv(member set 一致)
func TestConversationRepo_FindOrCreateDM_Existing(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seed := seedConvFixture(t, db)

	conv1, err := repo.FindOrCreateDM("dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: seed.agentID, MemberType: "agent"},
	})
	if err != nil {
		t.Fatalf("首次 FindOrCreateDM 失败: %v", err)
	}

	// 二次(同 Initiator/Other 顺序)→ 同 conv
	conv2, err := repo.FindOrCreateDM("dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: seed.agentID, MemberType: "agent"},
	})
	if err != nil {
		t.Fatalf("二次 FindOrCreateDM 失败: %v", err)
	}
	if conv1.ID != conv2.ID {
		t.Errorf("二次应返回同 conv, conv1=%s conv2=%s", conv1.ID, conv2.ID)
	}

	// 三次(Initiator/Other 互换)→ 仍同 conv(member set 一致)
	conv3, err := repo.FindOrCreateDM("dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.agentID, MemberType: "agent"},
		Other:     ParticipantInput{MemberID: seed.userID, MemberType: "user"},
	})
	if err != nil {
		t.Fatalf("三次 FindOrCreateDM 失败: %v", err)
	}
	if conv1.ID != conv3.ID {
		t.Errorf("members 互换应返回同 conv, conv1=%s conv3=%s", conv1.ID, conv3.ID)
	}

	// 校验 participants 行只有 2 行(没重复加)
	pRepo := NewParticipantRepo(db)
	parts, _ := pRepo.ListByConversation(conv1.ID)
	if len(parts) != 2 {
		t.Errorf("重复 FindOrCreateDM 后 participants 行数错误: 期望 2, 实际 %d", len(parts))
	}
}

// === CreateTx 测试 ===

// TestConversationRepo_CreateTx 验证 CreateTx 只 INSERT conversations 不加 participants。
// 群聊场景由 handler 调 CreateTx + AddParticipantsTx 协作。
func TestConversationRepo_CreateTx(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seedConvFixture(t, db)

	tx, err := repo.BeginTx()
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	conv, err := repo.CreateTx(tx, "group_user", "群名", "/avatar.png")
	if err != nil {
		t.Fatalf("CreateTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit 失败: %v", err)
	}
	if conv.Type != "group_user" {
		t.Errorf("type 错误: 期望 group_user, 实际 %s", conv.Type)
	}
	if conv.Title != "群名" {
		t.Errorf("title 错误: %s", conv.Title)
	}
	if conv.AvatarURL != "/avatar.png" {
		t.Errorf("avatar_url 错误: %s", conv.AvatarURL)
	}

	// 校验 participants 表无此 conv 的行(由 handler 调 AddParticipantsTx 加)
	pRepo := NewParticipantRepo(db)
	parts, err := pRepo.ListByConversation(conv.ID)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(parts) != 0 {
		t.Errorf("CreateTx 不应自动加 participants, 实际 %d 行", len(parts))
	}
}

// === UpdateProfile 测试 ===

// TestConversationRepo_UpdateProfile 验证群名/群头像更新。
// COALESCE(NULLIF) 模式: 空串=不动。
func TestConversationRepo_UpdateProfile(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seedConvFixture(t, db)

	tx, _ := repo.BeginTx()
	conv, _ := repo.CreateTx(tx, "group_user", "旧名", "/old.png")
	tx.Commit()

	// 改 title 不传 avatarURL(空串不动)
	if err := repo.UpdateProfile(conv.ID, "新名", ""); err != nil {
		t.Fatalf("UpdateProfile 失败: %v", err)
	}
	got, _ := repo.GetByID(conv.ID)
	if got.Title != "新名" {
		t.Errorf("title 应更新为 新名, 实际 %s", got.Title)
	}
	if got.AvatarURL != "/old.png" {
		t.Errorf("avatar_url 应保持 /old.png, 实际 %s", got.AvatarURL)
	}
}

// === ListForUser 测试 ===

// TestConversationRepo_ListForUser_Basic 验证 ListForUser 的基础场景:
//   - user 有 1 个 dm_user_agent 会话(带 last_message_content)
//   - ListForUser 返回该会话,带 unread_count + Agent 摘要 + 对端 Participants
//   - hidden_at IS NULL 的会话才返回
//   - last_message_content IS NULL 的会话不返回(IM 列表只展示有消息的)
func TestConversationRepo_ListForUser_Basic(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seed := seedConvFixture(t, db)

	conv, err := repo.FindOrCreateDM("dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: seed.agentID, MemberType: "agent"},
	})
	if err != nil {
		t.Fatalf("FindOrCreateDM 失败: %v", err)
	}
	// 写 last_message_content(没消息的会话不进列表)
	content, _ := json.Marshal(map[string]string{"k": "v"})
	if err := repo.UpdateLastMessage(conv.ID, content); err != nil {
		t.Fatalf("UpdateLastMessage 失败: %v", err)
	}

	items, err := repo.ListForUser(seed.userID)
	if err != nil {
		t.Fatalf("ListForUser 失败: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("期望 1 条, 实际 %d", len(items))
	}
	if items[0].ID != conv.ID {
		t.Errorf("conv id 不匹配: got=%s want=%s", items[0].ID, conv.ID)
	}
	if items[0].Type != "dm_user_agent" {
		t.Errorf("type 错误: %s", items[0].Type)
	}
	if items[0].UnreadCount != 0 {
		t.Errorf("初始 unread_count 应为 0, 实际 %d", items[0].UnreadCount)
	}
	// dm_user_agent 应填 Agent 摘要
	if items[0].Agent == nil {
		t.Errorf("dm_user_agent 应填 Agent 摘要, 实际 nil")
	} else {
		if items[0].Agent.ID != seed.agentID {
			t.Errorf("agent.id 不匹配: got=%s want=%s", items[0].Agent.ID, seed.agentID)
		}
		if items[0].Agent.Name != "Agent" {
			t.Errorf("agent.name 不匹配: %s", items[0].Agent.Name)
		}
	}
}

// TestConversationRepo_ListForUser_ExcludesNoMessage 验证无消息会话不进列表。
func TestConversationRepo_ListForUser_ExcludesNoMessage(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seed := seedConvFixture(t, db)

	// 创建一个 dm 但不写 last_message_content
	if _, err := repo.FindOrCreateDM("dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: seed.agentID, MemberType: "agent"},
	}); err != nil {
		t.Fatalf("FindOrCreateDM 失败: %v", err)
	}

	items, err := repo.ListForUser(seed.userID)
	if err != nil {
		t.Fatalf("ListForUser 失败: %v", err)
	}
	if len(items) != 0 {
		t.Errorf("无消息会话不应进列表, 实际 %d 条", len(items))
	}
}

// TestConversationRepo_ListForUser_ExcludesHidden 验证用户维度隐藏的会话不进列表。
// spec §3.5:WHERE p.hidden_at IS NULL
func TestConversationRepo_ListForUser_ExcludesHidden(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	pRepo := NewParticipantRepo(db)
	seed := seedConvFixture(t, db)

	conv, _ := repo.FindOrCreateDM("dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: seed.agentID, MemberType: "agent"},
	})
	content, _ := json.Marshal(map[string]string{"k": "v"})
	if err := repo.UpdateLastMessage(conv.ID, content); err != nil {
		t.Fatalf("UpdateLastMessage 失败: %v", err)
	}

	// 用户隐藏该会话
	if err := pRepo.SetHidden(conv.ID, seed.userID, "user", true); err != nil {
		t.Fatalf("SetHidden 失败: %v", err)
	}
	items, _ := repo.ListForUser(seed.userID)
	if len(items) != 0 {
		t.Errorf("隐藏的会话不应进列表, 实际 %d 条", len(items))
	}
}

// TestConversationRepo_ListForUser_OrdersByPinnedThenLastMessageAt 验证排序:
//   - 置顶组在前(pinned_at DESC NULLS LAST)
//   - 组内按 last_message_at DESC
//
// 场景:user 有 3 个 dm:
//   - convA 早 1 小时,置顶
//   - convB 当前,未置顶
//   - convC 早 2 小时,未置顶
//
// 期望顺序:[A(置顶), B(当前), C(早 2 小时)]
func TestConversationRepo_ListForUser_OrdersByPinnedThenLastMessageAt(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	pRepo := NewParticipantRepo(db)
	seed := seedConvFixture(t, db)

	// 3 个 agent + 3 个 dm
	now := time.Now().UTC()
	makeDMAgent := func(name string) string {
		t.Helper()
		var id string
		if err := db.QueryRow(`
			INSERT INTO agents (owner_id, name, avatar_url, secret_key, status, created_at)
			VALUES ($1, $2, '', $3, 'offline', $4) RETURNING id
		`, seed.userID, name, "sk-"+name, now).Scan(&id); err != nil {
			t.Fatalf("seed agent %s 失败: %v", name, err)
		}
		return id
	}
	agentA := makeDMAgent("AgentA")
	agentB := makeDMAgent("AgentB")
	agentC := makeDMAgent("AgentC")

	convA, _ := repo.FindOrCreateDM("dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: agentA, MemberType: "agent"},
	})
	convB, _ := repo.FindOrCreateDM("dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: agentB, MemberType: "agent"},
	})
	convC, _ := repo.FindOrCreateDM("dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: agentC, MemberType: "agent"},
	})

	content, _ := json.Marshal(map[string]string{"k": "v"})
	// A: 早 1 小时 + 置顶
	if _, err := db.Exec(`UPDATE conversations SET last_message_content = $1, last_message_at = NOW() - INTERVAL '1 hour' WHERE id = $2`, content, convA.ID); err != nil {
		t.Fatalf("UPDATE A 失败: %v", err)
	}
	if err := pRepo.SetPinned(convA.ID, seed.userID, "user", true); err != nil {
		t.Fatalf("SetPinned A 失败: %v", err)
	}
	// B: 当前
	if _, err := db.Exec(`UPDATE conversations SET last_message_content = $1, last_message_at = NOW() WHERE id = $2`, content, convB.ID); err != nil {
		t.Fatalf("UPDATE B 失败: %v", err)
	}
	// C: 早 2 小时
	if _, err := db.Exec(`UPDATE conversations SET last_message_content = $1, last_message_at = NOW() - INTERVAL '2 hours' WHERE id = $2`, content, convC.ID); err != nil {
		t.Fatalf("UPDATE C 失败: %v", err)
	}

	items, err := repo.ListForUser(seed.userID)
	if err != nil {
		t.Fatalf("ListForUser 失败: %v", err)
	}
	if len(items) != 3 {
		t.Fatalf("期望 3 条, 实际 %d", len(items))
	}
	// 期望顺序:A(置顶), B(当前), C(早 2 小时)
	if items[0].ID != convA.ID {
		t.Errorf("首条期望 convA(置顶), 实际 %s", items[0].ID)
	}
	if items[1].ID != convB.ID {
		t.Errorf("第二条期望 convB(最新), 实际 %s", items[1].ID)
	}
	if items[2].ID != convC.ID {
		t.Errorf("第三条期望 convC(最早), 实际 %s", items[2].ID)
	}
	// items[0] 应有 PinnedAt 非 nil
	if items[0].PinnedAt == nil {
		t.Errorf("convA 的 PinnedAt 应非 nil(已置顶)")
	}
}

// === BatchLoadParticipantSummaries 测试 ===

// TestConversationRepo_BatchLoadParticipantSummaries 验证批量加载 participant 摘要:
//   - 2 个 conv,各 2 个 participant(user + agent)
//   - BatchLoadParticipantSummaries 返回 map[convID] -> []ParticipantSummary
//   - 每个 summary 含 username/nickname/avatar_url 字段正确
//   - user 的 nickname 取 COALESCE(nickname, username)
//   - agent 的 nickname 取 name
func TestConversationRepo_BatchLoadParticipantSummaries(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seed := seedConvFixture(t, db)

	// 给 user 设 nickname
	nick := "用户A"
	if _, err := db.Exec(`UPDATE users SET nickname = $1 WHERE id = $2`, nick, seed.userID); err != nil {
		t.Fatalf("set nickname 失败: %v", err)
	}

	conv1, _ := repo.FindOrCreateDM("dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: seed.agentID, MemberType: "agent"},
	})

	// 第二个 dm(用第二个 agent)
	var agent2ID string
	if err := db.QueryRow(`
		INSERT INTO agents (owner_id, name, avatar_url, secret_key, status, created_at)
		VALUES ($1, 'AgentB', '', 'sk-b', 'offline', NOW()) RETURNING id
	`, seed.userID).Scan(&agent2ID); err != nil {
		t.Fatalf("seed agent B 失败: %v", err)
	}
	conv2, _ := repo.FindOrCreateDM("dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: agent2ID, MemberType: "agent"},
	})

	result, err := repo.BatchLoadParticipantSummaries([]string{conv1.ID, conv2.ID})
	if err != nil {
		t.Fatalf("BatchLoadParticipantSummaries 失败: %v", err)
	}
	if len(result) != 2 {
		t.Fatalf("result map 大小错误: 期望 2, 实际 %d", len(result))
	}
	parts1, ok := result[conv1.ID]
	if !ok {
		t.Fatalf("缺 conv1 的 participants")
	}
	if len(parts1) != 2 {
		t.Fatalf("conv1 participants 行数错误: 期望 2, 实际 %d", len(parts1))
	}
	// 按 member_type 找出 user/agent
	var userPS, agentPS *model.ParticipantSummary
	for i := range parts1 {
		if parts1[i].MemberType == "user" {
			userPS = &parts1[i]
		} else if parts1[i].MemberType == "agent" {
			agentPS = &parts1[i]
		}
	}
	if userPS == nil || agentPS == nil {
		t.Fatalf("conv1 应有 user + agent participant, 实际 %+v", parts1)
	}
	// user 的 nickname = "用户A"(COALESCE 取 nickname)
	if userPS.Nickname != nick {
		t.Errorf("user nickname 错误: 期望 %s, 实际 %s", nick, userPS.Nickname)
	}
	if userPS.Role != "owner" {
		t.Errorf("user role 错误: 期望 owner, 实际 %s", userPS.Role)
	}
	// agent 的 nickname = name("Agent")
	if agentPS.Nickname != "Agent" {
		t.Errorf("agent nickname 错误: 期望 Agent, 实际 %s", agentPS.Nickname)
	}
	if agentPS.Role != "member" {
		t.Errorf("agent role 错误: 期望 member, 实际 %s", agentPS.Role)
	}
}

// TestConversationRepo_BatchLoadParticipantSummaries_EmptyInput 验证空 convIDs 不报错返空 map。
func TestConversationRepo_BatchLoadParticipantSummaries_EmptyInput(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seedConvFixture(t, db)

	result, err := repo.BatchLoadParticipantSummaries(nil)
	if err != nil {
		t.Fatalf("空 input 不应报错: %v", err)
	}
	if len(result) != 0 {
		t.Errorf("空 input 应返空 map, 实际 %d 个 key", len(result))
	}
}

// === 越权 / 不存在场景 ===

// TestConversationRepo_GetByID_NotExists 验证 GetByID 不存在返 (nil, nil)。
func TestConversationRepo_GetByID_NotExists(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seedConvFixture(t, db)

	got, err := repo.GetByID("00000000-0000-0000-0000-000000000001")
	if err != nil {
		t.Fatalf("GetByID 不存在应返 nil err, 实际 %v", err)
	}
	if got != nil {
		t.Errorf("不存在应返 nil, 实际 %+v", got)
	}
}

// TestConversationRepo_ListForUser_NoConv 验证 user 没参与任何会话时返空切片。
func TestConversationRepo_ListForUser_NoConv(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seed := seedConvFixture(t, db)

	items, err := repo.ListForUser(seed.userID)
	if err != nil {
		t.Fatalf("ListForUser 失败: %v", err)
	}
	if len(items) != 0 {
		t.Errorf("无会话 user 应返空切片, 实际 %d 条", len(items))
	}
}
