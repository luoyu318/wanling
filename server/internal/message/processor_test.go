package message

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/wanling/server/internal/agent"
	"github.com/wanling/server/internal/hub"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// shortName 把测试名压成不超过 32 字符的稳定短串，避免超出 users.username varchar(64) 限制。
func shortName(t *testing.T, prefix string) string {
	t.Helper()
	name := strings.ToLower(t.Name())
	name = strings.ReplaceAll(name, "test", "")
	name = strings.ReplaceAll(name, "_", "")
	if len(name) > 20 {
		name = name[:20]
	}
	return prefix + name
}

// === 测试 seed helpers ===

// seedUser 直接 INSERT users 表,返回 user_id。
// 不走 UserRepo.Create(避免被 hash 逻辑耦合),测试只关心 participant 模型行为。
func seedUser(t *testing.T, db *sql.DB, username string) string {
	t.Helper()
	var id string
	if err := db.QueryRow(`
		INSERT INTO users (username, password_hash, avatar_url, created_at)
		VALUES ($1, $2, '', $3) RETURNING id
	`, username, "hash", time.Now().UTC()).Scan(&id); err != nil {
		t.Fatalf("seed user %q 失败: %v", username, err)
	}
	return id
}

// seedAgent 直接 INSERT agents 表,owner_id 外键到 users。
func seedAgent(t *testing.T, db *sql.DB, ownerID, name string) string {
	t.Helper()
	var id string
	if err := db.QueryRow(`
		INSERT INTO agents (owner_id, name, avatar_url, secret_key, created_at)
		VALUES ($1, $2, '', $3, $4) RETURNING id
	`, ownerID, name, "sk-test", time.Now().UTC()).Scan(&id); err != nil {
		t.Fatalf("seed agent %q 失败: %v", name, err)
	}
	return id
}

// dmFixture 是 DM(dm_user_agent)测试场景的常用 ID 集合。
type dmFixture struct {
	db            *sql.DB
	convRepo      *repository.ConversationRepo
	msgRepo       *repository.MessageRepo
	agentRepo     *repository.AgentRepo
	userRepo      *repository.UserRepo
	fileRepo      *repository.FileRepo
	participantRp *repository.ParticipantRepo
	deliveryRp    *repository.DeliveryRepo
	userID        string
	agentID       string
	convID        string
}

// seedDM 构造 user + agent + dm_user_agent 会话,返回 fixture。
// 会话通过 FindOrCreateDM 建出 2 个 participants(user=owner, agent=member)。
func seedDM(t *testing.T) dmFixture {
	t.Helper()
	db := repository.SetupTestDB(t)
	fix := dmFixture{
		db:            db,
		convRepo:      repository.NewConversationRepo(db),
		msgRepo:       repository.NewMessageRepo(db),
		agentRepo:     repository.NewAgentRepo(db),
		userRepo:      repository.NewUserRepo(db),
		fileRepo:      repository.NewFileRepo(db),
		participantRp: repository.NewParticipantRepo(db),
		deliveryRp:    repository.NewDeliveryRepo(db),
	}
	fix.userID = seedUser(t, db, shortName(t, "u_"))
	fix.agentID = seedAgent(t, db, fix.userID, "Agent"+shortName(t, ""))

	conv, err := fix.convRepo.FindOrCreateDM(t.Context(), "dm_user_agent", repository.DMMembers{
		Initiator: repository.ParticipantInput{MemberID: fix.userID, MemberType: "user", Role: "owner"},
		Other:     repository.ParticipantInput{MemberID: fix.agentID, MemberType: "agent", Role: "member"},
	})
	if err != nil {
		t.Fatalf("FindOrCreateDM 失败: %v", err)
	}
	fix.convID = conv.ID
	return fix
}

// newProcessorWithNilHub 构造一个 hub(无 presence,无任何 client 注册)的 Processor。
// dispatch 时 SendToUser/SendToAgent 会直接 return nil,不触发 bufferedSend,
// 是测试 dispatch 副作用的最小侵入方式。
// agentRegistry 传 nil:默认测试不验证 AGENT_MODELS 分支;需要时由测试自行赋值
// p.agentRegistry(见 TestProcessor_AgentModels_*)。
func newProcessorWithNilHub(t *testing.T, fix dmFixture) *Processor {
	t.Helper()
	h := hub.NewHub(nil, fix.agentRepo, fix.participantRp, nil)
	return NewProcessor(h, fix.convRepo, fix.msgRepo, fix.agentRepo, fix.userRepo, fix.fileRepo,
		fix.participantRp, fix.deliveryRp, nil, nil, nil, nil, nil)
}

// msgContent 构造 text 消息 content JSON。
func msgContent(text string) json.RawMessage {
	c, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": text},
	})
	return c
}

// convPayload 构造 MESSAGE_CREATE 的 wsMsg.D(新协议:含 conversation_id)。
// user_id/agent_id 路由已废弃,所有 send 路径都用 conversation_id。
func convPayload(convID string, content json.RawMessage) json.RawMessage {
	d, _ := json.Marshal(map[string]interface{}{
		"conversation_id": convID,
		"content":         content,
	})
	return d
}

// legacyAgentToUserPayload 构造旧协议 payload(含 user_id,无 conversation_id)。
// 仅用于 TestHandleIncoming_RejectsLegacyUserIDPayload 验证旧协议被静默丢弃。
func legacyAgentToUserPayload(userID string, content json.RawMessage) json.RawMessage {
	d, _ := json.Marshal(map[string]interface{}{
		"user_id": userID,
		"content": content,
	})
	return d
}

// === 集成测试 ===

// TestProcessor_HandleIncoming_DMUserAgent 验证 dm_user_agent 场景:
// agent → user 发消息,3 写操作原子提交,deliveries / unread_count / dispatch 全对齐。
//
// 校验点:
//  1. messages 表新增 1 行
//  2. message_deliveries 新增 1 行(recipient=user, read_at=NULL)
//  3. user.unread_count = 1, agent.unread_count 不变(0)
//  4. agent 自己也有 participant 行(role=member,unread=0)
//
// 注:017 删 conversations.last_message_content 缓存字段后,本测试不再校验缓存写入
// (ListForUser 改子查询实时算,见 repository/conversation_repo_test.go)。
func TestProcessor_HandleIncoming_DMUserAgent(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageCreate,
		D:  convPayload(fix.convID, msgContent("agent reply")),
	})

	// 1. messages 表 1 行
	msgs, err := fix.msgRepo.ListByConversation(t.Context(), fix.convID, fix.userID, "user", 100, 0)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("期望 1 条消息,实际: %d", len(msgs))
	}
	if msgs[0].SenderType != "agent" || msgs[0].SenderID != fix.agentID {
		t.Errorf("sender 错误: got %s/%s, want agent/%s", msgs[0].SenderType, msgs[0].SenderID, fix.agentID)
	}

	// 2. deliveries: 1 行 recipient=user read_at NULL
	var (
		dCount    int
		dReadAt   *time.Time
		dRecipID  string
		dRecipTyp string
	)
	if err := fix.db.QueryRow(`
		SELECT COUNT(*), (SELECT read_at FROM message_deliveries WHERE message_id = $1),
		       (SELECT recipient_id FROM message_deliveries WHERE message_id = $1),
		       (SELECT recipient_type FROM message_deliveries WHERE message_id = $1)
		FROM message_deliveries WHERE message_id = $1
	`, msgs[0].ID).Scan(&dCount, &dReadAt, &dRecipID, &dRecipTyp); err != nil {
		t.Fatalf("查 deliveries 失败: %v", err)
	}
	if dCount != 1 {
		t.Errorf("deliveries 行数错误: 期望 1, 实际 %d", dCount)
	}
	if dReadAt != nil {
		t.Errorf("delivery read_at 应为 NULL, 实际 %v", *dReadAt)
	}
	if dRecipID != fix.userID || dRecipTyp != "user" {
		t.Errorf("delivery recipient 错误: got %s/%s, want %s/user", dRecipTyp, dRecipID, fix.userID)
	}

	// 3. unread_count: user=1, agent=0
	userP, err := fix.participantRp.Get(t.Context(), fix.convID, fix.userID, "user")
	if err != nil {
		t.Fatalf("Get user participant 失败: %v", err)
	}
	if userP.UnreadCount != 1 {
		t.Errorf("user unread_count 期望 1, 实际 %d", userP.UnreadCount)
	}
	agentP, err := fix.participantRp.Get(t.Context(), fix.convID, fix.agentID, "agent")
	if err != nil {
		t.Fatalf("Get agent participant 失败: %v", err)
	}
	if agentP.UnreadCount != 0 {
		t.Errorf("agent unread_count 期望 0, 实际 %d", agentP.UnreadCount)
	}
	if agentP.Role != "member" {
		t.Errorf("agent role 期望 member, 实际 %s", agentP.Role)
	}
}

// TestProcessor_HandleIncoming_GroupUserTxFlow 验证 group_user 场景下,
// HandleIncoming 内部那 4 个事务操作的语义(对 group 同样适用):
// 3 个 user 的群,user_a 发消息,user_b/user_c 各 +1 unread,a 不变;
// deliveries 2 行(recipient=b/c, read_at=NULL);agent 不参与。
//
// 注意:本测试不通过 HandleIncoming 入口,而是直接走事务路径(模拟 ws_handler
// 改造后从路由层拿 convID 的场景)。当前 HandleIncoming 还会强制 FindOrCreateDM
// (走 dm 路径),完整 group + HandleIncoming 联调在 ws_handler 改造后补
// (后续 task: TODO participants-refactor)。
//
// 关键校验:
//   - recipients 过滤掉 sender,只剩 2 个
//   - IncrUnreadTx 只给非 sender 全员 +1
//   - CreateBatchTx 只给 recipients 插 deliveries
func TestProcessor_HandleIncoming_GroupUserTxFlow(t *testing.T) {
	db := repository.SetupTestDB(t)
	convRepo := repository.NewConversationRepo(db)
	msgRepo := repository.NewMessageRepo(db)
	participantRp := repository.NewParticipantRepo(db)
	deliveryRp := repository.NewDeliveryRepo(db)

	// 3 个 user
	userA := seedUser(t, db, shortName(t, "ua_"))
	userB := seedUser(t, db, shortName(t, "ub_"))
	userC := seedUser(t, db, shortName(t, "uc_"))

	// 创建 group_user 会话(owner=userA)
	tx, err := db.Begin()
	if err != nil {
		t.Fatalf("Begin 失败: %v", err)
	}
	conv, err := convRepo.CreateTx(t.Context(), tx, "group_user", "测试群", "")
	if err != nil {
		t.Fatalf("CreateTx 失败: %v", err)
	}
	if err := participantRp.AddParticipantsTx(t.Context(), tx, conv.ID, []repository.ParticipantInput{
		{MemberID: userA, MemberType: "user", Role: "owner"},
		{MemberID: userB, MemberType: "user", Role: "member"},
		{MemberID: userC, MemberType: "user", Role: "member"},
	}); err != nil {
		t.Fatalf("AddParticipantsTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit 失败: %v", err)
	}

	// 复刻 HandleIncoming 内部事务路径(spec §3.3):
	// BeginTx → CreateTx → ListByConversationTx → filter sender →
	// CreateBatchTx → IncrUnreadTx → Commit
	// (017 删 last_message_content 缓存后,事务不再调 UpdateLastMessageTx;
	//  会话列表改子查询实时算。)
	tx, err = convRepo.BeginTx(t.Context())
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	defer tx.Rollback()

	content := msgContent("group broadcast")
	msg, err := msgRepo.CreateTx(t.Context(), tx, conv.ID, "user", userA, content)
	if err != nil {
		t.Fatalf("CreateTx 失败: %v", err)
	}
	parts, err := participantRp.ListByConversationTx(t.Context(), tx, conv.ID)
	if err != nil {
		t.Fatalf("ListByConversationTx 失败: %v", err)
	}
	recipients := filterSender(parts, userA, "user")
	if len(recipients) != 2 {
		t.Fatalf("recipients 数错误: 期望 2(b/c), 实际 %d", len(recipients))
	}
	if err := deliveryRp.CreateBatchTx(t.Context(), tx, msg.ID, recipients); err != nil {
		t.Fatalf("CreateBatchTx 失败: %v", err)
	}
	if err := participantRp.IncrUnreadTx(t.Context(), tx, conv.ID, userA, "user"); err != nil {
		t.Fatalf("IncrUnreadTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit 失败: %v", err)
	}

	// 校验:user_b/c unread=1,user_a unread=0
	for _, uid := range []string{userB, userC} {
		pt, err := participantRp.Get(t.Context(), conv.ID, uid, "user")
		if err != nil {
			t.Fatalf("Get %s 失败: %v", uid, err)
		}
		if pt.UnreadCount != 1 {
			t.Errorf("%s unread 期望 1, 实际 %d", uid, pt.UnreadCount)
		}
	}
	ptA, _ := participantRp.Get(t.Context(), conv.ID, userA, "user")
	if ptA.UnreadCount != 0 {
		t.Errorf("user_a unread 期望 0(sender 不自增), 实际 %d", ptA.UnreadCount)
	}

	// deliveries 2 行,都 read_at=NULL
	var (
		dCount   int
		nullRows int
	)
	if err := db.QueryRow(`
		SELECT COUNT(*), COUNT(*) FILTER (WHERE read_at IS NULL)
		FROM message_deliveries WHERE message_id = $1
	`, msg.ID).Scan(&dCount, &nullRows); err != nil {
		t.Fatalf("查 deliveries 失败: %v", err)
	}
	if dCount != 2 {
		t.Errorf("deliveries 行数错误: 期望 2(b+c), 实际 %d", dCount)
	}
	if nullRows != 2 {
		t.Errorf("新消息 deliveries 应全为 NULL: 期望 2, 实际 %d", nullRows)
	}
}

