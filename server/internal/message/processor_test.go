package message

import (
	"database/sql"
	"encoding/json"
	"strings"
	"testing"
	"time"

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
		INSERT INTO agents (owner_id, name, avatar_url, secret_key, status, created_at)
		VALUES ($1, $2, '', $3, 'offline', $4) RETURNING id
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

	conv, err := fix.convRepo.FindOrCreateDM("dm_user_agent", repository.DMMembers{
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
func newProcessorWithNilHub(t *testing.T, fix dmFixture) *Processor {
	t.Helper()
	h := hub.NewHub(nil, fix.agentRepo, fix.participantRp)
	return NewProcessor(h, fix.convRepo, fix.msgRepo, fix.agentRepo, fix.userRepo, fix.fileRepo,
		fix.participantRp, fix.deliveryRp)
}

// msgContent 构造 text 消息 content JSON。
func msgContent(text string) json.RawMessage {
	c, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": text},
	})
	return c
}

// userToAgentPayload 构造 user → agent 方向 MESSAGE_CREATE 的 wsMsg.D。
func userToAgentPayload(agentID string, content json.RawMessage) json.RawMessage {
	d, _ := json.Marshal(map[string]interface{}{
		"agent_id": agentID,
		"content":  content,
	})
	return d
}

// agentToUserPayload 构造 agent → user 方向 MESSAGE_CREATE 的 wsMsg.D。
func agentToUserPayload(userID string, content json.RawMessage) json.RawMessage {
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

	p.HandleIncoming("agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageCreate,
		D:  agentToUserPayload(fix.userID, msgContent("agent reply")),
	})

	// 1. messages 表 1 行
	msgs, err := fix.msgRepo.ListByConversation(fix.convID, fix.userID, "user", 100, 0)
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
	userP, err := fix.participantRp.Get(fix.convID, fix.userID, "user")
	if err != nil {
		t.Fatalf("Get user participant 失败: %v", err)
	}
	if userP.UnreadCount != 1 {
		t.Errorf("user unread_count 期望 1, 实际 %d", userP.UnreadCount)
	}
	agentP, err := fix.participantRp.Get(fix.convID, fix.agentID, "agent")
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
	conv, err := convRepo.CreateTx(tx, "group_user", "测试群", "")
	if err != nil {
		t.Fatalf("CreateTx 失败: %v", err)
	}
	if err := participantRp.AddParticipantsTx(tx, conv.ID, []repository.ParticipantInput{
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
	tx, err = convRepo.BeginTx()
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	defer tx.Rollback()

	content := msgContent("group broadcast")
	msg, err := msgRepo.CreateTx(tx, conv.ID, "user", userA, content)
	if err != nil {
		t.Fatalf("CreateTx 失败: %v", err)
	}
	parts, err := participantRp.ListByConversationTx(tx, conv.ID)
	if err != nil {
		t.Fatalf("ListByConversationTx 失败: %v", err)
	}
	recipients := filterSender(parts, userA, "user")
	if len(recipients) != 2 {
		t.Fatalf("recipients 数错误: 期望 2(b/c), 实际 %d", len(recipients))
	}
	if err := deliveryRp.CreateBatchTx(tx, msg.ID, recipients); err != nil {
		t.Fatalf("CreateBatchTx 失败: %v", err)
	}
	if err := participantRp.IncrUnreadTx(tx, conv.ID, userA, "user"); err != nil {
		t.Fatalf("IncrUnreadTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit 失败: %v", err)
	}

	// 校验:user_b/c unread=1,user_a unread=0
	for _, uid := range []string{userB, userC} {
		pt, err := participantRp.Get(conv.ID, uid, "user")
		if err != nil {
			t.Fatalf("Get %s 失败: %v", uid, err)
		}
		if pt.UnreadCount != 1 {
			t.Errorf("%s unread 期望 1, 实际 %d", uid, pt.UnreadCount)
		}
	}
	ptA, _ := participantRp.Get(conv.ID, userA, "user")
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
// conv 的某 participant.hidden_at IS NOT NULL(user 隐藏了会话),
// 但发消息应该 still work(hidden_at 只影响 IM 列表显示,不影响消息流)。
//
// 校验:user 隐藏会话 → agent 发消息 → 仍能写入 + unread 仍 +1 + delivery 仍插。
// 隐藏语义的恢复(发消息自动取消隐藏)由 handler 层负责,processor 不管。
func TestProcessor_HandleIncoming_HiddenAtDoesNotAffectSend(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	// user 隐藏会话
	if err := fix.participantRp.SetHidden(fix.convID, fix.userID, "user", true); err != nil {
		t.Fatalf("SetHidden 失败: %v", err)
	}

	// agent 发消息
	p.HandleIncoming("agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageCreate,
		D:  agentToUserPayload(fix.userID, msgContent("after hide")),
	})

	// 校验:消息正常写入
	msgs, err := fix.msgRepo.ListByConversation(fix.convID, fix.userID, "user", 100, 0)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(msgs) != 1 {
		t.Fatalf("hidden 状态下消息应正常写入: 期望 1, 实际 %d", len(msgs))
	}

	// 校验:user.unread_count 仍 +1(hidden 不影响未读计数)
	userP, _ := fix.participantRp.Get(fix.convID, fix.userID, "user")
	if userP.UnreadCount != 1 {
		t.Errorf("hidden 状态下 unread 仍应 +1: 期望 1, 实际 %d", userP.UnreadCount)
	}
	// hidden_at 仍非空(processor 不主动取消隐藏)
	if userP.HiddenAt == nil {
		t.Errorf("hidden_at 应保持非空(processor 不动 hidden 字段)")
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

	// senderType="invalid":FindOrCreateDM 阶段 CHECK 失败
	p.HandleIncoming("invalid", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageCreate,
		D:  agentToUserPayload(fix.userID, msgContent("should abort")),
	})

	// 验证 messages 表无残留
	msgs, err := fix.msgRepo.ListByConversation(fix.convID, fix.userID, "user", 100, 0)
	if err != nil {
		t.Fatalf("ListByConversation 失败: %v", err)
	}
	if len(msgs) != 0 {
		t.Errorf("非法 sender_type 处理后 messages 不应有数据,实际: %d 条", len(msgs))
	}

	// 验证 unread_count 不变(user 仍 0)
	userP, _ := fix.participantRp.Get(fix.convID, fix.userID, "user")
	if userP.UnreadCount != 0 {
		t.Errorf("非法 sender_type 处理后 unread 不应变化: 期望 0, 实际 %d", userP.UnreadCount)
	}
}

// TestProcessor_Tx_BeginCreateCommit 验证事务 API happy path:
// convRepo.BeginTx → msgRepo.CreateTx → tx.Commit 之后 messages 表有新行。
// 这是 HandleIncoming 事务路径的"组件级"覆盖,避免依赖 hub。
// (017 删 last_message_content 缓存后,事务不再调 UpdateLastMessageTx;
//  会话列表改子查询实时算,见 repository/conversation_repo_test.go。)
func TestProcessor_Tx_BeginCreateCommit(t *testing.T) {
	fix := seedDM(t)

	content := msgContent("tx component")

	tx, err := fix.convRepo.BeginTx()
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	defer tx.Rollback()

	msg, err := fix.msgRepo.CreateTx(tx, fix.convID, "user", fix.userID, content)
	if err != nil {
		t.Fatalf("CreateTx 失败: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit 失败: %v", err)
	}

	// 验证 messages 表
	msgs, _ := fix.msgRepo.ListByConversation(fix.convID, fix.userID, "user", 100, 0)
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

	tx, err := fix.convRepo.BeginTx()
	if err != nil {
		t.Fatalf("BeginTx 失败: %v", err)
	}
	defer tx.Rollback()

	// 用不存在的 conversation_id 触发 FK 约束失败
	invalidConvID := "00000000-0000-0000-0000-000000000000"
	_, err = fix.msgRepo.CreateTx(tx, invalidConvID, "user", fix.userID, msgContent("rollback"))
	if err == nil {
		t.Fatalf("期望 CreateTx 失败(FK 约束), 实际成功")
	}

	// defer Rollback 兜底,无需显式调;验证真实 convID 下无消息残留
	msgs, _ := fix.msgRepo.ListByConversation(fix.convID, fix.userID, "user", 100, 0)
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

	p.HandleIncoming("agent", fix.agentID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageCreate,
		D:  agentToUserPayload(fix.userID, msgContent("agent reply")),
	})

	// 断言:user.unread_count == 1
	count, err := fix.deliveryRp.GetUnreadCount(fix.convID, fix.userID, "user")
	if err != nil {
		t.Fatalf("GetUnreadCount 失败: %v", err)
	}
	if count != 1 {
		t.Errorf("agent 消息应一律 +1 unread, 实际: %d", count)
	}
}

// createImageFile 往 files 表插一条带 width/height 的图片记录，返回 fileID。
// 复用 repository.CreateFileParams，供 enhanceImageContent 测试。
func createImageFile(t *testing.T, fileRepo *repository.FileRepo, ownerID string, w, h int) string {
	t.Helper()
	f, err := fileRepo.Create(repository.CreateFileParams{
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

// TestEnhanceImageContent_FillsWidthHeight 主路径：image 消息缺宽高 → 从 files 表补全。
func TestEnhanceImageContent_FillsWidthHeight(t *testing.T) {
	fix := seedDM(t)
	p := newProcessorWithNilHub(t, fix)

	fileID := createImageFile(t, fix.fileRepo, fix.userID, 1080, 1920)

	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "image",
		"data":     map[string]interface{}{"file_id": fileID},
	})

	got := p.enhanceImageContent(json.RawMessage(content))

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

// TestEnhanceImageContent_Idempotent 已带宽高的消息 → 幂等跳过，不查 DB。
func TestEnhanceImageContent_Idempotent(t *testing.T) {
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
	got := p.enhanceImageContent(json.RawMessage(content))

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

// TestEnhanceImageContent_FailSoft 各种异常情况都不阻断，返回原 content。
func TestEnhanceImageContent_FailSoft(t *testing.T) {
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
			got := p.enhanceImageContent(json.RawMessage(orig))
			// 应原样返回（fail-soft 不阻断）
			if string(got) != string(orig) {
				t.Errorf("fail-soft 失败: 异常情况应原样返回\ngot:  %s\nwant: %s", got, orig)
			}
		})
	}

	// 单独测：files 表有记录但 width/height 为 NULL（非图片文件上传的场景）
	f, err := fix.fileRepo.Create(repository.CreateFileParams{
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
	got := p.enhanceImageContent(json.RawMessage(content))
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
