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
		INSERT INTO agents (owner_id, name, avatar_url, secret_key, created_at)
		VALUES ($1, $2, '', $3, $4) RETURNING id
	`, s.userID, "Agent", "sk-conv-test", now).Scan(&s.agentID); err != nil {
		t.Fatalf("seed agent 失败: %v", err)
	}
	return s
}

// insertConvDirect 用裸 SQL 插一条 conversation(默认 type=dm_user_agent),
// 供测试构造 seed 数据用(绕过 repo 方法,避免循环依赖)。
func insertConvDirect(t *testing.T, db *sql.DB) string {
	t.Helper()
	var id string
	if err := db.QueryRow(`
		INSERT INTO conversations (created_at) VALUES ($1) RETURNING id
	`, time.Now().UTC()).Scan(&id); err != nil {
		t.Fatalf("insert conversation 失败: %v", err)
	}
	return id
}

// === GetByID 测试 ===

// TestConversationRepo_GetByID_NewConv 验证新建会话 GetByID 返回基本字段正确。
// 017 删 last_message_content/last_message_at 缓存字段后,Conversation 模型
// 不再有这俩字段,本测试简化为只校验 type 默认值。
func TestConversationRepo_GetByID_NewConv(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seed := seedConvFixture(t, db)

	convID := insertConvDirect(t, db)

	got, err := repo.GetByID(t.Context(), convID)
	if err != nil {
		t.Fatalf("GetByID 失败: %v", err)
	}
	if got == nil {
		t.Fatalf("GetByID 返回 nil")
	}
	if got.Type != "dm_user_agent" {
		t.Errorf("默认 type 错误: 期望 dm_user_agent, 实际 %s", got.Type)
	}
	_ = seed
}

// TestNullJSON_JSONSerialization 校验 NullJSON 的 JSON 序列化行为符合预期:
//   - NULL → 输出 "null";
//   - 非 NULL → 透传 JSON 内容。
//
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

// === FindOrCreateDM 测试 ===

// TestConversationRepo_FindOrCreateDM_New 验证 FindOrCreateDM 新建 dm:
//   - 首次调用创建新会话 + 2 行 participants
//   - Initiator=owner, Other=member
//   - 返回的 Conversation.type = typeStr
func TestConversationRepo_FindOrCreateDM_New(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seed := seedConvFixture(t, db)

	conv, err := repo.FindOrCreateDM(t.Context(), "dm_user_agent", DMMembers{
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
	parts, err := pRepo.ListByConversation(t.Context(), conv.ID)
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

	conv1, err := repo.FindOrCreateDM(t.Context(), "dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: seed.agentID, MemberType: "agent"},
	})
	if err != nil {
		t.Fatalf("首次 FindOrCreateDM 失败: %v", err)
	}

	// 二次(同 Initiator/Other 顺序)→ 同 conv
	conv2, err := repo.FindOrCreateDM(t.Context(), "dm_user_agent", DMMembers{
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
	conv3, err := repo.FindOrCreateDM(t.Context(), "dm_user_agent", DMMembers{
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
	parts, _ := pRepo.ListByConversation(t.Context(), conv1.ID)
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

	tx, err := repo.BeginTx(t.Context())
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	conv, err := repo.CreateTx(t.Context(), tx, "group_user", "群名", "/avatar.png")
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
	parts, err := pRepo.ListByConversation(t.Context(), conv.ID)
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

	tx, _ := repo.BeginTx(t.Context())
	conv, _ := repo.CreateTx(t.Context(), tx, "group_user", "旧名", "/old.png")
	tx.Commit()

	// 改 title 不传 avatarURL(空串不动)
	if err := repo.UpdateProfile(t.Context(), conv.ID, "新名", ""); err != nil {
		t.Fatalf("UpdateProfile 失败: %v", err)
	}
	got, _ := repo.GetByID(t.Context(), conv.ID)
	if got.Title != "新名" {
		t.Errorf("title 应更新为 新名, 实际 %s", got.Title)
	}
	if got.AvatarURL != "/old.png" {
		t.Errorf("avatar_url 应保持 /old.png, 实际 %s", got.AvatarURL)
	}
}

// === ListForUser 测试 ===

// TestConversationRepo_ListForUser_Basic 验证 ListForUser 的基础场景:
//   - user 有 1 个 dm_user_agent 会话(有消息)
//   - ListForUser 返回该会话,带 unread_count + Agent 摘要 + 对端 Participants
//   - hidden_at IS NULL 的会话才返回
//   - 无可见消息的会话不返回(IM 列表只展示有消息的,EXISTS subquery 过滤)
func TestConversationRepo_ListForUser_Basic(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	msgRepo := NewMessageRepo(db)
	seed := seedConvFixture(t, db)

	conv, err := repo.FindOrCreateDM(t.Context(), "dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: seed.agentID, MemberType: "agent"},
	})
	if err != nil {
		t.Fatalf("FindOrCreateDM 失败: %v", err)
	}
	// 写一条消息(没消息的会话不进列表)
	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "hi"},
	})
	if _, err := msgRepo.Create(t.Context(), conv.ID, "user", seed.userID, content); err != nil {
		t.Fatalf("Create msg 失败: %v", err)
	}

	items, err := repo.ListForUser(t.Context(), seed.userID)
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

// TestConversationRepo_ListForUser_IncludesNoMessageWithCreatedAtFallback 验证
// 无消息会话也返列表(让新建群/DM 立即在所有 participant 列表出现),
// 且 last_message_at fallback 到 created_at 避免零值。
func TestConversationRepo_ListForUser_IncludesNoMessageWithCreatedAtFallback(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seed := seedConvFixture(t, db)

	// 创建一个 dm 但不写消息
	conv, err := repo.FindOrCreateDM(t.Context(), "dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: seed.agentID, MemberType: "agent"},
	})
	if err != nil {
		t.Fatalf("FindOrCreateDM 失败: %v", err)
	}

	items, err := repo.ListForUser(t.Context(), seed.userID)
	if err != nil {
		t.Fatalf("ListForUser 失败: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("无消息会话应进列表, 实际 %d 条", len(items))
	}
	if items[0].ID != conv.ID {
		t.Errorf("返回会话 ID 错误: 期望 %s, 实际 %s", conv.ID, items[0].ID)
	}
	// 无消息时 last_message_at 应 fallback 到 created_at(不是 0001-01-01 零值)
	if !items[0].LastMessageAt.Equal(conv.CreatedAt) {
		t.Errorf("无消息会话 last_message_at 应 fallback 到 created_at, 实际 last=%v created=%v",
			items[0].LastMessageAt, conv.CreatedAt)
	}
	// last_message_content / sender 应为空(无消息)
	if items[0].LastMessageContent.Valid {
		t.Errorf("无消息会话 last_message_content 应为 NULL, 实际 %v", items[0].LastMessageContent)
	}
}

// TestConversationRepo_ListForUser_ExcludesHidden 验证用户维度隐藏的会话不进列表。
// spec §3.5:WHERE p.hidden_at IS NULL
func TestConversationRepo_ListForUser_ExcludesHidden(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	msgRepo := NewMessageRepo(db)
	pRepo := NewParticipantRepo(db)
	seed := seedConvFixture(t, db)

	conv, _ := repo.FindOrCreateDM(t.Context(), "dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: seed.agentID, MemberType: "agent"},
	})
	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "hi"},
	})
	if _, err := msgRepo.Create(t.Context(), conv.ID, "user", seed.userID, content); err != nil {
		t.Fatalf("Create msg 失败: %v", err)
	}

	// 用户隐藏该会话
	if err := pRepo.SetHidden(t.Context(), conv.ID, seed.userID, "user", true); err != nil {
		t.Fatalf("SetHidden 失败: %v", err)
	}
	items, _ := repo.ListForUser(t.Context(), seed.userID)
	if len(items) != 0 {
		t.Errorf("隐藏的会话不应进列表, 实际 %d 条", len(items))
	}
}

// TestConversationRepo_ListForUser_OrdersByPinnedThenLastMessageAt 验证排序:
//   - 置顶组在前(pinned_at DESC NULLS LAST)
//   - 组内按最新消息 created_at DESC(017 后改子查询 messages 表)
//
// 场景:user 有 3 个 dm,各发 1 条消息:
//   - convC 最早发,未置顶
//   - convA 第二发(早于 B 一会儿),置顶
//   - convB 最后发,未置顶
//
// 期望顺序:[A(置顶), B(最新), C(最早)]
func TestConversationRepo_ListForUser_OrdersByPinnedThenLastMessageAt(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	msgRepo := NewMessageRepo(db)
	pRepo := NewParticipantRepo(db)
	seed := seedConvFixture(t, db)

	// 3 个 agent + 3 个 dm
	now := time.Now().UTC()
	makeDMAgent := func(name string) string {
		t.Helper()
		var id string
		if err := db.QueryRow(`
			INSERT INTO agents (owner_id, name, avatar_url, secret_key, created_at)
			VALUES ($1, $2, '', $3, $4) RETURNING id
		`, seed.userID, name, "sk-"+name, now).Scan(&id); err != nil {
			t.Fatalf("seed agent %s 失败: %v", name, err)
		}
		return id
	}
	agentA := makeDMAgent("AgentA")
	agentB := makeDMAgent("AgentB")
	agentC := makeDMAgent("AgentC")

	convA, _ := repo.FindOrCreateDM(t.Context(), "dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: agentA, MemberType: "agent"},
	})
	convB, _ := repo.FindOrCreateDM(t.Context(), "dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: agentB, MemberType: "agent"},
	})
	convC, _ := repo.FindOrCreateDM(t.Context(), "dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: agentC, MemberType: "agent"},
	})

	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "x"},
	})
	// C: 最早发
	if _, err := msgRepo.Create(t.Context(), convC.ID, "user", seed.userID, content); err != nil {
		t.Fatalf("Create C msg 失败: %v", err)
	}
	time.Sleep(5 * time.Millisecond)
	// A: 第二发 + 置顶
	if _, err := msgRepo.Create(t.Context(), convA.ID, "user", seed.userID, content); err != nil {
		t.Fatalf("Create A msg 失败: %v", err)
	}
	if err := pRepo.SetPinned(t.Context(), convA.ID, seed.userID, "user", true); err != nil {
		t.Fatalf("SetPinned A 失败: %v", err)
	}
	time.Sleep(5 * time.Millisecond)
	// B: 最后发
	if _, err := msgRepo.Create(t.Context(), convB.ID, "user", seed.userID, content); err != nil {
		t.Fatalf("Create B msg 失败: %v", err)
	}

	items, err := repo.ListForUser(t.Context(), seed.userID)
	if err != nil {
		t.Fatalf("ListForUser 失败: %v", err)
	}
	if len(items) != 3 {
		t.Fatalf("期望 3 条, 实际 %d", len(items))
	}
	// 期望顺序:A(置顶), B(最新), C(最早)
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

	conv1, _ := repo.FindOrCreateDM(t.Context(), "dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: seed.agentID, MemberType: "agent"},
	})

	// 第二个 dm(用第二个 agent)
	var agent2ID string
	if err := db.QueryRow(`
		INSERT INTO agents (owner_id, name, avatar_url, secret_key, created_at)
		VALUES ($1, 'AgentB', '', 'sk-b', NOW()) RETURNING id
	`, seed.userID).Scan(&agent2ID); err != nil {
		t.Fatalf("seed agent B 失败: %v", err)
	}
	conv2, _ := repo.FindOrCreateDM(t.Context(), "dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: agent2ID, MemberType: "agent"},
	})

	result, err := repo.BatchLoadParticipantSummaries(t.Context(), []string{conv1.ID, conv2.ID})
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

	result, err := repo.BatchLoadParticipantSummaries(t.Context(), nil)
	if err != nil {
		t.Fatalf("空 input 不应报错: %v", err)
	}
	if len(result) != 0 {
		t.Errorf("空 input 应返空 map, 实际 %d 个 key", len(result))
	}
}

// TestConversationRepo_BatchLoadParticipantSummaries_DanglingMember 验证 LEFT JOIN 未命中时容错。
//
// 场景:conversation_participants.member_id 在 users/agents 表中已无对应记录(脏数据 / 历史遗留)。
// 修复前:SQL SELECT username 列返 NULL,Go 用 string 扫描报 "converting NULL to string is unsupported"。
// 修复后:COALESCE(..., ”) 把 NULL 转空串,其他字段正常返回。
//
// 构造方式:seed 一个 dm,然后 DELETE FROM users WHERE id = ?,让 participants 引用悬空 user_id。
// 不能直接 INSERT 一行 member_id 不在 users 表的 participants(外键约束会拦),
// 删 user 路径绕过外键(users 表与 participants 表之间未必有外键,见 migration 001_init.sql)。
func TestConversationRepo_BatchLoadParticipantSummaries_DanglingMember(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seed := seedConvFixture(t, db)

	conv1, _ := repo.FindOrCreateDM(t.Context(), "dm_user_agent", DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user"},
		Other:     ParticipantInput{MemberID: seed.agentID, MemberType: "agent"},
	})

	// 删 user 制造悬空 participant(外键约束若有,DELETE 会被拦——目前 schema 无此 FK)。
	if _, err := db.Exec(`DELETE FROM users WHERE id = $1`, seed.userID); err != nil {
		t.Fatalf("delete user 制造悬空数据失败(可能 schema 加了 FK): %v", err)
	}

	result, err := repo.BatchLoadParticipantSummaries(t.Context(), []string{conv1.ID})
	if err != nil {
		t.Fatalf("悬空 member 不应报错: %v", err)
	}
	parts, ok := result[conv1.ID]
	if !ok {
		t.Fatalf("应返回 conv1 participants")
	}
	// 找悬空的 user participant,验证 username/nickname 是空串而非报错
	for _, p := range parts {
		if p.MemberType == "user" {
			if p.Username != "" {
				t.Errorf("悬空 user username 应为空串, 实际 %q", p.Username)
			}
			if p.Nickname != "" {
				t.Errorf("悬空 user nickname 应为空串, 实际 %q", p.Nickname)
			}
		}
	}
}

// === 越权 / 不存在场景 ===

// TestConversationRepo_GetByID_NotExists 验证 GetByID 不存在返 (nil, nil)。
func TestConversationRepo_GetByID_NotExists(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seedConvFixture(t, db)

	got, err := repo.GetByID(t.Context(), "00000000-0000-0000-0000-000000000001")
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

	items, err := repo.ListForUser(t.Context(), seed.userID)
	if err != nil {
		t.Fatalf("ListForUser 失败: %v", err)
	}
	if len(items) != 0 {
		t.Errorf("无会话 user 应返空切片, 实际 %d 条", len(items))
	}
}

// === FindDMByOwnerAgent 测试 ===

// TestConversationRepo_FindDMByOwnerAgent 验证按 (owner_user_id, agent_id) 查 dm_user_agent:
//   - 未建 conv 时返 (nil, nil),不报错
//   - 建 conv 后应返该 conv
//   - conv_id 与 FindOrCreateDM 一致
func TestConversationRepo_FindDMByOwnerAgent(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seed := seedConvFixture(t, db)

	// 1. 未建 conv 时返 (nil, nil)
	conv, err := repo.FindDMByOwnerAgent(t.Context(), seed.userID, seed.agentID)
	if err != nil {
		t.Fatalf("未建 conv 时不应报错: %v", err)
	}
	if conv != nil {
		t.Fatalf("未建 conv 时应返 nil,实际 %+v", conv)
	}

	// 2. 建 conv 后应能查到
	created, err := repo.FindOrCreateDM(t.Context(), model.ConvTypeDMUserAgent, DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user", Role: "owner"},
		Other:     ParticipantInput{MemberID: seed.agentID, MemberType: "agent", Role: "member"},
	})
	if err != nil {
		t.Fatalf("FindOrCreateDM 失败: %v", err)
	}

	conv, err = repo.FindDMByOwnerAgent(t.Context(), seed.userID, seed.agentID)
	if err != nil {
		t.Fatalf("建 conv 后查询失败: %v", err)
	}
	if conv == nil {
		t.Fatalf("应返已建 conv,实际 nil")
	}
	if conv.ID != created.ID {
		t.Errorf("conv_id 不一致: 期望 %s 实际 %s", created.ID, conv.ID)
	}
}

// === ListForAgent 测试 ===

// TestConversationRepo_ListForAgent 验证 agent 视角列出会话:
//   - 初始无 conv 时返空切片(非 nil)
//   - 建一个 dm 后应返 1 条
func TestConversationRepo_ListForAgent(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seed := seedConvFixture(t, db)

	// 1. 初始空
	convs, err := repo.ListForAgent(t.Context(), seed.agentID, "")
	if err != nil {
		t.Fatalf("初始查询失败: %v", err)
	}
	if len(convs) != 0 {
		t.Errorf("初始应返空切片,实际 %d 条", len(convs))
	}

	// 2. 建一个 dm
	created, err := repo.FindOrCreateDM(t.Context(), model.ConvTypeDMUserAgent, DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user", Role: "owner"},
		Other:     ParticipantInput{MemberID: seed.agentID, MemberType: "agent", Role: "member"},
	})
	if err != nil {
		t.Fatalf("FindOrCreateDM 失败: %v", err)
	}

	convs, err = repo.ListForAgent(t.Context(), seed.agentID, "")
	if err != nil {
		t.Fatalf("建 conv 后查询失败: %v", err)
	}
	if len(convs) != 1 {
		t.Fatalf("应返 1 条 conv,实际 %d", len(convs))
	}
	if convs[0].ID != created.ID {
		t.Errorf("conv_id 不一致: 期望 %s 实际 %s", created.ID, convs[0].ID)
	}
}

// TestConversationRepo_ListForAgent_TypeFilter 验证 typeFilter 参数:
//   - 空串 = 不过滤,返全部
//   - 指定 dm_user_agent = 只返该 type
//   - 指定 agent_session = 返全部 agent_session 实例(多实例语义)
//   - 指定不存在的 type = 返空
func TestConversationRepo_ListForAgent_TypeFilter(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	seed := seedConvFixture(t, db)

	// 建 1 个 dm_user_agent + 2 个 agent_session(同 owner+agent,多实例)
	_, err := repo.FindOrCreateDM(t.Context(), model.ConvTypeDMUserAgent, DMMembers{
		Initiator: ParticipantInput{MemberID: seed.userID, MemberType: "user", Role: "owner"},
		Other:     ParticipantInput{MemberID: seed.agentID, MemberType: "agent", Role: "member"},
	})
	if err != nil {
		t.Fatalf("FindOrCreateDM 失败: %v", err)
	}
	if _, err := repo.CreateAgentSession(t.Context(), seed.userID, seed.agentID, "s1", ""); err != nil {
		t.Fatalf("CreateAgentSession s1 失败: %v", err)
	}
	if _, err := repo.CreateAgentSession(t.Context(), seed.userID, seed.agentID, "s2", ""); err != nil {
		t.Fatalf("CreateAgentSession s2 失败: %v", err)
	}

	// 1. 空串 = 全部(3 条)
	all, err := repo.ListForAgent(t.Context(), seed.agentID, "")
	if err != nil {
		t.Fatalf("ListForAgent(空 filter) 失败: %v", err)
	}
	if len(all) != 3 {
		t.Errorf("空 filter 应返全部 3 条,实际 %d", len(all))
	}

	// 2. dm_user_agent 过滤
	dmOnly, err := repo.ListForAgent(t.Context(), seed.agentID, model.ConvTypeDMUserAgent)
	if err != nil {
		t.Fatalf("ListForAgent(dm) 失败: %v", err)
	}
	if len(dmOnly) != 1 {
		t.Errorf("dm filter 应返 1 条,实际 %d", len(dmOnly))
	}
	if len(dmOnly) > 0 && dmOnly[0].Type != model.ConvTypeDMUserAgent {
		t.Errorf("dm filter 返回 type 错误: %s", dmOnly[0].Type)
	}

	// 3. agent_session 过滤
	sessOnly, err := repo.ListForAgent(t.Context(), seed.agentID, model.ConvTypeAgentSession)
	if err != nil {
		t.Fatalf("ListForAgent(session) 失败: %v", err)
	}
	if len(sessOnly) != 2 {
		t.Errorf("session filter 应返 2 条,实际 %d", len(sessOnly))
	}
	for _, c := range sessOnly {
		if c.Type != model.ConvTypeAgentSession {
			t.Errorf("session filter 返回 type 错误: %s", c.Type)
		}
	}

	// 4. 不存在的 type = 空
	none, err := repo.ListForAgent(t.Context(), seed.agentID, "nonexistent_type")
	if err != nil {
		t.Fatalf("ListForAgent(不存在) 失败: %v", err)
	}
	if len(none) != 0 {
		t.Errorf("不存在的 type 应返空,实际 %d", len(none))
	}
}

// TestListAgentSessionsForUser 验证 user 视角查某 agent 的所有 agent_session 群。
// 供 APP 二级列表页:点 opencode agent 入口 → 列出该 agent 下所有 session 群。
//
// 场景:user 与 agent 有 2 个 agent_session + 1 个 dm_user_agent,
// ListAgentSessionsForUser 应只返 2 个 agent_session,排除 dm。
func TestListAgentSessionsForUser(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, err := urepo.Create(t.Context(), uniqueShortName(t, "u"), "$2a$10$h")
	if err != nil {
		t.Fatalf("Create user: %v", err)
	}
	agent, err := arepo.Create(t.Context(), user.ID, uniqueShortName(t, "ag"), "sk", "opencode")
	if err != nil {
		t.Fatalf("Create agent: %v", err)
	}

	// 2 个 agent_session(同 user+agent,多实例)
	if _, err := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s1", ""); err != nil {
		t.Fatalf("CreateAgentSession s1: %v", err)
	}
	if _, err := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s2", ""); err != nil {
		t.Fatalf("CreateAgentSession s2: %v", err)
	}
	// 1 个 dm_user_agent(不应出现)
	if _, err := repo.FindOrCreateDM(t.Context(), model.ConvTypeDMUserAgent, DMMembers{
		Initiator: ParticipantInput{MemberID: user.ID, MemberType: "user", Role: "owner"},
		Other:     ParticipantInput{MemberID: agent.ID, MemberType: "agent", Role: "member"},
	}); err != nil {
		t.Fatalf("FindOrCreateDM: %v", err)
	}

	got, err := repo.ListAgentSessionsForUser(t.Context(), user.ID, agent.ID)
	if err != nil {
		t.Fatalf("ListAgentSessionsForUser: %v", err)
	}
	if len(got) != 2 {
		t.Errorf("期望 2 个 agent_session,实际 %d", len(got))
	}
	for _, c := range got {
		if c.Type != model.ConvTypeAgentSession {
			t.Errorf("混入非 agent_session: %s", c.Type)
		}
	}
}

// TestConversationRepo_CreateAgentSession_DefaultSessionMeta 验证新建 agent_session
// 时写入默认 session_meta,确保 APP 首屏即可渲染 SessionMetaStrip/EnvMetaStrip。
// 回归:此前 CreateAgentSession 不写 session_meta → DB NULL → APP getConversation
// 拉到 sessionMeta=null → strips 整块不渲染,需等 plugin 首次 UpdateSessionMeta 才出现。
func TestConversationRepo_CreateAgentSession_DefaultSessionMeta(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, _ := urepo.Create(t.Context(), uniqueShortName(t, "u"), "$2a$10$h")
	agent, _ := arepo.Create(t.Context(), user.ID, uniqueShortName(t, "ag"), "sk", "opencode")

	conv, err := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s1", "")
	if err != nil {
		t.Fatalf("CreateAgentSession: %v", err)
	}

	// 重新从 DB 读取(走 GetByID 路径,与 buildDetail 一致)
	got, err := repo.GetByID(t.Context(), conv.ID)
	if err != nil {
		t.Fatalf("GetByID: %v", err)
	}
	if !got.SessionMeta.Valid {
		t.Fatal("新建 agent_session 的 session_meta 应非 NULL")
	}
	var meta map[string]any
	if err := json.Unmarshal(got.SessionMeta.RawMessage, &meta); err != nil {
		t.Fatalf("unmarshal session_meta: %v", err)
	}
	if mode, _ := meta["mode"].(string); mode != "build" {
		t.Errorf("默认 mode 期望 build,实际 %v", meta["mode"])
	}
	if _, ok := meta["model_id"]; !ok {
		t.Errorf("session_meta 应含 model_id 字段(空串即可)")
	}
	if _, ok := meta["provider_id"]; !ok {
		t.Errorf("session_meta 应含 provider_id 字段(空串即可)")
	}
}

// TestConversationRepo_CreateAgentSession_Directory 验证 directory 一级列写入与读取:
//   - 非空 directory → 入库后能通过 GetByID 读出
//   - 空 directory → 入库后 directory 为 NULL(*string == nil)
func TestConversationRepo_CreateAgentSession_Directory(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, _ := urepo.Create(t.Context(), uniqueShortName(t, "u"), "$2a$10$h")
	agent, _ := arepo.Create(t.Context(), user.ID, uniqueShortName(t, "ag"), "sk", "opencode")

	t.Run("非空 directory 写入与读出", func(t *testing.T) {
		conv, err := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "with-dir", "/workspace/app/chat")
		if err != nil {
			t.Fatalf("CreateAgentSession: %v", err)
		}
		got, err := repo.GetByID(t.Context(), conv.ID)
		if err != nil || got == nil {
			t.Fatalf("GetByID: %v %v", got, err)
		}
		if got.Directory == nil || *got.Directory != "/workspace/app/chat" {
			t.Errorf("Directory = %v, want /workspace/app/chat", got.Directory)
		}
	})

	t.Run("空 directory 表示 NULL", func(t *testing.T) {
		conv, err := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "no-dir", "")
		if err != nil {
			t.Fatalf("CreateAgentSession: %v", err)
		}
		got, err := repo.GetByID(t.Context(), conv.ID)
		if err != nil || got == nil {
			t.Fatalf("GetByID: %v %v", got, err)
		}
		if got.Directory != nil {
			t.Errorf("空 directory 期望 nil(NULL),实际 %v", *got.Directory)
		}
	})
}

// TestListAgentSessionsForUser_Empty 验证无 agent_session 时返空切片(非 nil),
// 且不误返其他 user 与同 agent 的 session(隔离校验)。
func TestListAgentSessionsForUser_Empty(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, _ := urepo.Create(t.Context(), uniqueShortName(t, "u"), "$2a$10$h")
	agent, _ := arepo.Create(t.Context(), user.ID, uniqueShortName(t, "ag"), "sk", "")

	// 只有 dm,无 agent_session
	repo.FindOrCreateDM(t.Context(), model.ConvTypeDMUserAgent, DMMembers{
		Initiator: ParticipantInput{MemberID: user.ID, MemberType: "user", Role: "owner"},
		Other:     ParticipantInput{MemberID: agent.ID, MemberType: "agent", Role: "member"},
	})

	got, err := repo.ListAgentSessionsForUser(t.Context(), user.ID, agent.ID)
	if err != nil {
		t.Fatalf("ListAgentSessionsForUser: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("无 agent_session 应返空,实际 %d", len(got))
	}
}

// TestListAgentSessionsForUser_OtherAgentExcluded 验证隔离:
// user 与 agentA 有 agent_session,与 agentB 也有 agent_session,
// 查 agentA 的 session 群时不应混入 agentB 的。
func TestListAgentSessionsForUser_OtherAgentExcluded(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, _ := urepo.Create(t.Context(), uniqueShortName(t, "u"), "$2a$10$h")
	agentA, _ := arepo.Create(t.Context(), user.ID, uniqueShortName(t, "agA"), "sk", "opencode")
	agentB, _ := arepo.Create(t.Context(), user.ID, uniqueShortName(t, "agB"), "sk", "opencode")

	// agentA 2 个 session,agentB 1 个 session
	repo.CreateAgentSession(t.Context(), user.ID, agentA.ID, "a1", "")
	repo.CreateAgentSession(t.Context(), user.ID, agentA.ID, "a2", "")
	repo.CreateAgentSession(t.Context(), user.ID, agentB.ID, "b1", "")

	gotA, err := repo.ListAgentSessionsForUser(t.Context(), user.ID, agentA.ID)
	if err != nil {
		t.Fatalf("ListAgentSessionsForUser agentA: %v", err)
	}
	if len(gotA) != 2 {
		t.Errorf("agentA 期望 2 个 session,实际 %d", len(gotA))
	}

	gotB, err := repo.ListAgentSessionsForUser(t.Context(), user.ID, agentB.ID)
	if err != nil {
		t.Fatalf("ListAgentSessionsForUser agentB: %v", err)
	}
	if len(gotB) != 1 {
		t.Errorf("agentB 期望 1 个 session,实际 %d", len(gotB))
	}
}

// TestListAgentSessionsForUser_FullFields 验证升级后的字段:
//   - last_message_content/sender 在有消息时正确填充
//   - 无消息时 last_message_at fallback 到 created_at, content NULL
//   - pinned 会话排在前面(pinned_at DESC NULLS LAST)
//   - hidden 会话不出现
func TestListAgentSessionsForUser_FullFields(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	msgRepo := NewMessageRepo(db)
	pRepo := NewParticipantRepo(db)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, _ := urepo.Create(t.Context(), uniqueShortName(t, "u"), "$2a$10$h")
	agent, _ := arepo.Create(t.Context(), user.ID, uniqueShortName(t, "ag"), "sk", "opencode")

	conv1, _ := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s1", "")
	conv2, _ := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s2", "")
	conv3, _ := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s3", "")
	conv4, _ := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s4", "")

	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "hello"},
	})

	// conv1: agent 消息 + 置顶
	msgRepo.Create(t.Context(), conv1.ID, "agent", agent.ID, content)
	pRepo.SetPinned(t.Context(), conv1.ID, user.ID, "user", true)
	time.Sleep(5 * time.Millisecond)

	// conv2: user 消息, 未置顶
	msgRepo.Create(t.Context(), conv2.ID, "user", user.ID, content)

	// conv3: 无消息

	// conv4: 有消息 + 隐藏(不应出现)
	msgRepo.Create(t.Context(), conv4.ID, "agent", agent.ID, content)
	pRepo.SetHidden(t.Context(), conv4.ID, user.ID, "user", true)

	got, err := repo.ListAgentSessionsForUser(t.Context(), user.ID, agent.ID)
	if err != nil {
		t.Fatalf("ListAgentSessionsForUser: %v", err)
	}
	if len(got) != 3 {
		t.Fatalf("期望 3 个(hidden 排除 conv4), 实际 %d", len(got))
	}

	// 排序: conv1(pinned) → conv2(最新消息) → conv3(无消息 fallback created_at)
	if got[0].ID != conv1.ID {
		t.Errorf("置顶 conv1 应排第一, 实际 %s", got[0].ID)
	}
	if got[1].ID != conv2.ID {
		t.Errorf("conv2 应排第二, 实际 %s", got[1].ID)
	}
	if got[2].ID != conv3.ID {
		t.Errorf("conv3 应排第三, 实际 %s", got[2].ID)
	}

	// conv1 字段验证
	if got[0].PinnedAt == nil {
		t.Errorf("conv1 应有 pinned_at")
	}
	if got[0].LastMessageSenderType != "agent" {
		t.Errorf("conv1 sender_type 期望 agent, 实际 %s", got[0].LastMessageSenderType)
	}
	if got[0].LastMessageSenderID != agent.ID {
		t.Errorf("conv1 sender_id 期望 %s, 实际 %s", agent.ID, got[0].LastMessageSenderID)
	}

	// conv2 字段验证
	if got[1].PinnedAt != nil {
		t.Errorf("conv2 未置顶, pinned_at 应 nil")
	}
	if got[1].LastMessageSenderType != "user" {
		t.Errorf("conv2 sender_type 期望 user, 实际 %s", got[1].LastMessageSenderType)
	}

	// conv3 无消息 → last_message_at fallback + content NULL
	if got[2].LastMessageContent.Valid {
		t.Errorf("conv3 无消息, last_message_content 应 NULL")
	}
	if !got[2].LastMessageAt.Equal(conv3.CreatedAt) {
		t.Errorf("conv3 无消息, last_message_at 应 fallback 到 created_at, got=%v want=%v",
			got[2].LastMessageAt, conv3.CreatedAt)
	}

	// 所有返回的 hidden_at 应为 nil
	for _, item := range got {
		if item.HiddenAt != nil {
			t.Errorf("返回的 session 不应有 hidden_at: %s", item.ID)
		}
	}
}

// TestListAgentSessionsForUser_LastUserMessageContent 验证 last_user_message_content
// 子查询:取当前用户最后一条 msg_type=text/tui_user 的消息文本,过滤 agent 消息和非文字类型。
// tui_user 消息需带 [TUI] 前缀(与 APP MsgTypeX.preview 规则对齐)。
func TestListAgentSessionsForUser_LastUserMessageContent(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	msgRepo := NewMessageRepo(db)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, _ := urepo.Create(t.Context(), uniqueShortName(t, "u"), "$2a$10$h")
	agent, _ := arepo.Create(t.Context(), user.ID, uniqueShortName(t, "ag"), "sk", "opencode")

	conv1, _ := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s1", "")
	conv2, _ := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s2", "")
	conv3, _ := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s3", "")
	conv4, _ := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s4", "")
	conv5, _ := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s5", "")
	conv6, _ := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s6", "")

	mkText := func(s string) json.RawMessage {
		b, _ := json.Marshal(map[string]interface{}{
			"msg_type": "text",
			"data":     map[string]string{"text": s},
		})
		return b
	}
	mkImage := func() json.RawMessage {
		b, _ := json.Marshal(map[string]interface{}{
			"msg_type": "image",
			"data":     map[string]string{"url": "x.png"},
		})
		return b
	}
	mkTui := func(s string) json.RawMessage {
		b, _ := json.Marshal(map[string]interface{}{
			"msg_type": "tui_user",
			"data":     map[string]string{"text": s},
		})
		return b
	}

	// conv1: user 发两条 text + agent 回复 → 期望最后一条 user text
	msgRepo.Create(t.Context(), conv1.ID, "user", user.ID, mkText("帮我修bug"))
	time.Sleep(5 * time.Millisecond)
	msgRepo.Create(t.Context(), conv1.ID, "user", user.ID, mkText("帮我改样式"))
	time.Sleep(5 * time.Millisecond)
	msgRepo.Create(t.Context(), conv1.ID, "agent", agent.ID, mkText("好的"))

	// conv2: 只有 agent 消息 → 期望空
	msgRepo.Create(t.Context(), conv2.ID, "agent", agent.ID, mkText("你好"))

	// conv3: user 发非文字(image) → 期望空
	msgRepo.Create(t.Context(), conv3.ID, "user", user.ID, mkImage())

	// conv4: 无消息 → 期望空

	// conv5: user 只发 tui_user → 期望 [TUI] xxx
	msgRepo.Create(t.Context(), conv5.ID, "user", user.ID, mkTui("在终端敲的"))

	// conv6: user 先发 text 后发 tui_user → 期望取最新 tui_user
	msgRepo.Create(t.Context(), conv6.ID, "user", user.ID, mkText("旧指令"))
	time.Sleep(5 * time.Millisecond)
	msgRepo.Create(t.Context(), conv6.ID, "user", user.ID, mkTui("新指令"))

	// conv7: plugin 代发 tui_user(真实场景:plugin 用 agent JWT 连 WS,
	// sender_type='agent'/sender_id=agent_id) → 期望仍命中摘要且带 [TUI] 前缀。
	conv7, _ := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s7", "")
	msgRepo.Create(t.Context(), conv7.ID, "agent", agent.ID, mkTui("plugin 代发的指令"))

	// conv8: user 先发 text,plugin 后代发 tui_user → 期望取最新 tui_user(OR 放宽后
	// user text 与 agent 代发 tui_user 共同按 created_at DESC 竞争,取最新)。
	conv8, _ := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s8", "")
	msgRepo.Create(t.Context(), conv8.ID, "user", user.ID, mkText("user 的旧问题"))
	time.Sleep(5 * time.Millisecond)
	msgRepo.Create(t.Context(), conv8.ID, "agent", agent.ID, mkTui("plugin 代发的新指令"))

	got, err := repo.ListAgentSessionsForUser(t.Context(), user.ID, agent.ID)
	if err != nil {
		t.Fatalf("ListAgentSessionsForUser: %v", err)
	}
	byID := map[string]model.ConversationListItem{}
	for _, c := range got {
		byID[c.ID] = c
	}

	if byID[conv1.ID].LastUserMessageContent != "帮我改样式" {
		t.Errorf("conv1 期望「帮我改样式」, 实际 %q", byID[conv1.ID].LastUserMessageContent)
	}
	if byID[conv2.ID].LastUserMessageContent != "" {
		t.Errorf("conv2 只有 agent 消息, 期望空, 实际 %q", byID[conv2.ID].LastUserMessageContent)
	}
	if byID[conv3.ID].LastUserMessageContent != "" {
		t.Errorf("conv3 user 发图非文字, 期望空, 实际 %q", byID[conv3.ID].LastUserMessageContent)
	}
	if byID[conv4.ID].LastUserMessageContent != "" {
		t.Errorf("conv4 无消息, 期望空, 实际 %q", byID[conv4.ID].LastUserMessageContent)
	}
	if byID[conv5.ID].LastUserMessageContent != "[TUI] 在终端敲的" {
		t.Errorf("conv5 期望「[TUI] 在终端敲的」, 实际 %q", byID[conv5.ID].LastUserMessageContent)
	}
	if byID[conv6.ID].LastUserMessageContent != "[TUI] 新指令" {
		t.Errorf("conv6 期望「[TUI] 新指令」(tui 比 text 新), 实际 %q", byID[conv6.ID].LastUserMessageContent)
	}
	if byID[conv7.ID].LastUserMessageContent != "[TUI] plugin 代发的指令" {
		t.Errorf("conv7 期望「[TUI] plugin 代发的指令」(plugin 代发 sender=agent), 实际 %q", byID[conv7.ID].LastUserMessageContent)
	}
	if byID[conv8.ID].LastUserMessageContent != "[TUI] plugin 代发的新指令" {
		t.Errorf("conv8 期望「[TUI] plugin 代发的新指令」(tui 比 user text 新), 实际 %q", byID[conv8.ID].LastUserMessageContent)
	}
}

// TestListForUser_ExcludesAgentSession 验证 ListForUser 的一级列表过滤:
//   - agent_session 不出现在 ListForUser(只在二级列表展示,避免污染 IM 主列表)
//   - dm_user_agent 的 AgentSummary 带 Type(供 APP 据类型路由点击行为)
func TestListForUser_ExcludesAgentSession(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, err := urepo.Create(t.Context(), uniqueShortName(t, "u"), "$2a$10$h")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	agent, err := arepo.Create(t.Context(), user.ID, uniqueShortName(t, "ag"), "sk", "opencode")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}

	// 一个 dm_user_agent + 两个 agent_session
	_, err = repo.FindOrCreateDM(t.Context(), model.ConvTypeDMUserAgent, DMMembers{
		Initiator: ParticipantInput{MemberID: user.ID, MemberType: "user", Role: "owner"},
		Other:     ParticipantInput{MemberID: agent.ID, MemberType: "agent", Role: "member"},
	})
	if err != nil {
		t.Fatalf("FindOrCreateDM 失败: %v", err)
	}
	if _, err := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s1", ""); err != nil {
		t.Fatalf("CreateAgentSession s1 失败: %v", err)
	}
	if _, err := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s2", ""); err != nil {
		t.Fatalf("CreateAgentSession s2 失败: %v", err)
	}

	items, err := repo.ListForUser(t.Context(), user.ID)
	if err != nil {
		t.Fatalf("ListForUser: %v", err)
	}
	for _, it := range items {
		if it.Type == model.ConvTypeAgentSession {
			t.Errorf("agent_session 不应出现在一级列表: %s", it.ID)
		}
	}
	// dm 的 AgentSummary 应带 type=opencode
	var dmFound bool
	for _, it := range items {
		if it.Type == model.ConvTypeDMUserAgent && it.Agent != nil {
			dmFound = true
			if it.Agent.Type != model.AgentTypeOpencode {
				t.Errorf("AgentSummary.Type = %q, want opencode", it.Agent.Type)
			}
		}
	}
	if !dmFound {
		t.Errorf("dm_user_agent 的 agent 摘要缺失")
	}
}

// === BatchLoadAgentSessionStats 测试 ===

// TestBatchLoadAgentSessionStats 验证批量聚合 agent_session 统计数据:
//   - session_count: agent_session 数量
//   - unread_total: 所有 agent_session 未读之和
//   - pending_count: 待处理 permission_card / question_card 数
//   - last_msg_at: 最新 session 活跃时间
func TestBatchLoadAgentSessionStats(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	msgRepo := NewMessageRepo(db)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, _ := urepo.Create(t.Context(), uniqueShortName(t, "u"), "$2a$10$h")
	agent, _ := arepo.Create(t.Context(), user.ID, uniqueShortName(t, "ag"), "sk", "opencode")

	// 2 个 agent_session
	s1, _ := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s1", "")
	s2, _ := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s2", "")

	// s1: 1 条 pending permission_card
	permPending, _ := json.Marshal(map[string]interface{}{
		"msg_type": "permission_card",
		"data":     map[string]interface{}{"status": "pending", "action": "bash"},
	})
	msgRepo.Create(t.Context(), s1.ID, "agent", agent.ID, permPending)

	// s1: 1 条已处理 question_card（不应计入 pending）
	qaAnswered, _ := json.Marshal(map[string]interface{}{
		"msg_type": "question_card",
		"data":     map[string]interface{}{"status": "answered"},
	})
	msgRepo.Create(t.Context(), s1.ID, "agent", agent.ID, qaAnswered)

	// s2: 1 条普通 text 消息
	textContent, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "hello"},
	})
	msgRepo.Create(t.Context(), s2.ID, "agent", agent.ID, textContent)

	// 设置 unread_count（模拟消息处理器给非 sender +1）
	db.Exec(`UPDATE conversation_participants SET unread_count = 3 WHERE conv_id = $1 AND member_id = $2`, s1.ID, user.ID)
	db.Exec(`UPDATE conversation_participants SET unread_count = 1 WHERE conv_id = $1 AND member_id = $2`, s2.ID, user.ID)

	stats, err := repo.BatchLoadAgentSessionStats(t.Context(), user.ID, []string{agent.ID})
	if err != nil {
		t.Fatalf("BatchLoadAgentSessionStats: %v", err)
	}

	s, ok := stats[agent.ID]
	if !ok {
		t.Fatal("期望返回 agent 的统计数据")
	}
	if s.SessionCount != 2 {
		t.Errorf("SessionCount 期望 2, 实际 %d", s.SessionCount)
	}
	if s.UnreadTotal != 4 {
		t.Errorf("UnreadTotal 期望 4, 实际 %d", s.UnreadTotal)
	}
	if s.PendingCount != 1 {
		t.Errorf("PendingCount 期望 1, 实际 %d", s.PendingCount)
	}
	if s.LastMessageAt.IsZero() {
		t.Error("LastMessageAt 不应为零值")
	}
}

// TestBatchLoadAgentSessionStats_EmptyInput 验证空 agentIDs 返空 map 不报错。
func TestBatchLoadAgentSessionStats_EmptyInput(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	urepo := NewUserRepo(db)
	user, _ := urepo.Create(t.Context(), uniqueShortName(t, "u"), "$2a$10$h")

	result, err := repo.BatchLoadAgentSessionStats(t.Context(), user.ID, nil)
	if err != nil {
		t.Fatalf("空输入不应报错: %v", err)
	}
	if len(result) != 0 {
		t.Errorf("空输入应返空 map, 实际 %d 项", len(result))
	}
}

// TestBatchLoadAgentSessionStats_NoSession 验证 agent 无 agent_session 时返空 map。
func TestBatchLoadAgentSessionStats_NoSession(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, _ := urepo.Create(t.Context(), uniqueShortName(t, "u"), "$2a$10$h")
	agent, _ := arepo.Create(t.Context(), user.ID, uniqueShortName(t, "ag"), "sk", "opencode")

	// 只有 dm，无 agent_session
	repo.FindOrCreateDM(t.Context(), model.ConvTypeDMUserAgent, DMMembers{
		Initiator: ParticipantInput{MemberID: user.ID, MemberType: "user", Role: "owner"},
		Other:     ParticipantInput{MemberID: agent.ID, MemberType: "agent", Role: "member"},
	})

	result, err := repo.BatchLoadAgentSessionStats(t.Context(), user.ID, []string{agent.ID})
	if err != nil {
		t.Fatalf("无 session 不应报错: %v", err)
	}
	if len(result) != 0 {
		t.Errorf("无 agent_session 应返空 map, 实际 %d 项", len(result))
	}
}

// TestBatchLoadAgentSessionStats_MultiAgent 验证多 agent 聚合互不干扰。
func TestBatchLoadAgentSessionStats_MultiAgent(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, _ := urepo.Create(t.Context(), uniqueShortName(t, "u"), "$2a$10$h")
	agentA, _ := arepo.Create(t.Context(), user.ID, uniqueShortName(t, "agA"), "sk", "opencode")
	agentB, _ := arepo.Create(t.Context(), user.ID, uniqueShortName(t, "agB"), "sk", "opencode")

	// agentA: 1 个 session + 1 条 pending
	sA, _ := repo.CreateAgentSession(t.Context(), user.ID, agentA.ID, "a1", "")
	permPending, _ := json.Marshal(map[string]interface{}{
		"msg_type": "permission_card",
		"data":     map[string]interface{}{"status": "pending"},
	})
	msgRepo := NewMessageRepo(db)
	msgRepo.Create(t.Context(), sA.ID, "agent", agentA.ID, permPending)

	// agentB: 2 个 session，无 pending
	repo.CreateAgentSession(t.Context(), user.ID, agentB.ID, "b1", "")
	repo.CreateAgentSession(t.Context(), user.ID, agentB.ID, "b2", "")

	stats, err := repo.BatchLoadAgentSessionStats(t.Context(), user.ID, []string{agentA.ID, agentB.ID})
	if err != nil {
		t.Fatalf("BatchLoadAgentSessionStats: %v", err)
	}

	sA2, ok := stats[agentA.ID]
	if !ok {
		t.Fatal("agentA 统计缺失")
	}
	if sA2.SessionCount != 1 || sA2.PendingCount != 1 {
		t.Errorf("agentA: SessionCount=%d PendingCount=%d, want 1/1", sA2.SessionCount, sA2.PendingCount)
	}

	sB, ok := stats[agentB.ID]
	if !ok {
		t.Fatal("agentB 统计缺失")
	}
	if sB.SessionCount != 2 || sB.PendingCount != 0 {
		t.Errorf("agentB: SessionCount=%d PendingCount=%d, want 2/0", sB.SessionCount, sB.PendingCount)
	}
}

// TestBatchLoadAgentSessionStats_ChildApprovalCardPending 验证:子 agent 审批卡
// (permission_card,带 parent/root,pending)豁免 pending_count 过滤(is_main_stream),
// 计入待办角标。即使挂在子 agent 子树下,用户也需在一级列表看到待办。
func TestBatchLoadAgentSessionStats_ChildApprovalCardPending(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	msgRepo := NewMessageRepo(db)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, _ := urepo.Create(t.Context(), uniqueShortName(t, "u"), "$2a$10$h")
	agent, _ := arepo.Create(t.Context(), user.ID, uniqueShortName(t, "ag"), "sk", "opencode")

	s1, _ := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s1", "")

	// 顶层 task 卡片(作为 parent/root)
	taskContent, _ := json.Marshal(map[string]interface{}{
		"msg_type": "tool_card",
		"data":     map[string]interface{}{"name": "task"},
	})
	taskMsg, _ := msgRepo.Create(t.Context(), s1.ID, "agent", agent.ID, taskContent)

	// 子 agent permission_card(parent=task, root=task, pending):应计入 pending
	permPending, _ := json.Marshal(map[string]interface{}{
		"msg_type": "permission_card",
		"data":     map[string]interface{}{"status": "pending", "action": "bash"},
	})
	_, err := msgRepo.CreateWithParent(t.Context(), s1.ID, "agent", agent.ID, permPending, taskMsg.ID, taskMsg.ID)
	if err != nil {
		t.Fatalf("CreateWithParent 子审批卡失败: %v", err)
	}

	stats, err := repo.BatchLoadAgentSessionStats(t.Context(), user.ID, []string{agent.ID})
	if err != nil {
		t.Fatalf("BatchLoadAgentSessionStats: %v", err)
	}

	s, ok := stats[agent.ID]
	if !ok {
		t.Fatal("期望返回 agent 的统计数据")
	}
	if s.PendingCount != 1 {
		t.Errorf("子 agent 审批卡应计入 PendingCount, 期望 1, 实际 %d", s.PendingCount)
	}
}

// TestListAgentSessionsForUser_PendingCount 验证二级列表每条 session 的 pending_count:
//   - pending permission_card / question_card 计入
//   - 已处理(approved/denied/answered/rejected/expired)不计入
//   - 子流(is_main_stream=false)不计入
func TestListAgentSessionsForUser_PendingCount(t *testing.T) {
	db := SetupTestDB(t)
	repo := NewConversationRepo(db)
	msgRepo := NewMessageRepo(db)
	urepo := NewUserRepo(db)
	arepo := NewAgentRepo(db)

	user, _ := urepo.Create(t.Context(), uniqueShortName(t, "u"), "$2a$10$h")
	agent, _ := arepo.Create(t.Context(), user.ID, uniqueShortName(t, "ag"), "sk", "opencode")

	s1, _ := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s1", "")
	s2, _ := repo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s2", "")

	permPending, _ := json.Marshal(map[string]interface{}{
		"msg_type": "permission_card",
		"data":     map[string]interface{}{"status": "pending", "action": "bash"},
	})
	msgRepo.Create(t.Context(), s1.ID, "agent", agent.ID, permPending)

	qaPending, _ := json.Marshal(map[string]interface{}{
		"msg_type": "question_card",
		"data":     map[string]interface{}{"status": "pending"},
	})
	msgRepo.Create(t.Context(), s1.ID, "agent", agent.ID, qaPending)

	permApproved, _ := json.Marshal(map[string]interface{}{
		"msg_type": "permission_card",
		"data":     map[string]interface{}{"status": "approved"},
	})
	msgRepo.Create(t.Context(), s1.ID, "agent", agent.ID, permApproved)

	textContent, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "hello"},
	})
	msgRepo.Create(t.Context(), s2.ID, "agent", agent.ID, textContent)

	got, err := repo.ListAgentSessionsForUser(t.Context(), user.ID, agent.ID)
	if err != nil {
		t.Fatalf("ListAgentSessionsForUser: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("期望 2 个 session, 实际 %d", len(got))
	}

	var s1Item, s2Item model.ConversationListItem
	for _, item := range got {
		if item.ID == s1.ID {
			s1Item = item
		}
		if item.ID == s2.ID {
			s2Item = item
		}
	}
	if s1Item.PendingCount != 2 {
		t.Errorf("s1 pending_count 期望 2(1 perm + 1 qa), 实际 %d", s1Item.PendingCount)
	}
	if s2Item.PendingCount != 0 {
		t.Errorf("s2 pending_count 期望 0, 实际 %d", s2Item.PendingCount)
	}
}