// filterSender 从 participants 列表过滤掉 sender,返回 recipients。
// 与 processor.go 的逻辑等价,在 group 测试中作为 oracle 用。
func filterSender(parts []model.ConversationParticipant, senderID, senderType string) []model.ConversationParticipant {
	out := make([]model.ConversationParticipant, 0, len(parts))
	for _, p := range parts {
		if p.MemberID == senderID && p.MemberType == senderType {
			continue
		}
		out = append(out, p)
	}
	return out
}

// TestProcessor_HandleIncoming_HiddenAtDoesNotAffectSend 边界:
// conv 的某 participant.hidden_at IS NOT NULL(某人隐藏了会话),
// 但发消息应该 still work(hidden_at 只影响 IM 列表显示,不影响消息流)。
//
// 场景:user 隐藏 → agent 发消息。
// 校验:消息正常写入 + delivery 正常插 + unread 仍 +1 + hidden_at 在事务内被清空。
func TestProcessor_HandleIncoming_HiddenAtDoesNotAffectSend(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	// user 隐藏会话
	if err := fix.participantRp.SetHidden(t.Context(), fix.convID, fix.userID, "user", true); err != nil {
		t.Fatalf("SetHidden 失败: %v", err)
	}

	// agent 发消息
	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageCreate,
		D:  convPayload(fix.convID, msgContent("after hide")),
	})

	// 校验:消息正常写入
	msgs, err := fix.msgRepo.ListByConversation(t.Context(), fix.convID, fix.userID, "user", 100, 0)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("hidden 状态下消息应正常写入: 期望 1, 实际 %d", len(msgs))
	}

	// 校验:user.unread_count 仍 +1(hidden 不影响未读计数)
	userP, _ := fix.participantRp.Get(t.Context(), fix.convID, fix.userID, "user")
	if userP.UnreadCount != 1 {
		t.Errorf("hidden 状态下 unread 仍应 +1: 期望 1, 实际 %d", userP.UnreadCount)
	}
	// 校验:user 作为 recipient,hidden_at 也应被新消息自动清空
	// (migration 004「新消息来时置空」语义:会话有新消息全员恢复显示)
	if userP.HiddenAt != nil {
		t.Errorf("新消息后 recipient(user)的 hidden_at 应被清空,仍非空: %v", userP.HiddenAt)
	}
}

// TestProcessor_HandleIncoming_NewMessageClearsAllHiddenAt 验证「新消息自动恢复全员显示」语义
// (migration 004 承诺,participants 模型重构后下沉为「会话内全员 hidden_at 都清空」)。
//
// 场景:user 和 agent 都隐藏了会话 → agent 发消息 → 两者 hidden_at 都被清空。
// 这是修复「对方删过会话,我发消息后对方列表不显示」bug 的核心断言。
func TestProcessor_HandleIncoming_NewMessageClearsAllHiddenAt(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	// 双方都隐藏会话(模拟两端各自删除过)
	if err := fix.participantRp.SetHidden(t.Context(), fix.convID, fix.userID, "user", true); err != nil {
		t.Fatalf("SetHidden user 失败: %v", err)
	}
	if err := fix.participantRp.SetHidden(t.Context(), fix.convID, fix.agentID, "agent", true); err != nil {
		t.Fatalf("SetHidden agent 失败: %v", err)
	}

	// agent 发消息
	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageCreate,
		D:  convPayload(fix.convID, msgContent("reactivate")),
	})

	// 校验:agent(sender)的 hidden_at 被清空
	agentP, _ := fix.participantRp.Get(t.Context(), fix.convID, fix.agentID, "agent")
	if agentP.HiddenAt != nil {
		t.Errorf("sender(agent)的 hidden_at 应被清空,仍非空: %v", agentP.HiddenAt)
	}
	// 校验:user(recipient)的 hidden_at 也被清空(关键:对齐老 migration 语义)
	userP, _ := fix.participantRp.Get(t.Context(), fix.convID, fix.userID, "user")
	if userP.HiddenAt != nil {
		t.Errorf("recipient(user)的 hidden_at 应被新消息自动清空,仍非空: %v", userP.HiddenAt)
	}
}

// TestProcessor_HandleIncoming_AgentSessionMessageUnhidesParentDM multi_session 级联恢复:
// 用户在一级列表删除 dm 入口行(Hide dm),之后 agent 在 agent_session 子会话回复
// → dm 入口行应自动恢复(hidden_at 清空),否则入口行永远不出现在一级列表。
//
// 背景:Unhide 的作用域是「消息落点会话」,multi_session 拓扑下入口行(dm)与
// 消息落点(agent_session)分离,子会话消息不进 dm,dm 的 hidden_at 永远无人清。
// 修复:消息落 agent_session 时级联 Unhide 同 (owner, agent) 的 dm 入口行。
func TestProcessor_HandleIncoming_AgentSessionMessageUnhidesParentDM(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	// 建 agent_session 子会话(同 owner+agent,自动加 2 participants)
	session, err := fix.convRepo.CreateAgentSession(t.Context(), fix.userID, fix.agentID, "s1", "")
	if err != nil {
		t.Fatalf("CreateAgentSession 失败: %v", err)
	}

	// 用户删除一级 dm 入口行 + 二级子会话(各自独立隐藏)
	if err := fix.participantRp.SetHidden(t.Context(), fix.convID, fix.userID, "user", true); err != nil {
		t.Fatalf("SetHidden dm 失败: %v", err)
	}
	if err := fix.participantRp.SetHidden(t.Context(), session.ID, fix.userID, "user", true); err != nil {
		t.Fatalf("SetHidden session 失败: %v", err)
	}

	// agent 在子会话回复
	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageCreate,
		D:  convPayload(session.ID, msgContent("session reply")),
	})

	// 关键断言:dm 入口行 hidden_at 被级联清空(一级列表恢复显示入口行)
	dmP, _ := fix.participantRp.Get(t.Context(), fix.convID, fix.userID, "user")
	if dmP.HiddenAt != nil {
		t.Errorf("子会话消息后 dm 入口行 hidden_at 应被级联清空,仍非空: %v", dmP.HiddenAt)
	}
	// 子会话自身 hidden_at 照常被清(现有行为不回退)
	sessionP, _ := fix.participantRp.Get(t.Context(), session.ID, fix.userID, "user")
	if sessionP.HiddenAt != nil {
		t.Errorf("子会话自身 hidden_at 应被清空,仍非空: %v", sessionP.HiddenAt)
	}
}

// TestProcessor_HandleIncoming_AbortsOnInvalidSenderType 验证:
// HandleIncoming 在 sender_type 非法时优雅失败 — 不污染任何表(messages / deliveries /
// participants / conversations 都无残留),unread_count 不变。
//
// 当前实现下,非法 sender_type 在 FindOrCreateDM 阶段就会触发 conversation_participants
// 的 member_type CHECK 约束,processor 走 log + return 路径,根本不进入写事务。
// 这是 fail-fast 行为:非法输入尽早暴露,不留下任何副作用。
//
// 注意:本测试不验证「事务回滚」(事务根本没开),验证的是「无副作用」。
// 真正的事务回滚路径(CreateTx 失败 → defer Rollback)在 spec §3.3 数据流里,
// 由 TestProcessor_Tx_BeginCreateUpdateCommit 的反向用例覆盖(此处从略)。
func TestProcessor_HandleIncoming_AbortsOnInvalidSenderType(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	// senderType="invalid":PersistAndDispatch 内 participant Exists 校验失败
	p.HandleIncoming(t.Context(), "invalid", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageCreate,
		D:  convPayload(fix.convID, msgContent("should abort")),
	})

	// 验证 messages 表无残留
	msgs, err := fix.msgRepo.ListByConversation(t.Context(), fix.convID, fix.userID, "user", 100, 0)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(msgs) != 0 {
		t.Errorf("非法 sender_type 处理后 messages 不应有数据,实际: %d 条", len(msgs))
	}

	// 验证 unread_count 不变(user 仍 0)
	userP, _ := fix.participantRp.Get(t.Context(), fix.convID, fix.userID, "user")
	if userP.UnreadCount != 0 {
		t.Errorf("非法 sender_type 处理后 unread 不应变化: 期望 0, 实际 %d", userP.UnreadCount)
	}
}

// TestProcessor_Tx_BeginCreateCommit 验证事务 API happy path:
// convRepo.BeginTx → msgRepo.CreateTx → tx.Commit 之后 messages 表有新行。
// 这是 HandleIncoming 事务路径的"组件级"覆盖,避免依赖 hub。
// (017 删 last_message_content 缓存后,事务不再调 UpdateLastMessageTx;
//
//	会话列表改子查询实时算,见 repository/conversation_repo_test.go。)
func TestProcessor_Tx_BeginCreateCommit(t *testing.T) {
	fix := seedDM(t)

	content := msgContent("tx component")

	tx, err := fix.convRepo.BeginTx(t.Context())
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	defer tx.Rollback()

	msg, err := fix.msgRepo.CreateTx(t.Context(), tx, fix.convID, "user", fix.userID, content)
	if err != nil {
		t.Fatalf("CreateTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit 失败: %v", err)
	}

	// 验证 messages 表
	msgs, _ := fix.msgRepo.ListByConversation(t.Context(), fix.convID, fix.userID, "user", 100, 0)
	if len(msgs) != 1 || msgs[0].ID != msg.ID {
		t.Errorf("消息未持久化: %+v", msgs)
	}
}

// TestProcessor_Tx_RollsBackOnCreateTxFKFailure 验证事务回滚路径
// (spec §3.3 数据流的「CreateTx 失败 → defer tx.Rollback()」分支)。
//
// 触发:用不存在的 conversation_id 让 CreateTx 命中 messages.conversation_id
// 的 FK 约束(001_init.sql)。失败后 defer Rollback 兜底,避免半提交事务。
//
// 注意:本测试不通过 HandleIncoming(它内部用合法 convID),而是直接走 repo
// 事务路径,覆盖 CreateTx 失败的最小复现。HandleIncoming 的早退路径
// 由 TestProcessor_HandleIncoming_AbortsOnInvalidSenderType 覆盖。
func TestProcessor_Tx_RollsBackOnCreateTxFKFailure(t *testing.T) {
	fix := seedDM(t)

	tx, err := fix.convRepo.BeginTx(t.Context())
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	defer tx.Rollback()

	// 用不存在的 conversation_id 触发 FK 约束失败
	invalidConvID := "00000000-0000-0000-0000-000000000000"
	_, err = fix.msgRepo.CreateTx(t.Context(), tx, invalidConvID, "user", fix.userID, msgContent("rollback"))
	if err == nil {
		t.Fatalf("期望 CreateTx 失败(FK 约束), 实际成功")
	}

	// defer Rollback 兜底,无需显式调;验证真实 convID 下无消息残留
	msgs, _ := fix.msgRepo.ListByConversation(t.Context(), fix.convID, fix.userID, "user", 100, 0)
	if len(msgs) != 0 {
		t.Errorf("FK 失败回滚后 messages 不应有数据, 实际: %d 条", len(msgs))
	}
}

// TestProcessor_HandleIncoming_AgentAlwaysIncrUnread 验证:agent 发消息一律计未读,
// 不再依赖 user 是否「正在看会话」。这是 participants 模型下的标准口径
// (IncrUnreadTx 无条件给非 sender 全员 +1)。
func TestProcessor_HandleIncoming_AgentAlwaysIncrUnread(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageCreate,
		D:  convPayload(fix.convID, msgContent("agent reply")),
	})

	// 断言:user.unread_count == 1（直接查 conversation_participants 维度）
	userP, err := fix.participantRp.Get(t.Context(), fix.convID, fix.userID, "user")
	if err != nil {
		t.Fatalf("participantRp.Get 失败: %v", err)
	}
	if userP.UnreadCount != 1 {
		t.Errorf("agent 消息应一律 +1 unread, 实际: %d", userP.UnreadCount)
	}
}

// createImageFile 往 files 表插一条带 width/height 的图片记录，返回 fileID。
// 复用 repository.CreateFileParams，供 enhanceContentFromFile 测试。
func createImageFile(t *testing.T, fileRepo *repository.FileRepo, ownerID string, w, h int) string {
	t.Helper()
	f, err := fileRepo.Create(t.Context(), repository.CreateFileParams{
		OwnerID:       ownerID,
		Filename:      "test.png",
		MimeType:      "image/png",
		Size:          100,
		StoragePath:   "abc.png",
		ThumbnailPath: nil,
		Width:         &w,
		Height:        &h,
	})
	if err != nil {
		t.Fatalf("Create file 失败: %v", err)
	}
	return f.ID
}

// TestEnhanceContentFromFile_FillsWidthHeight 主路径：image 消息缺宽高 → 从 files 表补全。
func TestEnhanceContentFromFile_FillsWidthHeight(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	fileID := createImageFile(t, fix.fileRepo, fix.userID, 1080, 1920)

	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "image",
		"data":     map[string]interface{}{"file_id": fileID},
	})

	got := p.enhanceContentFromFile(t.Context(), json.RawMessage(content))

	var parsed struct {
		Data struct {
			FileID string `json:"file_id"`
			Width  int    `json:"width"`
			Height int    `json:"height"`
		} `json:"data"`
	}
	if err := json.Unmarshal(got, &parsed); err != nil {
		t.Fatalf("解析增强后 content 失败: %v", err)
	}
	if parsed.Data.Width != 1080 || parsed.Data.Height != 1920 {
		t.Errorf("宽高未补全: width=%d height=%d, want 1080/1920", parsed.Data.Width, parsed.Data.Height)
	}
	if parsed.Data.FileID != fileID {
		t.Errorf("file_id 被篡改: %s", parsed.Data.FileID)
	}
}

// TestEnhanceContentFromFile_Idempotent 已带宽高的消息 → 幂等跳过，不查 DB。
func TestEnhanceContentFromFile_Idempotent(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	fileID := createImageFile(t, fix.fileRepo, fix.userID, 1080, 1920)

	// content 已带 width/height（故意写与库不同的值，验证不被覆盖）
	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "image",
		"data": map[string]interface{}{
			"file_id": fileID,
			"width":   500,
			"height":  500,
		},
	})
	got := p.enhanceContentFromFile(t.Context(), json.RawMessage(content))

	var parsed struct {
		Data struct {
			Width  int `json:"width"`
			Height int `json:"height"`
		} `json:"data"`
	}
	json.Unmarshal(got, &parsed)
	// 应保留原值 500/500，不被库里的 1080/1920 覆盖
	if parsed.Data.Width != 500 || parsed.Data.Height != 500 {
		t.Errorf("幂等失败: 宽高被覆盖为 %d/%d, 应保留 500/500", parsed.Data.Width, parsed.Data.Height)
	}
}

// TestEnhanceContentFromFile_FailSoft 各种异常情况都不阻断，返回原 content。
func TestEnhanceContentFromFile_FailSoft(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	cases := []struct {
		name    string
		content map[string]interface{}
	}{
		{
			name: "非 image 消息",
			content: map[string]interface{}{
				"msg_type": "text",
				"data":     map[string]interface{}{"text": "hi"},
			},
		},
		{
			name: "image 但无 file_id",
			content: map[string]interface{}{
				"msg_type": "image",
				"data":     map[string]interface{}{},
			},
		},
		{
			name: "file_id 不存在",
			content: map[string]interface{}{
				"msg_type": "image",
				"data":     map[string]interface{}{"file_id": "00000000-0000-0000-0000-000000000000"},
			},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			orig, _ := json.Marshal(tc.content)
			got := p.enhanceContentFromFile(t.Context(), json.RawMessage(orig))
			// 应原样返回（fail-soft 不阻断）
			if string(got) != string(orig) {
				t.Errorf("fail-soft 失败: 异常情况应原样返回\ngot:  %s\nwant: %s", got, orig)
			}
		})
	}

	// 单独测：files 表有记录但 width/height 为 NULL（非图片文件上传的场景）
	f, err := fix.fileRepo.Create(t.Context(), repository.CreateFileParams{
		OwnerID:     fix.userID,
		Filename:    "note.txt",
		MimeType:    "text/plain",
		Size:        10,
		StoragePath: "note.txt",
	})
	if err != nil {
		t.Fatalf("Create 无宽高文件失败: %v", err)
	}
	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "image",
		"data":     map[string]interface{}{"file_id": f.ID},
	})
	got := p.enhanceContentFromFile(t.Context(), json.RawMessage(content))
	// files 表该记录 width/height 为 NULL，应原样返回不补
	var parsed struct {
		Data struct {
			Width  *int `json:"width"`
			Height *int `json:"height"`
		} `json:"data"`
	}
	json.Unmarshal(got, &parsed)
	if parsed.Data.Width != nil || parsed.Data.Height != nil {
		t.Errorf("NULL 宽高不应被补全: width=%v height=%v", parsed.Data.Width, parsed.Data.Height)
	}
}

// TestEnhanceContentFromFile_FillsFileSizeAndMimeType file 消息主路径：
// 缺 file_size/mime_type 时从 files 表权威值补全。
// 走 fileRepo.Create 直接落 DB（无需实际文件落盘，files 表只是元数据）。
func TestEnhanceContentFromFile_FillsFileSizeAndMimeType(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	// 直接 INSERT files 表（无需磁盘文件，fileRepo.Create 只写元数据）
	pdfFile, err := fix.fileRepo.Create(t.Context(), repository.CreateFileParams{
		OwnerID:     fix.userID,
		Filename:    "test.pdf",
		MimeType:    "application/pdf",
		Size:        12345,
		StoragePath: "uploads/test.pdf",
	})
	if err != nil {
		t.Fatalf("fileRepo.Create 失败: %v", err)
	}

	// 构造 file 类型消息，data 只含 file_id 和 filename（缺 file_size/mime_type）
	raw, _ := json.Marshal(map[string]interface{}{
		"msg_type": "file",
		"data": map[string]interface{}{
			"file_id":  pdfFile.ID,
			"filename": "test.pdf",
		},
	})
	enhanced := p.enhanceContentFromFile(t.Context(), json.RawMessage(raw))

	var got struct {
		MsgType string `json:"msg_type"`
		Data    struct {
			FileID   string `json:"file_id"`
			Filename string `json:"filename"`
			FileSize int64  `json:"file_size"`
			MimeType string `json:"mime_type"`
		} `json:"data"`
	}
	if err := json.Unmarshal(enhanced, &got); err != nil {
		t.Fatalf("unmarshal enhanced 失败: %v", err)
	}
	if got.Data.FileSize != 12345 {
		t.Errorf("file_size: got %d, want 12345", got.Data.FileSize)
	}
	if got.Data.MimeType != "application/pdf" {
		t.Errorf("mime_type: got %q, want application/pdf", got.Data.MimeType)
	}
	if got.Data.Filename != "test.pdf" {
		t.Errorf("filename: got %q, want test.pdf", got.Data.Filename)
	}
	if got.Data.FileID != pdfFile.ID {
		t.Errorf("file_id 被篡改: got %q, want %q", got.Data.FileID, pdfFile.ID)
	}
}

// TestHandleIncoming_RejectsLegacyUserIDPayload 验证旧协议 payload(含 user_id,无 conversation_id)
// 被静默丢弃:无消息持久化,无 unread 变化。
// 协议迁移后,所有 send 路径必须走 conversation_id,旧 user_id/agent_id 路径不再支持。
func TestHandleIncoming_RejectsLegacyUserIDPayload(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageCreate,
		D:  legacyAgentToUserPayload(fix.userID, msgContent("legacy")),
	})

	msgs, err := fix.msgRepo.ListByConversation(t.Context(), fix.convID, fix.userID, "user", 100, 0)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(msgs) != 0 {
		t.Errorf("旧协议 payload 不应被持久化,实际 %d 条", len(msgs))
	}
	userP, _ := fix.participantRp.Get(t.Context(), fix.convID, fix.userID, "user")
	if userP.UnreadCount != 0 {
		t.Errorf("旧协议 payload 不应改 unread: 期望 0 实际 %d", userP.UnreadCount)
	}
}

// TestHandleIncoming_RequiresConversationID 验证 payload 缺 conversation_id 时静默 return。
func TestHandleIncoming_RequiresConversationID(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	// 只含 content,无 conversation_id
	d, _ := json.Marshal(map[string]interface{}{
		"content": msgContent("no conv"),
	})
	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageCreate,
		D:  d,
	})

	msgs, _ := fix.msgRepo.ListByConversation(t.Context(), fix.convID, fix.userID, "user", 100, 0)
	if len(msgs) != 0 {
		t.Errorf("缺 conversation_id 时不应持久化,实际 %d 条", len(msgs))
	}
}

// TestHandleIncoming_UserParentRootIgnored 验证 server I-1 安全守卫:
// user 经 WS 发消息时即使 content 塞 parent_msg_id/root_msg_id 也被忽略(强制 nil),
// 与 SendHandler(HTTP user 路径传 nil,nil)对齐。否则 user 能发「幽灵消息」
// (不进主列表、不给对方未读)。
//
// 对照:agent 路径走 ExtractParentRoot 正常透传(由其他测试覆盖)。
func TestHandleIncoming_UserParentRootIgnored(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	// 先让 agent 发一条顶层消息,作为 user 伪造 parent/root 的目标(必须存在 + 属本会话,
	// 否则 validateParentRoot 会因「不存在/不属于会话」早退,无法区分是守卫挡的还是校验挡的)。
	rootContent, _ := json.Marshal(map[string]interface{}{
		"msg_type": "tool_card",
		"data": map[string]interface{}{
			"name": "task", "status": "completed",
			"parent_msg_id": nil, "root_msg_id": nil,
		},
	})
	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch, T: model.EventMessageCreate,
		D: convPayload(fix.convID, rootContent),
	})
	topMsgs, _ := fix.msgRepo.ListByConversation(t.Context(), fix.convID, fix.agentID, "agent", 10, 0)
	if len(topMsgs) != 1 {
		t.Fatalf("seed 顶层消息失败,期望 1 条,实际 %d", len(topMsgs))
	}
	topID := topMsgs[0].ID

	// user 发消息,content 内塞 parent_msg_id/root_msg_id 指向刚建的顶层消息。
	// 守卫应忽略(senderType=user),落库 parent/root 为 NULL,消息正常进主列表。
	userContent, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data": map[string]interface{}{
			"text":          "我试试能不能发幽灵消息",
			"parent_msg_id": topID,
			"root_msg_id":   topID,
		},
	})
	p.HandleIncoming(t.Context(), "user", fix.userID, &model.WSMessage{
		Op: model.OpDispatch, T: model.EventMessageCreate,
		D: convPayload(fix.convID, userContent),
	})

	// 断言:user 消息落库,且 parent_msg_id/root_msg_id 为空(守卫生效)。
	// ListByConversation 用 parent_msg_id IS NULL 过滤,若守卫未挡会查不到(变幽灵)。
	userMsgs, _ := fix.msgRepo.ListByConversation(t.Context(), fix.convID, fix.userID, "user", 100, 0)
	var userMsg *model.Message
	for i := range userMsgs {
		if userMsgs[i].SenderType == "user" {
			userMsg = &userMsgs[i]
			break
		}
	}
	if userMsg == nil {
		t.Fatalf("user 消息未落库或被当幽灵过滤,守卫可能误把 content 一并吞掉")
	}
	if userMsg.ParentMsgID != nil || userMsg.RootMsgID != nil {
		t.Errorf("user 路径 parent/root 应被强制 nil,实际 parent=%v root=%v",
			userMsg.ParentMsgID, userMsg.RootMsgID)
	}
}

// quoteContent 构造带 quote 子对象的 text 消息 content JSON。
// quoteMessageID 即被引用的 message_id。
func quoteContent(text, quoteMessageID string) json.RawMessage {
	c, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data": map[string]interface{}{
			"text":  text,
			"quote": map[string]interface{}{"message_id": quoteMessageID},
		},
	})
	return c
}

// quoteContentWithForgedFields 构造带 quote 子对象的 text 消息 content,
// 其中 quote 内除 message_id 外还塞入 client 伪造的 sender_* / msg_type / preview 字段,
// 用来断言 server 端富化覆盖了所有这些字段。
func quoteContentWithForgedFields(text, quoteMessageID string) json.RawMessage {
	c, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data": map[string]interface{}{
			"text": text,
			"quote": map[string]interface{}{
				"message_id":  quoteMessageID,
				"sender_type": "forged_type",
				"sender_id":   "forged-id",
				"sender_name": "伪造",
				"msg_type":    "forged_msg_type",
				"preview":     "伪造预览",
			},
		},
	})
	return c
}

// contentByType 构造指定 msg_type 的 content JSON,用于 preview 抽取测试。
// dataFields 直接 marshal 进 data 子对象。
func contentByType(msgType string, dataFields map[string]interface{}) json.RawMessage {
	c, _ := json.Marshal(map[string]interface{}{
		"msg_type": msgType,
		"data":     dataFields,
	})
	return c
}

// parseQuote 从持久化消息 content 里抽出 data.quote 子对象,方便断言富化结果。
func parseQuote(t *testing.T, raw json.RawMessage) map[string]interface{} {
	t.Helper()
	var parsed struct {
		Data struct {
			Quote map[string]interface{} `json:"quote"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil {
		t.Fatalf("解析 content 失败: %v", err)
	}
	if parsed.Data.Quote == nil {
		t.Fatalf("content.data.quote 缺失")
	}
	return parsed.Data.Quote
}

// TestProcessMessageQuoteNotFound 验证:content.data.quote.message_id 指向不存在的消息时,
// PersistAndDispatch 应 fail-fast 返回错误,不写 messages 表,不广播。
//
// Task 2 仅校验,不富化(Task 3 才富化)。本测试覆盖「不存在」分支。
func TestProcessMessageQuoteNotFound(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	// 被引用 message_id 是不存在的 UUID
	nonexistentID := "00000000-0000-0000-0000-000000000000"
	content := quoteContent("reply to ghost", nonexistentID)

	_, err := p.PersistAndDispatch(t.Context(), fix.convID, "user", fix.userID, content, nil, nil)
	if err == nil {
		t.Fatalf("期望 quote 引用不存在的消息时返 error,实际 nil")
	}

	// 验证 messages 表无新行
	msgs, err := fix.msgRepo.ListByConversation(t.Context(), fix.convID, fix.userID, "user", 100, 0)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(msgs) != 0 {
		t.Errorf("校验失败时不应持久化消息,实际 %d 条", len(msgs))
	}

	// 验证 unread_count 不变(确保 dispatch 路径未触达)
	userP, _ := fix.participantRp.Get(t.Context(), fix.convID, fix.userID, "user")
	if userP.UnreadCount != 0 {
		t.Errorf("校验失败不应改 unread: 期望 0 实际 %d", userP.UnreadCount)
	}
}

// TestProcessMessageQuoteCrossConv 验证:content.data.quote.message_id 指向另一会话的消息时,
// PersistAndDispatch 应 fail-fast 返回错误,不写 messages 表。
//
// 这是 IDOR 防护的关键:防止 sender 伪造 quote.message_id 引用其他会话的消息
// (可能泄漏被引用消息的存在性,以及富化后还会带 sender_name / preview 等快照字段)。
func TestProcessMessageQuoteCrossConv(t *testing.T) {
	// 两个独立 DM 会话(convA 和 convB),不同 user/agent 组合
	fixA := seedDM(t)
	fixB := seedDM(t)

	// 在 convB 里先放一条消息,作为「跨会话引用」的目标
	targetInB, err := fixB.msgRepo.Create(
		t.Context(), fixB.convID, "user", fixB.userID, msgContent("secret in conv B"),
	)
	if err != nil {
		t.Fatalf("在 convB 建目标消息失败: %v", err)
	}

	p := newProcessorWithNilHub(t, fixA)
	// 在 convA 里尝试引用 convB 的消息 — 应失败
	content := quoteContent("reply with cross-conv quote", targetInB.ID)

	_, err = p.PersistAndDispatch(t.Context(), fixA.convID, "user", fixA.userID, content, nil, nil)
	if err == nil {
		t.Fatalf("期望跨会话引用返 error,实际 nil")
	}

	// 验证 convA 无新行(原 0 行,不应被写入)
	msgsInA, err := fixA.msgRepo.ListByConversation(t.Context(), fixA.convID, fixA.userID, "user", 100, 0)
	if err != nil {
		t.Fatalf("ListByConversation convA 失败: %v", err)
	}
	if len(msgsInA) != 0 {
		t.Errorf("跨会话引用失败时 convA 不应有新消息,实际 %d 条", len(msgsInA))
	}

	// 验证 convB 行数仍为 1(原 targetInB),没有因为引用而新增
	msgsInB, err := fixB.msgRepo.ListByConversation(t.Context(), fixB.convID, fixB.userID, "user", 100, 0)
	if err != nil {
		t.Fatalf("ListByConversation convB 失败: %v", err)
	}
	if len(msgsInB) != 1 {
		t.Errorf("convB 不应受影响: 期望 1 条(targetInB),实际 %d 条", len(msgsInB))
	}
}

// TestExtractParentRoot 单元测试 ExtractParentRoot 函数。
// 覆盖分支:两字段都 nil / 仅 parent / 仅 root / 双字段 / content 非 JSON object /
// 再次 unmarshal 失败不可能构造(json.Unmarshal 失败时第一次就返 nil,这里跳过)。
func TestExtractParentRoot(t *testing.T) {
	pid := "p"
	rid := "r"

	tests := []struct {
		name        string
		content     string
		wantParent  *string
		wantRoot    *string
		wantCleaned bool // true=cleanedContent 应不含 parent/root 字段
	}{
		{
			name:        "两字段都缺",
			content:     `{"msg_type":"text","data":{"text":"hi"}}`,
			wantParent:  nil,
			wantRoot:    nil,
			wantCleaned: false,
		},
		{
			name:        "仅 parent",
			content:     `{"msg_type":"text","parent_msg_id":"p","data":{}}`,
			wantParent:  &pid,
			wantRoot:    nil,
			wantCleaned: true,
		},
		{
			name:        "仅 root",
			content:     `{"msg_type":"text","root_msg_id":"r","data":{}}`,
			wantParent:  nil,
			wantRoot:    &rid,
			wantCleaned: true,
		},
		{
			name:        "双字段",
			content:     `{"parent_msg_id":"p","root_msg_id":"r","msg_type":"text"}`,
			wantParent:  &pid,
			wantRoot:    &rid,
			wantCleaned: true,
		},
		{
			name:        "非 JSON object(数组)",
			content:     `[1,2,3]`,
			wantParent:  nil,
			wantRoot:    nil,
			wantCleaned: false,
		},
		{
			name:        "非 JSON(乱字符串)",
			content:     `not json at all`,
			wantParent:  nil,
			wantRoot:    nil,
			wantCleaned: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			parent, root, cleaned := ExtractParentRoot([]byte(tt.content))
			if (parent == nil) != (tt.wantParent == nil) {
				t.Errorf("parent: got %v, want %v", parent, tt.wantParent)
			}
			if parent != nil && *parent != *tt.wantParent {
				t.Errorf("parent value: got %q, want %q", *parent, *tt.wantParent)
			}
			if (root == nil) != (tt.wantRoot == nil) {
				t.Errorf("root: got %v, want %v", root, tt.wantRoot)
			}
			if root != nil && *root != *tt.wantRoot {
				t.Errorf("root value: got %q, want %q", *root, *tt.wantRoot)
			}
			if tt.wantCleaned {
				var check map[string]json.RawMessage
				if err := json.Unmarshal(cleaned, &check); err != nil {
					t.Fatalf("cleaned 不是合法 JSON: %v", err)
				}
				if _, exists := check["parent_msg_id"]; exists {
					t.Errorf("cleaned 不应含 parent_msg_id")
				}
				if _, exists := check["root_msg_id"]; exists {
					t.Errorf("cleaned 不应含 root_msg_id")
				}
			}
		})
	}
}

// TestProcessMessageParentRootCrossConv 验证 IDOR 防护:
// sender 伪造 parent_msg_id / root_msg_id 指向其他会话的消息时,
// PersistAndDispatch 应 fail-fast 返回错误,不写 messages 表。
//
// 对称 TestProcessMessageQuoteCrossConv:parent/root 与 quote 共享同一安全口径,
// FK 约束只挡「目标消息不存在」,归属校验由 validateParentRoot 补齐。
func TestProcessMessageParentRootCrossConv(t *testing.T) {
	fixA := seedDM(t)
	fixB := seedDM(t)

	// 在 convB 放一条主对话流消息(无 parent),作为「跨会话 parent」目标
	targetInB, err := fixB.msgRepo.Create(
		t.Context(), fixB.convID, "user", fixB.userID, msgContent("secret parent in conv B"),
	)
	if err != nil {
		t.Fatalf("在 convB 建目标消息失败: %v", err)
	}

	p := newProcessorWithNilHub(t, fixA)
	content := msgContent("child event referencing cross-conv parent")

	// 在 convA 发 child 事件,parent/root 都指向 convB 的消息
	_, err = p.PersistAndDispatch(
		t.Context(), fixA.convID, "agent", fixA.agentID, content,
		&targetInB.ID, &targetInB.ID,
	)
	if err == nil {
		t.Fatalf("期望跨会话 parent/root 返 error,实际 nil")
	}

	// convA 不应有新消息
	msgsInA, err := fixA.msgRepo.ListByConversation(t.Context(), fixA.convID, fixA.userID, "user", 100, 0)
	if err != nil {
		t.Fatalf("ListByConversation convA 失败: %v", err)
	}
	if len(msgsInA) != 0 {
		t.Errorf("跨会话 parent 校验失败时 convA 不应有新消息,实际 %d 条", len(msgsInA))
	}
}

// TestProcessMessageParentRootRootMustBeTopLevel 验证:root 消息必须是顶层
// (root.parent_msg_id IS NULL),防把中层消息冒充 root 拼错树。
func TestProcessMessageParentRootRootMustBeTopLevel(t *testing.T) {
	fix := seedDM(t)

	// 先建一条顶层 task 卡片消息(模拟 plugin 发的 task 卡片)
	rootMsg, err := fix.msgRepo.Create(
		t.Context(), fix.convID, "agent", fix.agentID, msgContent("top task card"),
	)
	if err != nil {
		t.Fatalf("建 root 消息失败: %v", err)
	}

	// 以 rootMsg 为 parent 建一条子事件(就是 mid 层)
	mid, err := fix.msgRepo.CreateWithParent(
		t.Context(), fix.convID, "agent", fix.agentID, msgContent("mid child"),
		rootMsg.ID, rootMsg.ID,
	)
	if err != nil {
		t.Fatalf("建 mid 子事件失败: %v", err)
	}

	p := newProcessorWithNilHub(t, fix)
	content := msgContent("nested child event")

	// 用 mid 作为 root(中层冒充顶层) → 应失败
	_, err = p.PersistAndDispatch(
		t.Context(), fix.convID, "agent", fix.agentID, content,
		&mid.ID, &mid.ID, // parent=mid, root=mid,但 mid 自己有 parent
	)
	if err == nil {
		t.Fatalf("期望 root 非顶层时返 error,实际 nil")
	}
}

// TestProcessMessageChildEventDeliveryMarkedRead 验证:子 agent 事件(parentMsgID != nil)
// 仍创建 delivery 记录,但 read_at 直接标 NOW()(已读态),不污染主列表未读角标,
// 避免孤儿未读 delivery 累积(用户永远点不到这条消息去标 read)。
func TestProcessMessageChildEventDeliveryMarkedRead(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	// 先建一条顶层 task 卡片作为 parent/root
	parent, err := fix.msgRepo.Create(
		t.Context(), fix.convID, "agent", fix.agentID, msgContent("top task"),
	)
	if err != nil {
		t.Fatalf("建 parent 失败: %v", err)
	}
	content := msgContent("child event")
	msg, err := p.PersistAndDispatch(
		t.Context(), fix.convID, "agent", fix.agentID, content,
		&parent.ID, &parent.ID,
	)
	if err != nil {
		t.Fatalf("子事件发送失败: %v", err)
	}

	// 查 message_deliveries:子事件应给非 sender 全员插记录,且 read_at 非 NULL
	var readAt sql.NullTime
	err = fix.db.QueryRowContext(
		t.Context(),
		`SELECT read_at FROM message_deliveries WHERE message_id = $1 AND recipient_id = $2 AND recipient_type = 'user'`,
		msg.ID, fix.userID,
	).Scan(&readAt)
	if err != nil {
		t.Fatalf("查子事件 delivery 失败: %v", err)
	}
	if !readAt.Valid {
		t.Fatalf("子事件 delivery 应标 read_at(已读态),实际为 NULL(孤儿未读)")
	}
}

// TestProcessMessageParentRootChainConsistency 验证树链一致性:
// 当 parent != root(多层嵌套)时,parent 必须挂在同一 root 子树下(parent.root_msg_id == rootMsgID)。
// 防止 sender 拿同会话两个顶层 task 拼出断裂的消息树。
func TestProcessMessageParentRootChainConsistency(t *testing.T) {
	fix := seedDM(t)

	// 建两个独立的顶层 task 卡片(模拟同会话两个不同的子 agent 任务)
	rootA, err := fix.msgRepo.Create(
		t.Context(), fix.convID, "agent", fix.agentID, msgContent("top task A"),
	)
	if err != nil {
		t.Fatalf("建 rootA 失败: %v", err)
	}
	rootB, err := fix.msgRepo.Create(
		t.Context(), fix.convID, "agent", fix.agentID, msgContent("top task B"),
	)
	if err != nil {
		t.Fatalf("建 rootB 失败: %v", err)
	}
	// rootA 下挂一条子事件(模拟 rootA 子 agent 输出)
	childOfA, err := fix.msgRepo.CreateWithParent(
		t.Context(), fix.convID, "agent", fix.agentID, msgContent("child of A"),
		rootA.ID, rootA.ID,
	)
	if err != nil {
		t.Fatalf("建 childOfA 失败: %v", err)
	}

	p := newProcessorWithNilHub(t, fix)
	content := msgContent("nested child")

	// 用 childOfA 作 parent,但 root 写成 rootB(不一致) → 应失败
	_, err = p.PersistAndDispatch(
		t.Context(), fix.convID, "agent", fix.agentID, content,
		&childOfA.ID, &rootB.ID,
	)
	if err == nil {
		t.Fatalf("期望 parent/root 树链不一致时返 error,实际 nil")
	}

	// 用 childOfA 作 parent,rootA 作 root(一致) → 应成功
	_, err = p.PersistAndDispatch(
		t.Context(), fix.convID, "agent", fix.agentID, content,
		&childOfA.ID, &rootA.ID,
	)
	if err != nil {
		t.Fatalf("一致树链应成功,实际: %v", err)
	}
}

// TestProcessMessageQuoteEnrichment 验证:client 传入 quote(仅 message_id 真实,
// 其他字段如 sender_name 是伪造的)→ 持久化后 content.data.quote 的所有字段
// 都被 server 权威值覆盖。
//
// 富化字段:
//   - sender_type / sender_id / sender_name: 来自被引用消息(从 DB + 表 JOIN 查)
//   - msg_type: 被引用消息的原始 msg_type(从其 content JSONB 解析)
//   - preview: 按 msg_type 抽取的单行预览
func TestProcessMessageQuoteEnrichment(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	// 先在 conv 里放一条 agent 发的 text 消息作为引用目标
	target, err := fix.msgRepo.Create(
		t.Context(), fix.convID, "agent", fix.agentID, msgContent("原消息内容"),
	)
	if err != nil {
		t.Fatalf("建目标消息失败: %v", err)
	}

	// user 引用这条消息,故意把 sender_name 等字段塞成伪造值
	content := quoteContentWithForgedFields("reply to agent", target.ID)

	_, err = p.PersistAndDispatch(t.Context(), fix.convID, "user", fix.userID, content, nil, nil)
	if err != nil {
		t.Fatalf("PersistAndDispatch 失败: %v", err)
	}

	// 取最新持久化的消息(应有 2 条:target + reply)
	msgs, err := fix.msgRepo.ListByConversation(t.Context(), fix.convID, fix.userID, "user", 100, 0)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(msgs) != 2 {
		t.Fatalf("期望 2 条消息(target+reply),实际 %d", len(msgs))
	}
	// ListByConversation 是 newest first,reply 是后发的应排第 0
	reply := msgs[0]
	if reply.SenderType != "user" || reply.SenderID != fix.userID {
		t.Fatalf("取错消息: got sender=%s/%s, want user/%s",
			reply.SenderType, reply.SenderID, fix.userID)
	}

	quote := parseQuote(t, reply.Content)

	// message_id 应保留(client 传入的)
	if quote["message_id"] != target.ID {
		t.Errorf("message_id 应保留为被引用 ID: got %v, want %s",
			quote["message_id"], target.ID)
	}
	// sender_type / sender_id 来自被引用消息(target 是 agent 发的)
	if quote["sender_type"] != "agent" {
		t.Errorf("sender_type 应为 agent(被引用消息真实 sender): got %v", quote["sender_type"])
	}
	if quote["sender_id"] != fix.agentID {
		t.Errorf("sender_id 应为 agent_id: got %v, want %s", quote["sender_id"], fix.agentID)
	}
	// sender_name 应被 server 权威值覆盖(seedAgent 时 name="Agent"+shortName)
	if quote["sender_name"] == "伪造" {
		t.Errorf("sender_name 未被覆盖,仍是 client 伪造值 %q", quote["sender_name"])
	}
	if quote["sender_name"] == "" {
		t.Errorf("sender_name 应填入 agent 名字,实际为空")
	}
	// msg_type 应是被引用消息的真实 msg_type(text),不是伪造的 forged_msg_type
	if quote["msg_type"] != "text" {
		t.Errorf("msg_type 应为 text(被引用消息真实类型): got %v", quote["msg_type"])
	}
	// preview 应按 text 类型抽取(原文前 50 字)
	if quote["preview"] != "原消息内容" {
		t.Errorf("preview 应为被引用消息原文: got %v, want %q",
			quote["preview"], "原消息内容")
	}
}

// TestProcessMessageQuoteClientFieldsOverwritten 显式断言:client 在 quote 里
// 塞入伪造的 sender_type / sender_id / sender_name / msg_type / preview 全部
// 被 server 权威值覆盖。这是 TestProcessMessageQuoteEnrichment 的强化版,
// 单独存在让回归时一眼能看出是「字段覆盖」语义被破坏。
func TestProcessMessageQuoteClientFieldsOverwritten(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	target, err := fix.msgRepo.Create(
		t.Context(), fix.convID, "agent", fix.agentID, msgContent("真实原文"),
	)
	if err != nil {
		t.Fatalf("建目标消息失败: %v", err)
	}

	content := quoteContentWithForgedFields("overwrite check", target.ID)
	_, err = p.PersistAndDispatch(t.Context(), fix.convID, "user", fix.userID, content, nil, nil)
	if err != nil {
		t.Fatalf("PersistAndDispatch 失败: %v", err)
	}

	msgs, _ := fix.msgRepo.ListByConversation(t.Context(), fix.convID, fix.userID, "user", 100, 0)
	if len(msgs) != 2 {
		t.Fatalf("期望 2 条,实际 %d", len(msgs))
	}
	quote := parseQuote(t, msgs[0].Content)

	// 5 个字段必须全部不等于 client 伪造值
	forbidden := map[string]string{
		"sender_type": "forged_type",
		"sender_id":   "forged-id",
		"sender_name": "伪造",
		"msg_type":    "forged_msg_type",
		"preview":     "伪造预览",
	}
	for field, bad := range forbidden {
		if quote[field] == bad {
			t.Errorf("字段 %s 未被 server 覆盖,仍是 client 伪造值 %q", field, bad)
		}
	}
	// 同时确认 server 值确实填进去了
	if quote["sender_type"] != "agent" {
		t.Errorf("sender_type 期望 agent, got %v", quote["sender_type"])
	}
	if quote["msg_type"] != "text" {
		t.Errorf("msg_type 期望 text, got %v", quote["msg_type"])
	}
	if quote["preview"] != "真实原文" {
		t.Errorf("preview 期望「真实原文」, got %v", quote["preview"])
	}
}

// TestProcessMessageQuotePreviewByTextType 覆盖 6 种 msg_type 的 preview 抽取规则。
// 表驱动:每条用例预先建对应类型的消息,然后用 quote 引用它,断言 preview 字段。
func TestProcessMessageQuotePreviewByTextType(t *testing.T) {
	cases := []struct {
		name      string
		msgType   string
		dataField map[string]interface{}
		wantPrev  string
	}{
		{
			name:    "text 短文",
			msgType: "text",
			dataField: map[string]interface{}{
				"text": "hello world",
			},
			wantPrev: "hello world",
		},
		{
			name:    "text 换行折叠成空格",
			msgType: "text",
			dataField: map[string]interface{}{
				"text": "第一行\n第二行",
			},
			wantPrev: "第一行 第二行",
		},
		{
			name:    "text 长文截断 50 字 + 省略号",
			msgType: "text",
			dataField: map[string]interface{}{
				"text": strings.Repeat("一二三四五六七八九十", 6), // 60 字符
			},
			// rune 截断到 50 + "..."
			wantPrev: strings.Repeat("一二三四五六七八九十", 5) + "...",
		},
		{
			name:    "markdown 剥除语法",
			msgType: "markdown",
			dataField: map[string]interface{}{
				"text": "**bold** _italic_ `code`",
			},
			wantPrev: "bold italic code",
		},
		{
			// M1: markdown preview 应折叠换行(符合 extractPreview 文档「单行预览」约束)
			name:    "markdown 换行折叠",
			msgType: "markdown",
			dataField: map[string]interface{}{
				"text": "# 标题\n\n段落",
			},
			// stripMarkdown 保留 # 段落语法(刻意),\n\n 折叠成空格
			wantPrev: "# 标题  段落",
		},
		{
			name:    "image 占位",
			msgType: "image",
			dataField: map[string]interface{}{
				"file_id": "fake-id",
			},
			wantPrev: "[图片]",
		},
		{
			name:    "file 占位带文件名",
			msgType: "file",
			dataField: map[string]interface{}{
				"file_id":  "fake-id",
				"filename": "report.pdf",
			},
			wantPrev: "[文件] report.pdf",
		},
		{
			// I2: mixed 类型有 data.text 时抽前 50 字(与 text/markdown 对称)
			name:    "mixed 有文本",
			msgType: "mixed",
			dataField: map[string]interface{}{
				"text": "这是 mixed 的描述文字",
			},
			wantPrev: "这是 mixed 的描述文字",
		},
		{
			// I2 fallback: mixed 类型 data.text 缺失/空 → 占位 [图文]
			name:    "mixed 无文本",
			msgType: "mixed",
			dataField: map[string]interface{}{
				"file_id": "fake-id",
			},
			wantPrev: "[图文]",
		},
		{
			name:    "card 占位带标题",
			msgType: "card",
			dataField: map[string]interface{}{
				"title": "审批卡片",
			},
			wantPrev: "[卡片] 审批卡片",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			fix := seedDM(t)
			p := newProcessorWithNilHub(t, fix)

			// 建引用目标
			targetContent := contentByType(tc.msgType, tc.dataField)
			target, err := fix.msgRepo.Create(
				t.Context(), fix.convID, "agent", fix.agentID, targetContent,
			)
			if err != nil {
				t.Fatalf("建目标消息失败: %v", err)
			}

			// user 引用
			_, err = p.PersistAndDispatch(
				t.Context(), fix.convID, "user", fix.userID,
				quoteContent("reply", target.ID),
				nil, nil,
			)
			if err != nil {
				t.Fatalf("PersistAndDispatch 失败: %v", err)
			}

			msgs, _ := fix.msgRepo.ListByConversation(
				t.Context(), fix.convID, fix.userID, "user", 100, 0,
			)
			if len(msgs) != 2 {
				t.Fatalf("期望 2 条,实际 %d", len(msgs))
			}
			quote := parseQuote(t, msgs[0].Content)
			if quote["preview"] != tc.wantPrev {
				t.Errorf("preview 抽取错误:\ngot:  %v\nwant: %s", quote["preview"], tc.wantPrev)
			}
			// msg_type 字段也应同步成被引用消息的真实类型
			if quote["msg_type"] != tc.msgType {
				t.Errorf("msg_type 字段错误: got %v, want %s", quote["msg_type"], tc.msgType)
			}
		})
	}
}

// TestProcessMessageQuoteNestedStripped 验证:被引用消息本身是「带 quote 的回复」时,
// 富化只抽它的「原文 preview」(text/markdown),不把它的 quote 信息嵌套进来。
//
// 这是防嵌套设计:quote.preview 是单行预览,不应该出现「引用的引用」结构。
func TestProcessMessageQuoteNestedStripped(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	// 先建一条「原文」(无 quote)
	original, err := fix.msgRepo.Create(
		t.Context(), fix.convID, "agent", fix.agentID, msgContent("最原始的内容"),
	)
	if err != nil {
		t.Fatalf("建 original 失败: %v", err)
	}

	// 再建一条「带 quote 的回复」(quote.message_id 指向 original)
	// 这条消息的 content.data 里有 quote 子对象
	replyContent, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data": map[string]interface{}{
			"text":  "这是回复",
			"quote": map[string]interface{}{"message_id": original.ID, "preview": "嵌套预览"},
		},
	})
	reply, err := fix.msgRepo.Create(
		t.Context(), fix.convID, "user", fix.userID, replyContent,
	)
	if err != nil {
		t.Fatalf("建 reply 失败: %v", err)
	}

	// 第三条消息引用 reply(被引用消息本身带 quote)
	_, err = p.PersistAndDispatch(
		t.Context(), fix.convID, "user", fix.userID,
		quoteContent("再回复一次", reply.ID),
		nil, nil,
	)
	if err != nil {
		t.Fatalf("PersistAndDispatch 失败: %v", err)
	}

	msgs, _ := fix.msgRepo.ListByConversation(t.Context(), fix.convID, fix.userID, "user", 100, 0)
	if len(msgs) != 3 {
		t.Fatalf("期望 3 条消息,实际 %d", len(msgs))
	}
	// newest first:第三条消息(本次 reply 的 reply)排第 0
	topQuote := parseQuote(t, msgs[0].Content)

	// preview 应该是「这是回复」(被引用消息 reply 的 text 原文),
	// 不是「嵌套预览」(reply 自己的 quote.preview)
	if topQuote["preview"] != "这是回复" {
		t.Errorf("嵌套剥除失败:preview 应取被引用消息原文\n got:  %v\n want: 这是回复",
			topQuote["preview"])
	}
	// sender_name 应是 reply 的 sender(user),不是 original 的(agent)
	if topQuote["sender_type"] != "user" {
		t.Errorf("sender_type 应取被引用消息(reply)的 sender_type: got %v, want user",
			topQuote["sender_type"])
	}
	if topQuote["sender_id"] != fix.userID {
		t.Errorf("sender_id 应取被引用消息(reply)的 sender_id: got %v", topQuote["sender_id"])
	}
}

// softDeleteViaTx 走 SoftDeleteTx + 事务撤回消息(与 production recall handler 一致)。
// MessageRepo.SoftDelete(非 Tx)已删,只能通过 SoftDeleteTx 触发 deleted_at。
func softDeleteViaTx(t *testing.T, fix dmFixture, msgID string) {
	t.Helper()
	tx, err := fix.db.BeginTx(t.Context(), nil)
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	if err := fix.msgRepo.SoftDeleteTx(t.Context(), tx, msgID); err != nil {
		_ = tx.Rollback()
		t.Fatalf("SoftDeleteTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit 失败: %v", err)
	}
}

// TestProcessor_HandleIncoming_SessionStatus 验证 agent 发的 SESSION_STATUS 透传给
// 该会话所有 user participants,与 TYPING_START 完全对称:
//   - 不持久化消息(messages 表无新行)
//   - 不增未读(user.unread_count 仍为 0)
//   - 透传原 wsMsg(payload 原样,含 conversation_id / status)
//
// 注:NewProcessor 接收具体类型 *hub.Hub(非接口),无法用 recordingHub mock。
// 改用真实 hub + RegisterClient 注册一个 user client,从 client.Send 读捕获 dispatch
// (bufferedSend 是同步非阻塞写 client.Send,HandleIncoming 返回后即可确定性读取)。
func TestProcessor_HandleIncoming_SessionStatus(t *testing.T) {
	fix := seedDM(t)
	h := hub.NewHub(nil, fix.agentRepo, fix.participantRp, nil)
	p := NewProcessor(h, fix.convRepo, fix.msgRepo, fix.agentRepo, fix.userRepo,
		fix.fileRepo, fix.participantRp, fix.deliveryRp, nil, nil, nil, nil, nil)

	// 注册 user client 捕获 dispatch(nil conn 即可,只读 client.Send channel)
	userClient := hub.NewClient(t.Context(), fix.userID, "user", nil)
	h.RegisterClient(userClient)

	statusPayload, _ := json.Marshal(map[string]interface{}{
		"conversation_id": fix.convID,
		"status":          "busy",
	})

	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  "SESSION_STATUS",
		D:  statusPayload,
	})

	// 1. 透传:user client 应收到 SESSION_STATUS(payload 原样)
	select {
	case data := <-userClient.Send:
		var got model.WSMessage
		if err := json.Unmarshal(data, &got); err != nil {
			t.Fatalf("解析收到的 dispatch 失败: %v", err)
		}
		if got.T != "SESSION_STATUS" {
			t.Errorf("透传 T 错误: got %q, want SESSION_STATUS", got.T)
		}
		var d struct {
			ConversationID string `json:"conversation_id"`
			Status         string `json:"status"`
		}
		if err := json.Unmarshal(got.D, &d); err != nil {
			t.Fatalf("解析透传 payload 失败: %v", err)
		}
		if d.ConversationID != fix.convID || d.Status != "busy" {
			t.Errorf("透传 payload 错误: conv_id=%q status=%q", d.ConversationID, d.Status)
		}
	default:
		t.Fatal("SESSION_STATUS 未透传给 user(client.Send 无消息)")
	}

	// 2. 不持久化消息
	msgs, err := fix.msgRepo.ListByConversation(t.Context(), fix.convID, fix.userID, "user", 100, 0)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(msgs) != 0 {
		t.Errorf("SESSION_STATUS 不应持久化消息, 实际: %d 条", len(msgs))
	}

	// 3. 不增未读
	userP, err := fix.participantRp.Get(t.Context(), fix.convID, fix.userID, "user")
	if err != nil {
		t.Fatalf("participantRp.Get 失败: %v", err)
	}
	if userP.UnreadCount != 0 {
		t.Errorf("SESSION_STATUS 不应增未读, 实际: %d", userP.UnreadCount)
	}
}

// TestProcessor_HandleIncoming_SessionStatusRejectsNonAgent 验证:
// 非 agent(user)发的 SESSION_STATUS 被丢弃,user client 不应收到 dispatch。
func TestProcessor_HandleIncoming_SessionStatusRejectsNonAgent(t *testing.T) {
	fix := seedDM(t)
	h := hub.NewHub(nil, fix.agentRepo, fix.participantRp, nil)
	p := NewProcessor(h, fix.convRepo, fix.msgRepo, fix.agentRepo, fix.userRepo,
		fix.fileRepo, fix.participantRp, fix.deliveryRp, nil, nil, nil, nil, nil)

	userClient := hub.NewClient(t.Context(), fix.userID, "user", nil)
	h.RegisterClient(userClient)

	statusPayload, _ := json.Marshal(map[string]interface{}{
		"conversation_id": fix.convID,
		"status":          "busy",
	})

	// user 发 SESSION_STATUS → 应被丢弃(senderType != "agent")
	p.HandleIncoming(t.Context(), "user", fix.userID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  "SESSION_STATUS",
		D:  statusPayload,
	})

	// user client 不应收到任何 dispatch(bufferedSend 同步写,确定性非阻塞读)
	select {
	case data := <-userClient.Send:
		t.Errorf("非 agent 的 SESSION_STATUS 应被丢弃,实际透传: %s", data)
	default:
		// 预期无消息,pass
	}
}

// TestProcessMessageQuoteQuotedRecalled 验证:被引用消息已撤回(deleted_at != nil)时,
// server 不应泄漏原文 preview,改用 [消息已撤回] 占位。
//
// 关键约束(I1 安全修复):
//   - quote 仍允许(fail-soft,不阻塞整条消息持久化,UX 友好)
//   - preview == "[消息已撤回]"(不泄漏原文)
//   - sender_name / sender_type / sender_id / msg_type 仍按被引用消息真实值填
//     (让 client 知道「谁被引用了」,渲染「${name} 的消息已被撤回」占位)
func TestProcessMessageQuoteQuotedRecalled(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	// agent 发一条原文消息(后续会被撤回)
	target, err := fix.msgRepo.Create(
		t.Context(), fix.convID, "agent", fix.agentID, msgContent("这是敏感原文不应泄漏"),
	)
	if err != nil {
		t.Fatalf("建目标消息失败: %v", err)
	}

	// 撤回 target(写 deleted_at)
	softDeleteViaTx(t, fix, target.ID)

	// user 引用已撤回的 target
	content := quoteContentWithForgedFields("reply to recalled", target.ID)
	_, err = p.PersistAndDispatch(t.Context(), fix.convID, "user", fix.userID, content, nil, nil)
	if err != nil {
		t.Fatalf("引用已撤回消息不应失败(应 fail-soft): %v", err)
	}

	msgs, _ := fix.msgRepo.ListByConversation(t.Context(), fix.convID, fix.userID, "user", 100, 0)
	if len(msgs) != 2 {
		t.Fatalf("期望 2 条消息(target recalled + reply),实际 %d 条", len(msgs))
	}
	// newest first:reply 排第 0
	quote := parseQuote(t, msgs[0].Content)

	// preview 必须是占位,不是原文
	if quote["preview"] != "[消息已撤回]" {
		t.Errorf("已撤回消息的 preview 应为 [消息已撤回] 占位,泄漏原文:\n got:  %v\n want: [消息已撤回]",
			quote["preview"])
	}
	// sender_* / msg_type 仍按被引用消息真实值填(让 client 渲染「谁的消息被撤回」)
	if quote["sender_type"] != "agent" {
		t.Errorf("sender_type 仍应填被引用消息真实值: got %v, want agent", quote["sender_type"])
	}
	if quote["sender_id"] != fix.agentID {
		t.Errorf("sender_id 仍应填被引用消息真实值: got %v, want %s", quote["sender_id"], fix.agentID)
	}
	if quote["msg_type"] != "text" {
		t.Errorf("msg_type 仍应填被引用消息真实值: got %v, want text", quote["msg_type"])
	}
	// sender_name 应是非空真实名字(不应该是 [消息已撤回] 之类的占位)
	if quote["sender_name"] == "" || quote["sender_name"] == "[消息已撤回]" {
		t.Errorf("sender_name 应填被引用消息真实 sender 名字,实际: %v", quote["sender_name"])
	}
}

// TestProcessMessageChildApprovalCardNormalUnread 验证:子 agent 审批卡
// (permission_card,带 parent/root)豁免 isChildEvent,走正常未读流程
// (delivery read_at=NULL + IncrUnread),浮到主对话流供用户立即操作。
func TestProcessMessageChildApprovalCardNormalUnread(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	// 先建一条顶层 task 卡片作为 parent/root
	parent, err := fix.msgRepo.Create(
		t.Context(), fix.convID, "agent", fix.agentID, msgContent("top task"),
	)
	if err != nil {
		t.Fatalf("建 parent 失败: %v", err)
	}

	// 子 agent permission_card:带 parent/root + silent=false
	permContent, _ := json.Marshal(map[string]interface{}{
		"msg_type": "permission_card",
		"data":     map[string]interface{}{"status": "pending", "action": "bash"},
		"silent":   false,
	})
	msg, err := p.PersistAndDispatch(
		t.Context(), fix.convID, "agent", fix.agentID, permContent,
		&parent.ID, &parent.ID,
	)
	if err != nil {
		t.Fatalf("子 agent 审批卡发送失败: %v", err)
	}

	// delivery read_at 应为 NULL(正常未读态),而非子事件的 NOW()
	var readAt sql.NullTime
	err = fix.db.QueryRowContext(
		t.Context(),
		`SELECT read_at FROM message_deliveries WHERE message_id = $1 AND recipient_id = $2 AND recipient_type = 'user'`,
		msg.ID, fix.userID,
	).Scan(&readAt)
	if err != nil {
		t.Fatalf("查审批卡 delivery 失败: %v", err)
	}
	if readAt.Valid {
		t.Fatalf("子 agent 审批卡 delivery 应为未读态(read_at=NULL),实际 %v", readAt.Time)
	}

	// unread_count 应 +1(silent=false 触发 IncrUnread)
	var unread int
	err = fix.db.QueryRowContext(
		t.Context(),
		`SELECT unread_count FROM conversation_participants WHERE conv_id = $1 AND member_id = $2 AND member_type = 'user'`,
		fix.convID, fix.userID,
	).Scan(&unread)
	if err != nil {
		t.Fatalf("查 unread_count 失败: %v", err)
	}
	if unread != 1 {
		t.Errorf("子 agent 审批卡应 +1 未读,实际 unread_count=%d", unread)
	}
}

// TestPersistAndDispatchConcurrentNoDeadlock 验证并发发消息不死锁不丢消息。
//
// 背景:UnhideTx 原在主事务内与 IncrUnreadTx 对同一批 conversation_participants 行
// 交叉锁,多 agent/多任务并发发消息触发 PG deadlock(40P01),PG kill 其中一条事务
// → 整条消息回滚丢失(plugin 收到 500 不重试,审批卡永久丢)。
//
// 修复:UnhideTx 移出主事务(commit 后 best-effort) + PersistAndDispatch 对 40P01
// 自动重试。本测试用 N 条并发消息验证全部成功落库,无丢失。
func TestPersistAndDispatchConcurrentNoDeadlock(t *testing.T) {
	if testing.Short() {
		t.Skip("跳过: 集成测试需 PG 容器")
	}
	const concurrency = 8
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	errs := make([]error, concurrency)
	msgs := make([]*model.Message, concurrency)
	done := make(chan struct{})

	for i := 0; i < concurrency; i++ {
		go func(idx int) {
			defer func() { done <- struct{}{} }()
			content := msgContent(fmt.Sprintf("并发消息 %d", idx))
			msg, err := p.PersistAndDispatch(
				t.Context(), fix.convID, "agent", fix.agentID, content, nil, nil,
			)
			errs[idx] = err
			msgs[idx] = msg
		}(i)
	}
	for i := 0; i < concurrency; i++ {
		<-done
	}

	// 全部成功,无 deadlock 丢失
	for i, err := range errs {
		if err != nil {
			t.Fatalf("并发消息 %d 失败(应不死锁丢失): %v", i, err)
		}
	}

	// 全部落库:DB 里该会话的消息数 == concurrency(seedDM 不建消息)
	var count int
	err := fix.db.QueryRowContext(
		t.Context(),
		`SELECT count(*) FROM messages WHERE conversation_id = $1`,
		fix.convID,
	).Scan(&count)
	if err != nil {
		t.Fatalf("查消息数失败: %v", err)
	}
	if count != concurrency {
		t.Errorf("并发 %d 条消息应全部落库,实际 DB 只有 %d 条(死锁丢失)", concurrency, count)
	}

	// hidden_at 全部清空(Unhide 事务外执行仍生效)
	var hiddenCount int
	err = fix.db.QueryRowContext(
		t.Context(),
		`SELECT count(*) FROM conversation_participants WHERE conv_id = $1 AND hidden_at IS NOT NULL`,
		fix.convID,
	).Scan(&hiddenCount)
	if err != nil {
		t.Fatalf("查 hidden_at 失败: %v", err)
	}
	if hiddenCount != 0 {
		t.Errorf("新消息后全员 hidden_at 应清空,实际 %d 条仍隐藏", hiddenCount)
	}
}

// === AGENT_MODELS 事件处理(APP 更换模型功能) ===
//
// AGENT_MODELS 是 plugin → server 的单向事件:plugin 启动/重连时拉 opencode
// providers,全量上报该 agent 可选模型清单。server 内存缓存(AgentRegistry),
// APP 通过 REST 拉取本清单渲染模型选择器。
//
// 安全关键:plugin A 不能冒充上报 plugin B 的清单。校验 payload.agent_id 必须
// 与 WS 鉴权的 sender_id 一致(来自 JWT,plugin 无法伪造)。

// TestProcessor_AgentModels_UpdatesRegistry happy path:
// agent 角色上报自己的模型清单,registry 应缓存最新值。
func TestProcessor_AgentModels_UpdatesRegistry(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)
	reg := agent.NewAgentRegistry()
	p.agentRegistry = reg

	models := []model.ModelInfo{
		{ProviderID: "zhipuai", ProviderName: "Zhipuai", ModelID: "glm-5.2", ModelName: "GLM-5.2"},
	}
	d, _ := json.Marshal(map[string]any{
		"agent_id": fix.agentID,
		"models":   models,
	})
	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventAgentModels,
		D:  d,
	})

	got, _ := reg.Get(fix.agentID)
	if len(got) != 1 || got[0].ModelID != "glm-5.2" {
		t.Fatalf("期望 registry 缓存 glm-5.2,实际 %v", got)
	}
}

// TestProcessor_AgentModels_RejectsUserIDMismatch 反欺骗关键用例:
// plugin A(sender_id=fix.agentID)尝试上报 agt-other 的清单,
// 应被 payload.agent_id != sender_id 校验挡掉,registry 无写入。
//
// 这是 AGENT_MODELS 的核心安全守卫 — 防 plugin A 覆盖 plugin B 的模型缓存,
// 否则 plugin A 能让 APP 看到 plugin B 的伪造清单,诱导用户选错模型。
func TestProcessor_AgentModels_RejectsUserIDMismatch(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)
	reg := agent.NewAgentRegistry()
	p.agentRegistry = reg

	d, _ := json.Marshal(map[string]any{
		"agent_id": "agt-other", // 伪造:与 sender_id(fix.agentID)不一致
		"models":   []model.ModelInfo{{ModelID: "m"}},
	})
	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventAgentModels,
		D:  d,
	})

	// 被冒充的 agt-other 不应被写入
	got, _ := reg.Get("agt-other")
	if len(got) != 0 {
		t.Fatalf("agent_id 不一致时不应写入,实际 %v", got)
	}
	// sender 自己也不应被写入(整条消息被拒)
	gotSelf, _ := reg.Get(fix.agentID)
	if len(gotSelf) != 0 {
		t.Fatalf("sender 自己也不应有残留写入,实际 %v", gotSelf)
	}
}

// TestProcessor_AgentModels_RejectsUserRole 权限用例:
// user 角色(伪造或越权)发 AGENT_MODELS 应被拒,只有 agent 能上报。
//
// user 没有 opencode providers,即使伪造也无效;但仍需在入口挡掉,
// 避免 user 通过发垃圾 AGENT_MODELS 触发不必要的 registry 写入。
func TestProcessor_AgentModels_RejectsUserRole(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)
	reg := agent.NewAgentRegistry()
	p.agentRegistry = reg

	d, _ := json.Marshal(map[string]any{
		"agent_id": "agt-x",
		"models":   []model.ModelInfo{{ModelID: "m"}},
	})
	// user 角色发送:应被 senderType != "agent" 守卫挡掉
	p.HandleIncoming(t.Context(), "user", "u-1", &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventAgentModels,
		D:  d,
	})

	got, _ := reg.Get("agt-x")
	if len(got) != 0 {
		t.Fatalf("user 角色上报不应写入,实际 %v", got)
	}
}

// === AGENT_SLASH_CATALOG 事件处理(APP 斜杠命令功能) ===
//
// AGENT_SLASH_CATALOG 是 plugin → server 的单向事件:plugin 启动/重连时拉 opencode
// command.list 后上报,server 缓存到 SlashCatalogRegistry 供 APP REST 拉取。
// 与 AGENT_MODELS 同构: 安全守卫一致(角色校验 + agent_id 一致性校验)。

func TestProcessor_AgentSlashCatalog_UpdatesRegistry(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)
	reg := agent.NewSlashCatalogRegistry()
	p.slashCatalogRegistry = reg

	commands := []model.SlashCommandInfo{
		{Name: "compact", Template: "/compact", Description: "压缩", Source: "command"},
		{Name: "new", Template: "/new", Source: "command"},
	}
	d, _ := json.Marshal(map[string]any{
		"agent_id": fix.agentID,
		"commands": commands,
	})
	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventAgentSlashCatalog,
		D:  d,
	})

	got, _ := reg.Get(fix.agentID)
	if len(got) != 2 || got[0].Name != "compact" || got[1].Name != "new" {
		t.Fatalf("期望 2 条 compact+new, 实际 %v", got)
	}
	if got[0].Source != "command" || got[1].Source != "command" {
		t.Fatalf("source 字段反序列化错误: %v", got)
	}
}

func TestProcessor_AgentSlashCatalog_RejectsUserIDMismatch(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)
	reg := agent.NewSlashCatalogRegistry()
	p.slashCatalogRegistry = reg

	d, _ := json.Marshal(map[string]any{
		"agent_id": "agt-other", // 伪造
		"commands": []model.SlashCommandInfo{{Name: "x"}},
	})
	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventAgentSlashCatalog,
		D:  d,
	})

	got, _ := reg.Get("agt-other")
	if len(got) != 0 {
		t.Fatalf("agent_id 不一致时不应写入, 实际 %v", got)
	}
	gotSelf, _ := reg.Get(fix.agentID)
	if len(gotSelf) != 0 {
		t.Fatalf("sender 自己也不应有残留, 实际 %v", gotSelf)
	}
}

func TestProcessor_AgentSlashCatalog_RejectsUserRole(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)
	reg := agent.NewSlashCatalogRegistry()
	p.slashCatalogRegistry = reg

	d, _ := json.Marshal(map[string]any{
		"agent_id": fix.agentID,
		"commands": []model.SlashCommandInfo{{Name: "x"}},
	})
	p.HandleIncoming(t.Context(), "user", fix.userID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventAgentSlashCatalog,
		D:  d,
	})

	got, _ := reg.Get(fix.agentID)
	if len(got) != 0 {
		t.Fatalf("user 角色上报应被拒, 实际 %v", got)
	}
}

// === PLUGIN_CAPABILITIES 事件处理(RPC 方法清单功能) ===
//
// PLUGIN_CAPABILITIES 是 plugin → server 的单向事件:plugin 启动/重连时上报该 agent
// 支持的 RPC 方法清单。server 内存缓存(CapabilityRegistry),RPC 路由层 + REST 读取。
// 与 AGENT_MODELS / AGENT_SLASH_CATALOG 完全同构: 安全守卫一致
// (senderType == "agent" + payload.agent_id == WS 鉴权 sender_id)。

// TestProcessor_PluginCapabilities_UpdatesRegistry happy path:
// agent 角色上报自己的 RPC 方法清单,registry 应缓存最新值。
func TestProcessor_PluginCapabilities_UpdatesRegistry(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)
	reg := agent.NewCapabilityRegistry()
	p.capabilityRegistry = reg

	methods := []model.RpcMethod{
		{Name: "echo", TimeoutHintMs: 3000},
	}
	d, _ := json.Marshal(map[string]any{
		"agent_id": fix.agentID,
		"methods":  methods,
	})
	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventPluginCapabilities,
		D:  d,
	})

	got, _ := reg.Get(fix.agentID)
	if len(got) != 1 || got[0].Name != "echo" || got[0].TimeoutHintMs != 3000 {
		t.Fatalf("期望 registry 缓存 echo(3000ms), 实际 %v", got)
	}
}

// TestProcessor_PluginCapabilities_RejectsUserIDMismatch 反欺骗关键用例:
// plugin A(sender_id=fix.agentID)尝试上报 agt-other 的方法清单,
// 应被 payload.agent_id != sender_id 校验挡掉,registry 无写入。
//
// 这是 PLUGIN_CAPABILITIES 的核心安全守卫 — 防 plugin A 覆盖 plugin B 的能力缓存,
// 否则 plugin A 能让 APP 看到 plugin B 的伪造清单,诱导 RPC 调用打错目标。
func TestProcessor_PluginCapabilities_RejectsUserIDMismatch(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)
	reg := agent.NewCapabilityRegistry()
	p.capabilityRegistry = reg

	d, _ := json.Marshal(map[string]any{
		"agent_id": "agt-other", // 伪造:与 sender_id(fix.agentID)不一致
		"methods":  []model.RpcMethod{{Name: "echo"}},
	})
	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventPluginCapabilities,
		D:  d,
	})

	// 被冒充的 agt-other 不应被写入
	got, _ := reg.Get("agt-other")
	if len(got) != 0 {
		t.Fatalf("agent_id 不一致时不应写入, 实际 %v", got)
	}
	// sender 自己也不应被写入(整条消息被拒)
	gotSelf, _ := reg.Get(fix.agentID)
	if len(gotSelf) != 0 {
		t.Fatalf("sender 自己也不应有残留写入, 实际 %v", gotSelf)
	}
}

// TestProcessor_PluginCapabilities_RejectsUserRole 权限用例:
// user 角色(伪造或越权)发 PLUGIN_CAPABILITIES 应被拒,只有 agent 能上报。
//
// user 没有 RPC 实现,即使伪造也无效;但仍需在入口挡掉,
// 避免 user 通过发垃圾 PLUGIN_CAPABILITIES 触发不必要的 registry 写入。
func TestProcessor_PluginCapabilities_RejectsUserRole(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)
	reg := agent.NewCapabilityRegistry()
	p.capabilityRegistry = reg

	d, _ := json.Marshal(map[string]any{
		"agent_id": fix.agentID,
		"methods":  []model.RpcMethod{{Name: "echo"}},
	})
	// user 角色发送:应被 senderType != "agent" 守卫挡掉
	p.HandleIncoming(t.Context(), "user", fix.userID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventPluginCapabilities,
		D:  d,
	})

	got, _ := reg.Get(fix.agentID)
	if len(got) != 0 {
		t.Fatalf("user 角色上报应被拒, 实际 %v", got)
	}
}

// TestProcessor_PluginCapabilities_EmptyMethodsValid 边界用例:
// 空 methods 是合法上报(plugin 临时无 RPC 方法),registry 应缓存空切片 +
// updatedAt 非零(标记"已上报,只是清单为空"),区别于从未上报的 agent。
func TestProcessor_PluginCapabilities_EmptyMethodsValid(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)
	reg := agent.NewCapabilityRegistry()
	p.capabilityRegistry = reg

	d, _ := json.Marshal(map[string]any{
		"agent_id": fix.agentID,
		"methods":  []model.RpcMethod{},
	})
	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventPluginCapabilities,
		D:  d,
	})

	got, updated := reg.Get(fix.agentID)
	if len(got) != 0 {
		t.Fatalf("空清单应缓存空切片, 实际 %d 条", len(got))
	}
	if updated.IsZero() {
		t.Fatalf("已上报空清单, updatedAt 不应 zero")
	}
}

// TestStripInjectStreamID 验证 stripStreamID / injectStreamID 的纯函数行为。
// _stream_id 是流式占位关联字段,落库前剥离、广播时注入回去,二者必须互逆。
func TestStripInjectStreamID(t *testing.T) {
	tests := []struct {
		name         string
		content      string
		wantSID      string
		wantStripped bool // 剥离后 content.data 应不含 _stream_id
	}{
		{
			name:         "data 含 _stream_id",
			content:      `{"msg_type":"reasoning","data":{"text":"结论","_stream_id":"s-1"}}`,
			wantSID:      "s-1",
			wantStripped: true,
		},
		{
			name:         "data 无 _stream_id",
			content:      `{"msg_type":"text","data":{"text":"hi"}}`,
			wantSID:      "",
			wantStripped: false,
		},
		{
			name:         "无 data 字段",
			content:      `{"msg_type":"text"}`,
			wantSID:      "",
			wantStripped: false,
		},
		{
			name:         "_stream_id 类型错(数字)",
			content:      `{"msg_type":"text","data":{"_stream_id":123}}`,
			wantSID:      "", // 类型不匹配 → 不剥离,返回原 content
			wantStripped: false,
		},
		{
			name:         "非 JSON object(数组)",
			content:      `[1,2,3]`,
			wantSID:      "",
			wantStripped: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			stripped, sid := stripStreamID([]byte(tt.content))
			if sid != tt.wantSID {
				t.Errorf("streamID: got %q, want %q", sid, tt.wantSID)
			}
			if !tt.wantStripped {
				return
			}
			var check struct {
				Data map[string]json.RawMessage `json:"data"`
			}
			if err := json.Unmarshal(stripped, &check); err != nil {
				t.Fatalf("stripped 不是合法 JSON: %v", err)
			}
			if _, exists := check.Data["_stream_id"]; exists {
				t.Errorf("剥离后 content.data 不应含 _stream_id")
			}
			// 注入回去应得回原值(strip / inject 互逆)
			injected := injectStreamID(stripped, sid)
			var ic struct {
				Data map[string]json.RawMessage `json:"data"`
			}
			if err := json.Unmarshal(injected, &ic); err != nil {
				t.Fatalf("injected 不是合法 JSON: %v", err)
			}
			rawSID, ok := ic.Data["_stream_id"]
			if !ok {
				t.Fatalf("注入后 content.data 应含 _stream_id")
			}
			var gotSID string
			if err := json.Unmarshal(rawSID, &gotSID); err != nil {
				t.Fatalf("解析注入的 _stream_id 失败: %v", err)
			}
			if gotSID != tt.wantSID {
				t.Errorf("注入的 _stream_id: got %q, want %q", gotSID, tt.wantSID)
			}
		})
	}
}

// TestPersistAndDispatch_StripsStreamID 验证:content.data._stream_id 是流式占位关联字段,
// 落库前必须剥离(不污染历史库),但广播 dispatch payload 保留(APP 据此同位置替换占位为终态)。
//
// 三态校验:
//  1. 入站 content.data 含 _stream_id
//  2. 落库 messages.content 不含 _stream_id(查 DB 真值,非 msg.Content 回显)
//  3. 广播 dispatch payload 的 content.data._stream_id == 入站原值
func TestPersistAndDispatch_StripsStreamID(t *testing.T) {
	fix := seedDM(t)

	// 构造真 hub + 注册 user client,捕获 dispatch payload。
	// newProcessorWithNilHub 的 hub 无 client 注册,无法捕获广播,故此处自行构造。
	h := hub.NewHub(nil, fix.agentRepo, fix.participantRp, nil)
	userClient := &hub.Client{
		ID:            fix.userID,
		Role:          "user",
		Send:          make(chan []byte, 8),
		LastHeartbeat: time.Now(),
	}
	h.RegisterClient(userClient)
	p := NewProcessor(h, fix.convRepo, fix.msgRepo, fix.agentRepo, fix.userRepo, fix.fileRepo,
		fix.participantRp, fix.deliveryRp, nil, nil, nil, nil, nil)

	// content.data 含 _stream_id(模拟 plugin 终态消息带流式关联)
	content, _ := json.Marshal(map[string]any{
		"msg_type": "reasoning",
		"data": map[string]any{
			"text":       "结论",
			"_stream_id": "s-1",
		},
	})

	msg, err := p.PersistAndDispatch(
		t.Context(), fix.convID, "agent", fix.agentID, content, nil, nil,
	)
	if err != nil {
		t.Fatalf("PersistAndDispatch 失败: %v", err)
	}

	// 1. 落库 content 不含 _stream_id(查 DB 真值,防 msg.Content 与 DB 不一致的假绿)
	var dbContent json.RawMessage
	err = fix.db.QueryRowContext(
		t.Context(),
		`SELECT content FROM messages WHERE id = $1`,
		msg.ID,
	).Scan(&dbContent)
	if err != nil {
		t.Fatalf("查 DB content 失败: %v", err)
	}
	var stored struct {
		Data map[string]json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal(dbContent, &stored); err != nil {
		t.Fatalf("解析落库 content 失败: %v", err)
	}
	if _, exists := stored.Data["_stream_id"]; exists {
		t.Errorf("落库 content.data 不应含 _stream_id")
	}
	// text 字段保留(剥离只删 _stream_id,不动业务字段)
	var text string
	if rawText, ok := stored.Data["text"]; ok {
		if err := json.Unmarshal(rawText, &text); err != nil {
			t.Fatalf("解析 text 失败: %v", err)
		}
	}
	if text != "结论" {
		t.Errorf("text 应保留, got %q want %q", text, "结论")
	}

	// 2. 广播 dispatch payload 含 _stream_id(原值)
	select {
	case raw := <-userClient.Send:
		var ws model.WSMessage
		if err := json.Unmarshal(raw, &ws); err != nil {
			t.Fatalf("解析 dispatch 失败: %v", err)
		}
		var d struct {
			Content json.RawMessage `json:"content"`
		}
		if err := json.Unmarshal(ws.D, &d); err != nil {
			t.Fatalf("解析 dispatch.D 失败: %v", err)
		}
		var bc struct {
			Data map[string]json.RawMessage `json:"data"`
		}
		if err := json.Unmarshal(d.Content, &bc); err != nil {
			t.Fatalf("解析广播 content 失败: %v", err)
		}
		rawSID, ok := bc.Data["_stream_id"]
		if !ok {
			t.Fatalf("广播 content.data 应含 _stream_id")
		}
		var sid string
		if err := json.Unmarshal(rawSID, &sid); err != nil {
			t.Fatalf("解析广播 _stream_id 失败: %v", err)
		}
		if sid != "s-1" {
			t.Errorf("广播 _stream_id: got %q want %q", sid, "s-1")
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("未收到 dispatch payload(user client Send chan 超时)")
	}
}

// TestAggregateCardSend 验证:agent 发 aggregate_card 消息(silent=true)
// → 正常落库 + 广播 MESSAGE_CREATE + 不计数未读。
//
// 背景:聚合卡是 plugin 流式输出新增的消息类型(sendCardMessage 走
// REST POST /api/conversations/:id/messages,默认 silent=true,回合进行中不打扰)。
// server 的 msg_type 是字符串透传(PersistAndDispatch 无白名单拦截),
// 本测试固化「aggregate_card 天然放行」行为,防未来加 msg_type 白名单时误伤。
//
// 走 PersistAndDispatch(WS HandleIncoming / HTTP SendAsAgent 两条发送路径的共同核心),
// 覆盖两通道共用的落库 + dispatch + silent 语义。
func TestAggregateCardSend(t *testing.T) {
	fix := seedDM(t)

	// 构造真 hub + 注册 user client,捕获广播(与 TestPersistAndDispatch_StripsStreamID 同模式)。
	h := hub.NewHub(nil, fix.agentRepo, fix.participantRp, nil)
	userClient := &hub.Client{
		ID:            fix.userID,
		Role:          "user",
		Send:          make(chan []byte, 8),
		LastHeartbeat: time.Now(),
	}
	h.RegisterClient(userClient)
	p := NewProcessor(h, fix.convRepo, fix.msgRepo, fix.agentRepo, fix.userRepo, fix.fileRepo,
		fix.participantRp, fix.deliveryRp, nil, nil, nil, nil, nil)

	// plugin sendCardMessage(convId, "aggregate_card", {state, elements}) 构造的 content。
	content, _ := json.Marshal(map[string]any{
		"msg_type": "aggregate_card",
		"data": map[string]any{
			"state":    "generating",
			"elements": []any{map[string]any{"type": "markdown", "seq": 1, "text": "..."}},
		},
		"silent": true,
	})
	msg, err := p.PersistAndDispatch(t.Context(), fix.convID, "agent", fix.agentID, content, nil, nil)
	if err != nil {
		t.Fatalf("aggregate_card 发送失败: %v", err)
	}

	// 1. 落库:content 保留 msg_type=aggregate_card + silent=true(查 DB 真值,防假绿)
	var dbContent json.RawMessage
	err = fix.db.QueryRowContext(t.Context(), `SELECT content FROM messages WHERE id = $1`, msg.ID).Scan(&dbContent)
	if err != nil {
		t.Fatalf("查 DB content 失败: %v", err)
	}
	var stored struct {
		MsgType string          `json:"msg_type"`
		Data    json.RawMessage `json:"data"`
		Silent  bool            `json:"silent"`
	}
	if err := json.Unmarshal(dbContent, &stored); err != nil {
		t.Fatalf("解析落库 content 失败: %v", err)
	}
	if stored.MsgType != "aggregate_card" {
		t.Errorf("落库 msg_type 应为 aggregate_card,实际 %q", stored.MsgType)
	}
	if !stored.Silent {
		t.Errorf("落库 silent 应保留 true,实际 %v", stored.Silent)
	}
	if len(stored.Data) == 0 {
		t.Errorf("落库 data 不应为空(应保留 elements)")
	}

	// 2. 广播 MESSAGE_CREATE 到在线 user client,content 保留 aggregate_card
	select {
	case raw := <-userClient.Send:
		var ws model.WSMessage
		if err := json.Unmarshal(raw, &ws); err != nil {
			t.Fatalf("解析 dispatch 失败: %v", err)
		}
		if ws.T != model.EventMessageCreate {
			t.Fatalf("期望 MESSAGE_CREATE,实际 %q", ws.T)
		}
		var d struct {
			Content json.RawMessage `json:"content"`
		}
		if err := json.Unmarshal(ws.D, &d); err != nil {
			t.Fatalf("解析 dispatch.D 失败: %v", err)
		}
		var bc struct {
			MsgType string `json:"msg_type"`
		}
		if err := json.Unmarshal(d.Content, &bc); err != nil {
			t.Fatalf("解析广播 content 失败: %v", err)
		}
		if bc.MsgType != "aggregate_card" {
			t.Errorf("广播 content msg_type 应为 aggregate_card,实际 %q", bc.MsgType)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("未收到 dispatch payload(user client Send chan 超时)")
	}

	// 3. 不计数未读:silent=true 跳过 IncrUnread,user unread_count 应为 0
	userP, err := fix.participantRp.Get(t.Context(), fix.convID, fix.userID, "user")
	if err != nil {
		t.Fatalf("Get user participant 失败: %v", err)
	}
	if userP.UnreadCount != 0 {
		t.Errorf("silent=true 的 aggregate_card 不应计数未读,实际 unread_count=%d", userP.UnreadCount)
	}
}

// ── AGENT_MODES / AGENT_PRESETS(能力上报管线第四/五成员) ──
// 与 AGENT_MODELS 同构的三个安全用例(happy/冒充/越权),守卫逻辑照抄。

func TestProcessor_AgentModes_UpdatesRegistry(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)
	reg := agent.NewModeRegistry()
	p.modeRegistry = reg

	d, _ := json.Marshal(map[string]any{
		"agent_id": fix.agentID,
		"modes": []model.AgentModeInfo{
			{ID: "build", Label: "构建", Style: "default"},
			{ID: "plan", Label: "计划", Style: "plan"},
		},
	})
	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventAgentModes,
		D:  d,
	})

	got, _ := reg.Get(fix.agentID)
	if len(got) != 2 || got[1].ID != "plan" || got[1].Style != "plan" {
		t.Fatalf("期望 registry 缓存 2 个 mode(第 2 个 plan),实际 %v", got)
	}
}

func TestProcessor_AgentModes_RejectsUserIDMismatch(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)
	reg := agent.NewModeRegistry()
	p.modeRegistry = reg

	d, _ := json.Marshal(map[string]any{
		"agent_id": "agt-other", // 伪造:与 sender_id 不一致
		"modes":    []model.AgentModeInfo{{ID: "plan"}},
	})
	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventAgentModes,
		D:  d,
	})

	got, _ := reg.Get("agt-other")
	if len(got) != 0 {
		t.Fatalf("agent_id 不一致时不应写入,实际 %v", got)
	}
	gotSelf, _ := reg.Get(fix.agentID)
	if len(gotSelf) != 0 {
		t.Fatalf("sender 自己也不应有残留写入,实际 %v", gotSelf)
	}
}

func TestProcessor_AgentModes_RejectsUserRole(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)
	reg := agent.NewModeRegistry()
	p.modeRegistry = reg

	d, _ := json.Marshal(map[string]any{
		"agent_id": fix.userID,
		"modes":    []model.AgentModeInfo{{ID: "plan"}},
	})
	p.HandleIncoming(t.Context(), "user", fix.userID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventAgentModes,
		D:  d,
	})

	got, _ := reg.Get(fix.userID)
	if len(got) != 0 {
		t.Fatalf("user 角色上报应被拒,实际 %v", got)
	}
}

func TestProcessor_AgentPresets_UpdatesRegistry(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)
	reg := agent.NewPresetRegistry()
	p.presetRegistry = reg

	d, _ := json.Marshal(map[string]any{
		"agent_id": fix.agentID,
		"presets": []model.AgentPresetInfo{
			{ID: "standard", Label: "标准", Trust: "system", Order: 1},
			{ID: "my-agent", Label: "我的定制", Trust: "user"},
		},
	})
	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventAgentPresets,
		D:  d,
	})

	got, _ := reg.Get(fix.agentID)
	if len(got) != 2 || got[1].Trust != "user" {
		t.Fatalf("期望 registry 缓存 2 个 preset(第 2 个 user trust),实际 %v", got)
	}
}

func TestProcessor_AgentPresets_RejectsUserIDMismatch(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)
	reg := agent.NewPresetRegistry()
	p.presetRegistry = reg

	d, _ := json.Marshal(map[string]any{
		"agent_id": "agt-other",
		"presets":  []model.AgentPresetInfo{{ID: "standard"}},
	})
	p.HandleIncoming(t.Context(), "agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventAgentPresets,
		D:  d,
	})

	got, _ := reg.Get("agt-other")
	if len(got) != 0 {
		t.Fatalf("agent_id 不一致时不应写入,实际 %v", got)
	}
}

func TestProcessor_AgentPresets_RejectsUserRole(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)
	reg := agent.NewPresetRegistry()
	p.presetRegistry = reg

	d, _ := json.Marshal(map[string]any{
		"agent_id": fix.userID,
		"presets":  []model.AgentPresetInfo{{ID: "standard"}},
	})
	p.HandleIncoming(t.Context(), "user", fix.userID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventAgentPresets,
		D:  d,
	})

	got, _ := reg.Get(fix.userID)
	if len(got) != 0 {
		t.Fatalf("user 角色上报应被拒,实际 %v", got)
	}
}
