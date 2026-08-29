package handler

import (
	"bytes"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/hub"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// shortName 复用同包 user_handler_test.go 里的定义，本文件不再重复声明。

// seedConvFixture 是 handler 测试常用 seed:user + agent + dm_user_agent 会话。
// 返回的 conv 已存在 user/agent 两个 participant。
type seedConvFixture struct {
	db       *sql.DB
	user     *model.User
	agent    *model.Agent
	conv     *model.Conversation
	convID   string
	convRepo *repository.ConversationRepo
	pRepo    *repository.ParticipantRepo
	dRepo    *repository.DeliveryRepo
	mRepo    *repository.MessageRepo
}

// seedUserAgentConv 建一个 user + agent + dm_user_agent 会话,返回 fixture。
// 用于大部分 conversation handler 测试。
func seedUserAgentConv(t *testing.T, usernamePrefix string) *seedConvFixture {
	t.Helper()
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	mrepo := repository.NewMessageRepo(db)
	prepo := repository.NewParticipantRepo(db)
	drepo := repository.NewDeliveryRepo(db)

	user, err := urepo.Create(t.Context(), shortName(t, usernamePrefix), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	agent, err := arepo.Create(t.Context(), user.ID, shortName(t, "ag"), "secret-key", "")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}
	conv, err := crepo.FindOrCreateDM(t.Context(), "dm_user_agent", repository.DMMembers{
		Initiator: repository.ParticipantInput{MemberID: user.ID, MemberType: "user", Role: "owner"},
		Other:     repository.ParticipantInput{MemberID: agent.ID, MemberType: "agent", Role: "member"},
	})
	if err != nil {
		t.Fatalf("FindOrCreateDM 失败: %v", err)
	}
	return &seedConvFixture{
		db:       db,
		user:     user,
		agent:    agent,
		conv:     conv,
		convID:   conv.ID,
		convRepo: crepo,
		pRepo:    prepo,
		dRepo:    drepo,
		mRepo:    mrepo,
	}
}

// addUnreadAgentMessage 模拟 agent → user 一条未读消息:
// INSERT message + delivery(read_at=NULL) + IncrUnreadTx。
// 返回 message id。
// 用 tx 确保三者原子化(模拟真实 MessageProcessor 路径)。
func (f *seedConvFixture) addUnreadAgentMessage(t *testing.T) string {
	t.Helper()
	tx, err := f.db.Begin()
	if err != nil {
		t.Fatalf("Begin: %v", err)
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback()
		}
	}()

	m, err := f.mRepo.CreateTx(t.Context(), tx, f.convID, "agent", f.agent.ID, json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`))
	if err != nil {
		t.Fatalf("CreateTx msg: %v", err)
		return ""
	}
	// delivery 给 user
	parts, err := f.pRepo.ListByConversationTx(t.Context(), tx, f.convID)
	if err != nil {
		t.Fatalf("ListByConversationTx: %v", err)
		return ""
	}
	var recipients []model.ConversationParticipant
	for _, p := range parts {
		if p.MemberID == f.agent.ID && p.MemberType == "agent" {
			continue // 跳过 sender
		}
		recipients = append(recipients, p)
	}
	if err := f.dRepo.CreateBatchTx(t.Context(), tx, m.ID, recipients); err != nil {
		t.Fatalf("CreateBatchTx: %v", err)
		return ""
	}
	if err := f.pRepo.IncrUnreadTx(t.Context(), tx, f.convID, f.agent.ID, "agent"); err != nil {
		t.Fatalf("IncrUnreadTx: %v", err)
		return ""
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit: %v", err)
		return ""
	}
	return m.ID
}

// assertConvUnread 查 participant 行的 unread_count,失败时 t.Errorf。
func assertConvUnread(t *testing.T, db *sql.DB, convID, memberID, memberType string, want int) {
	t.Helper()
	var n int
	err := db.QueryRow(`
		SELECT unread_count FROM conversation_participants
		WHERE conv_id = $1 AND member_id = $2 AND member_type = $3
	`, convID, memberID, memberType).Scan(&n)
	if err != nil {
		t.Fatalf("查 unread_count 失败: %v", err)
	}
	if n != want {
		t.Errorf("unread_count = %d, want %d", n, want)
	}
}

// newConvHandler 构造一个完整依赖的 ConversationHandler。
// hub 用 NewHub(nil,...) 实例化:GetClient 走 sync.Map,空客户端返 (nil,false)=offline,
// 满足 Get/buildDetail 路径对 hub 的依赖(不需要广播 / presence)。
func newConvHandler(f *seedConvFixture) *ConversationHandler {
	urepo := repository.NewUserRepo(f.db)
	arepo := repository.NewAgentRepo(f.db)
	frepo := repository.NewFriendshipRepo(f.db)
	hubInstance := hub.NewHub(nil, arepo, f.pRepo, nil)
	return NewConversationHandler(
		f.db, f.convRepo, f.pRepo, frepo,
		f.mRepo, f.dRepo, arepo, urepo, hubInstance, nil, repository.NewAgentTypeRepo(f.db),
	)
}

// === List 测试 ===

// TestConversationHandler_List_ReturnsAgentSummary 验证 IM 风格列表核心场景:
//   - 200 状态码;
//   - 响应包含对端 agent.name(subquery JOIN agents 生效);
//   - 响应包含 last_message_content。
func TestConversationHandler_List_ReturnsAgentSummary(t *testing.T) {
	f := seedUserAgentConv(t, "list")

	// 017 删 last_message_content 缓存字段后,IM 列表改子查询实时算最新消息。
	// 这里插一条真消息让会话进列表 + subquery 返回非 NULL。
	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "hi"},
	})
	if _, err := f.mRepo.Create(t.Context(), f.convID, "user", f.user.ID, content); err != nil {
		t.Fatalf("Create msg 失败: %v", err)
	}

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.List(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	body := w.Body.String()
	if !strings.Contains(body, `"name":`) {
		t.Errorf("响应缺少 agent.name: %s", body)
	}
	if !strings.Contains(body, `"last_message_content"`) {
		t.Errorf("响应缺少 last_message_content: %s", body)
	}
}

// TestConversationHandler_List_IncludesNoMessageConversations 验证 IM 列表:
//   - 新建无消息会话也进列表(让所有 participant 立即看到,主流 IM 行为)
//   - last_message_at fallback 到 created_at(避免 client 拿到零值)
//   - 空结果仍返 [] 而非 null(避免 APP 反序列化成 null 报错)
func TestConversationHandler_List_IncludesNoMessageConversations(t *testing.T) {
	f := seedUserAgentConv(t, "excl")
	// 会话已建但无消息,应进列表(server 改造后)

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.List(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	body := strings.TrimSpace(w.Body.String())
	if body == "[]" {
		t.Errorf("无消息会话应进列表, 实际空 []")
	}
	if !strings.Contains(body, `"last_message_at"`) {
		t.Errorf("响应缺 last_message_at 字段: %s", body)
	}
	// 校验 last_message_at 不是零值(应 fallback 到 created_at)
	if strings.Contains(body, `"last_message_at":"0001-01-01`) {
		t.Errorf("last_message_at 是零值, 应 fallback 到 created_at: %s", body)
	}
}

// TestConversationHandler_List_ReturnsParticipants 验证 IM 列表带 participants
// 摘要(让 client 拼群人数 / 头像)。fixture 是 dm_user_agent,期望返 2 个 participant。
func TestConversationHandler_List_ReturnsParticipants(t *testing.T) {
	f := seedUserAgentConv(t, "listp")
	// fixture 已建 dm_user_agent 会话,user + agent 两 participant

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.List(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}

	list := AssertOkList(t, w, http.StatusOK)
	if len(list) != 1 {
		t.Fatalf("期望 1 条会话, 实际 %d", len(list))
	}
	parts, ok := list[0].(map[string]any)["participants"].([]any)
	if !ok {
		t.Fatalf("participants 字段非数组: %v", list[0].(map[string]any)["participants"])
	}
	if len(parts) != 2 {
		t.Errorf("期望 2 个 participant (user + agent), 实际 %d", len(parts))
	}
}

// === Create 测试 ===

// TestConversationHandler_Create_LegacyAgentIDBody 验证老 body(agent_id)翻译为
// type=dm_user_agent + member=[(agent_id, agent)] 的兼容路径。
// 老客户端不变,server 自动注入 user 作 owner。
func TestConversationHandler_Create_LegacyAgentIDBody(t *testing.T) {
	f := seedUserAgentConv(t, "create")

	// 注意:fixture 已经建过 dm_user_agent,这里调 Create 应走 FindOrCreateDM 幂等返同一会话。
	h := newConvHandler(f)
	r := gin.New()
	r.POST("/api/conversations", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.Create(c)
	})

	body := `{"agent_id":"` + f.agent.ID + `"}`
	req := httptest.NewRequest("POST", "/api/conversations", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	resp := w.Body.String()
	if !strings.Contains(resp, `"id":"`+f.convID+`"`) {
		t.Errorf("期望返已存在会话 %s, resp: %s", f.convID, resp)
	}
}

// TestConversationHandler_Create_NewAgentBody 验证新 body(type + member_ids/types)创建 dm_user_agent。
func TestConversationHandler_Create_NewAgentBody(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	mrepo := repository.NewMessageRepo(db)
	prepo := repository.NewParticipantRepo(db)
	frepo := repository.NewFriendshipRepo(db)

	user, err := urepo.Create(t.Context(), shortName(t, "cna"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user: %v", err)
	}
	agent, err := arepo.Create(t.Context(), user.ID, shortName(t, "ag"), "secret-key", "")
	if err != nil {
		t.Fatalf("Create agent: %v", err)
	}

	drepo := repository.NewDeliveryRepo(db)
	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, drepo, arepo, urepo, nil, nil, repository.NewAgentTypeRepo(db))
	r := gin.New()
	r.POST("/api/conversations", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.Create(c)
	})

	body := fmt.Sprintf(`{"type":"dm_user_agent","member_ids":["%s"],"member_types":["agent"]}`, agent.ID)
	req := httptest.NewRequest("POST", "/api/conversations", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	// 校验 participants 摘要正确
	resp := w.Body.String()
	if !strings.Contains(resp, `"member_type":"agent"`) {
		t.Errorf("响应缺少 agent participant: %s", resp)
	}
	if !strings.Contains(resp, `"role":"owner"`) {
		t.Errorf("响应缺少 user owner role: %s", resp)
	}
}

// TestConversationHandler_Create_DMUserUser_RequiresFriendship 验证 dm_user_user
// 创建时校验好友关系,非好友返 403(spec §4.2)。
func TestConversationHandler_Create_DMUserUser_RequiresFriendship(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	mrepo := repository.NewMessageRepo(db)
	prepo := repository.NewParticipantRepo(db)
	frepo := repository.NewFriendshipRepo(db)

	user, _ := urepo.Create(t.Context(), shortName(t, "duf1"), "$2a$10$hash")
	other, _ := urepo.Create(t.Context(), shortName(t, "duf2"), "$2a$10$hash")
	// 不建好友关系

	drepo := repository.NewDeliveryRepo(db)
	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, drepo, arepo, urepo, nil, nil, repository.NewAgentTypeRepo(db))
	r := gin.New()
	r.POST("/api/conversations", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.Create(c)
	})

	body := fmt.Sprintf(`{"type":"dm_user_user","member_ids":["%s"],"member_types":["user"]}`, other.ID)
	req := httptest.NewRequest("POST", "/api/conversations", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusForbidden, "forbidden")
}

// TestConversationHandler_Create_DMUserUser_FriendsSucceed 验证 dm_user_user
// 好友关系正常时创建成功。
func TestConversationHandler_Create_DMUserUser_FriendsSucceed(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	mrepo := repository.NewMessageRepo(db)
	prepo := repository.NewParticipantRepo(db)
	frepo := repository.NewFriendshipRepo(db)

	user, _ := urepo.Create(t.Context(), shortName(t, "dufs1"), "$2a$10$hash")
	other, _ := urepo.Create(t.Context(), shortName(t, "dufs2"), "$2a$10$hash")

	// 建好友关系:发请求 + accept
	fr, err := frepo.CreateRequest(t.Context(), user.ID, other.ID)
	if err != nil {
		t.Fatalf("CreateRequest: %v", err)
	}
	if err := frepo.Accept(t.Context(), fr.ID, other.ID); err != nil {
		t.Fatalf("Accept: %v", err)
	}

	drepo := repository.NewDeliveryRepo(db)
	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, drepo, arepo, urepo, nil, nil, repository.NewAgentTypeRepo(db))
	r := gin.New()
	r.POST("/api/conversations", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.Create(c)
	})

	body := fmt.Sprintf(`{"type":"dm_user_user","member_ids":["%s"],"member_types":["user"]}`, other.ID)
	req := httptest.NewRequest("POST", "/api/conversations", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("好友 dm_user_user 创建应 200, 实际: %d body: %s", w.Code, w.Body.String())
	}
}

// TestConversationHandler_Create_GroupUser 验证 group_user 群聊创建:user 作 owner + 2 个 user member。
func TestConversationHandler_Create_GroupUser(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	mrepo := repository.NewMessageRepo(db)
	prepo := repository.NewParticipantRepo(db)
	frepo := repository.NewFriendshipRepo(db)

	creator, _ := urepo.Create(t.Context(), shortName(t, "gcr"), "$2a$10$hash")
	m1, _ := urepo.Create(t.Context(), shortName(t, "gm1"), "$2a$10$hash")
	m2, _ := urepo.Create(t.Context(), shortName(t, "gm2"), "$2a$10$hash")

	drepo := repository.NewDeliveryRepo(db)
	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, drepo, arepo, urepo, nil, nil, repository.NewAgentTypeRepo(db))
	r := gin.New()
	r.POST("/api/conversations", func(c *gin.Context) {
		c.Set("userID", creator.ID)
		h.Create(c)
	})

	body := fmt.Sprintf(
		`{"type":"group_user","member_ids":["%s","%s"],"member_types":["user","user"],"title":"群名","avatar_url":"http://x/a.png"}`,
		m1.ID, m2.ID,
	)
	req := httptest.NewRequest("POST", "/api/conversations", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("group_user 创建应 200, 实际: %d body: %s", w.Code, w.Body.String())
	}

	// 校验 conv 表里有 title
	var convID, title string
	_ = db.QueryRow(`SELECT id, title FROM conversations ORDER BY created_at DESC LIMIT 1`).Scan(&convID, &title)
	if title != "群名" {
		t.Errorf("title 期望 '群名', 实际 '%s'", title)
	}
	// 校验 3 个 participant(creator=owner + 2 member)
	var n int
	_ = db.QueryRow(`SELECT COUNT(*) FROM conversation_participants WHERE conv_id = $1`, convID).Scan(&n)
	if n != 3 {
		t.Errorf("participant 数 = %d, want 3", n)
	}
	// creator 是 owner
	var creatorRole string
	_ = db.QueryRow(`SELECT role FROM conversation_participants WHERE conv_id = $1 AND member_id = $2 AND member_type = 'user'`,
		convID, creator.ID).Scan(&creatorRole)
	if creatorRole != "owner" {
		t.Errorf("creator role = %s, want owner", creatorRole)
	}
}

// TestConversationHandler_Create_GroupUserByUsernames 验证群聊创建支持
// member_usernames 反查(client 不持 user_id,spec §4.2 防枚举)。
//
// 场景:creator 是 m1 / m2 的好友,POST /api/conversations body 带
// type=group_user + member_usernames=[m1, m2],server 反查 user_id 并建群。
// 期望:conversations.type=group_user + 3 行 participants(creator=owner, m1/m2=member)。
func TestConversationHandler_Create_GroupUserByUsernames(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	mrepo := repository.NewMessageRepo(db)
	prepo := repository.NewParticipantRepo(db)
	frepo := repository.NewFriendshipRepo(db)

	creator, _ := urepo.Create(t.Context(), shortName(t, "gnbu"), "$2a$10$hash")
	m1, _ := urepo.Create(t.Context(), shortName(t, "gnbm1"), "$2a$10$hash")
	m2, _ := urepo.Create(t.Context(), shortName(t, "gnbm2"), "$2a$10$hash")
	// 注:group_user 路径不强制好友(spec §4.2 仅 dm_user_user 校验),
	// 但仍建好友关系让测试贴近真实场景。
	fr1, err := frepo.CreateRequest(t.Context(), creator.ID, m1.ID)
	if err != nil {
		t.Fatalf("CreateRequest m1: %v", err)
	}
	if err := frepo.Accept(t.Context(), fr1.ID, m1.ID); err != nil {
		t.Fatalf("Accept m1: %v", err)
	}
	fr2, err := frepo.CreateRequest(t.Context(), creator.ID, m2.ID)
	if err != nil {
		t.Fatalf("CreateRequest m2: %v", err)
	}
	if err := frepo.Accept(t.Context(), fr2.ID, m2.ID); err != nil {
		t.Fatalf("Accept m2: %v", err)
	}

	drepo := repository.NewDeliveryRepo(db)
	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, drepo, arepo, urepo, nil, nil, repository.NewAgentTypeRepo(db))
	r := gin.New()
	r.POST("/api/conversations", func(c *gin.Context) {
		c.Set("userID", creator.ID)
		h.Create(c)
	})

	// 故意只传 member_usernames + 不传 member_ids/types,验证 server 端反查填回
	body := fmt.Sprintf(
		`{"type":"group_user","member_usernames":["%s","%s"],"title":"test group"}`,
		m1.Username, m2.Username,
	)
	req := httptest.NewRequest("POST", "/api/conversations", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("期望 200, 实际 %d body=%s", w.Code, w.Body.String())
	}

	// envelope: {ok:true, data:{id, last_message_at, ...}}
	data := AssertOk(t, w, http.StatusOK)
	convID, _ := data["id"].(string)
	lastMessageAt, _ := data["last_message_at"].(string)

	// 校验:conversations 表 type=group_user
	var convType string
	err = db.QueryRow(`SELECT type FROM conversations WHERE id=$1`, convID).Scan(&convType)
	if err != nil {
		t.Fatalf("查 conversations 失败: %v", err)
	}
	if convType != "group_user" {
		t.Errorf("type 错误: 期望 group_user, 实际 %s", convType)
	}

	// 校验:conversation_participants 表有 3 行(owner=creator + member=m1 + member=m2)
	var count int
	err = db.QueryRow(
		`SELECT COUNT(*) FROM conversation_participants WHERE conv_id=$1`,
		convID,
	).Scan(&count)
	if err != nil {
		t.Fatalf("查 participants 失败: %v", err)
	}
	if count != 3 {
		t.Errorf("participants 行数错误: 期望 3, 实际 %d", count)
	}

	// 校验:creator 是 owner, m1 / m2 是 member
	var roleCreator, roleM1, roleM2 string
	_ = db.QueryRow(`SELECT role FROM conversation_participants WHERE conv_id=$1 AND member_id=$2 AND member_type='user'`,
		convID, creator.ID).Scan(&roleCreator)
	_ = db.QueryRow(`SELECT role FROM conversation_participants WHERE conv_id=$1 AND member_id=$2 AND member_type='user'`,
		convID, m1.ID).Scan(&roleM1)
	_ = db.QueryRow(`SELECT role FROM conversation_participants WHERE conv_id=$1 AND member_id=$2 AND member_type='user'`,
		convID, m2.ID).Scan(&roleM2)
	if roleCreator != "owner" || roleM1 != "member" || roleM2 != "member" {
		t.Errorf("role 错误: creator=%s m1=%s m2=%s (期望 creator=owner, m1/m2=member)",
			roleCreator, roleM1, roleM2)
	}

	// 校验:无消息新建会话的 last_message_at 应 fallback 到 createdAt
	// (buildDetail 兜底逻辑,避免 client 拿到 0001-01-01 零值显示异常)
	if lastMessageAt == "" {
		t.Error("last_message_at 为空,期望非空(应 fallback 到 created_at)")
	}
	if strings.HasPrefix(lastMessageAt, "0001-01-01") {
		t.Errorf("last_message_at 是零值 %s,期望 fallback 到 created_at", lastMessageAt)
	}
}

// TestConversationHandler_Create_GroupUser_RejectsAmbiguousMembers 校验
// group_user 场景同时传 member_ids + member_usernames 时,helper 应 fail-fast
// 返 400(防语义模糊)。
func TestConversationHandler_Create_GroupUser_RejectsAmbiguousMembers(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	mrepo := repository.NewMessageRepo(db)
	prepo := repository.NewParticipantRepo(db)
	frepo := repository.NewFriendshipRepo(db)

	creator, _ := urepo.Create(t.Context(), shortName(t, "amb"), "$2a$10$hash")

	drepo := repository.NewDeliveryRepo(db)
	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, drepo, arepo, urepo, nil, nil, repository.NewAgentTypeRepo(db))
	r := gin.New()
	r.POST("/api/conversations", func(c *gin.Context) {
		c.Set("userID", creator.ID)
		h.Create(c)
	})

	body := `{"type":"group_user","member_usernames":["some-username"],"member_ids":["some-uuid"],"member_types":["user"]}`
	req := httptest.NewRequest("POST", "/api/conversations", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusBadRequest, "bad_request")
}

// TestConversationHandler_Create_GroupUser_RejectsDuplicateUsernames 校验
// group_user 场景 member_usernames 含重复 username 时,helper 应 fail-fast 返 400。
func TestConversationHandler_Create_GroupUser_RejectsDuplicateUsernames(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	mrepo := repository.NewMessageRepo(db)
	prepo := repository.NewParticipantRepo(db)
	frepo := repository.NewFriendshipRepo(db)

	creator, _ := urepo.Create(t.Context(), shortName(t, "dup"), "$2a$10$hash")
	m1, _ := urepo.Create(t.Context(), shortName(t, "dupm"), "$2a$10$hash")

	drepo := repository.NewDeliveryRepo(db)
	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, drepo, arepo, urepo, nil, nil, repository.NewAgentTypeRepo(db))
	r := gin.New()
	r.POST("/api/conversations", func(c *gin.Context) {
		c.Set("userID", creator.ID)
		h.Create(c)
	})

	// 故意把同一 username 传两次,模拟 client dedup bug
	body := fmt.Sprintf(
		`{"type":"group_user","member_usernames":["%s","%s"]}`,
		m1.Username, m1.Username,
	)
	req := httptest.NewRequest("POST", "/api/conversations", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusBadRequest, "bad_request")
}

// TestConversationHandler_Create_GroupUser_RejectsTooFewMembers 校验
// group_user 只传 1 个 username 时返 400(群聊至少需要 2 个 member,含 creator 共 3 人)。
func TestConversationHandler_Create_GroupUser_RejectsTooFewMembers(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	mrepo := repository.NewMessageRepo(db)
	prepo := repository.NewParticipantRepo(db)
	frepo := repository.NewFriendshipRepo(db)

	creator, _ := urepo.Create(t.Context(), shortName(t, "few"), "$2a$10$hash")
	// 用真实存在的 user(反查 username 会通过,之后才走到 group member 不足检查)
	m1, _ := urepo.Create(t.Context(), shortName(t, "fewm"), "$2a$10$hash")

	drepo := repository.NewDeliveryRepo(db)
	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, drepo, arepo, urepo, nil, nil, repository.NewAgentTypeRepo(db))
	r := gin.New()
	r.POST("/api/conversations", func(c *gin.Context) {
		c.Set("userID", creator.ID)
		h.Create(c)
	})

	body := fmt.Sprintf(`{"type":"group_user","member_usernames":["%s"]}`, m1.Username)
	req := httptest.NewRequest("POST", "/api/conversations", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusBadRequest, "bad_request")
}

// TestConversationHandler_Create_InvalidType 验证未知 type 返 400。
func TestConversationHandler_Create_InvalidType(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	mrepo := repository.NewMessageRepo(db)
	prepo := repository.NewParticipantRepo(db)
	frepo := repository.NewFriendshipRepo(db)

	user, _ := urepo.Create(t.Context(), shortName(t, "cit"), "$2a$10$hash")

	drepo := repository.NewDeliveryRepo(db)
	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, drepo, arepo, urepo, nil, nil, repository.NewAgentTypeRepo(db))
	r := gin.New()
	r.POST("/api/conversations", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.Create(c)
	})

	body := `{"type":"channel_xxx","member_ids":["x"],"member_types":["user"]}`
	req := httptest.NewRequest("POST", "/api/conversations", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusBadRequest, "bad_request")
}

// TestConversationHandler_Create_AgentSession 验证 user 视角建 agent_session 群:
// type=agent_session + member_ids=[agentId] + member_types=["agent"],
// server 建 conv + 同步通知 plugin 创建 OC session + 2 participants。
func TestConversationHandler_Create_AgentSession(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	mrepo := repository.NewMessageRepo(db)
	prepo := repository.NewParticipantRepo(db)
	frepo := repository.NewFriendshipRepo(db)

	user, _ := urepo.Create(t.Context(), shortName(t, "as"), "$2a$10$hash")
	agent, _ := arepo.Create(t.Context(), user.ID, shortName(t, "asag"), "sk", "opencode")

	drepo := repository.NewDeliveryRepo(db)
	registry := hub.NewRPCRegistry()
	hubInstance := hub.NewHub(nil, arepo, prepo, registry)
	fakeClient := newFakeAgentClient(t, hubInstance, agent.ID)
	defer fakeClient.Close()

	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, drepo, arepo, urepo, hubInstance, registry, repository.NewAgentTypeRepo(db))
	r := gin.New()
	r.POST("/api/conversations", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.Create(c)
	})

	body := fmt.Sprintf(
		`{"type":"agent_session","member_ids":["%s"],"member_types":["agent"]}`,
		agent.ID,
	)
	req := httptest.NewRequest("POST", "/api/conversations", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	go func() {
		resultJSON, _ := json.Marshal(map[string]any{"opencode_session_id": "sess-mock"})
		resolveFirstCall(t, fakeClient, registry, resultJSON, 5*time.Second)
	}()

	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("期望 200, 实际 %d body=%s", w.Code, w.Body.String())
	}
	data := AssertOk(t, w, http.StatusOK)
	convID, _ := data["id"].(string)
	if convID == "" {
		t.Fatal("期望返回 conv id")
	}

	// 校验 conversations 表 type=agent_session
	var convType string
	_ = db.QueryRow(`SELECT type FROM conversations WHERE id = $1`, convID).Scan(&convType)
	if convType != "agent_session" {
		t.Errorf("conversations.type = %s, want agent_session", convType)
	}
	// 校验 2 个 participants(user=owner, agent=member)
	var n int
	_ = db.QueryRow(`SELECT COUNT(*) FROM conversation_participants WHERE conv_id = $1`, convID).Scan(&n)
	if n != 2 {
		t.Errorf("participant 数 = %d, want 2", n)
	}
	var agentRole string
	_ = db.QueryRow(`SELECT role FROM conversation_participants WHERE conv_id = $1 AND member_id = $2 AND member_type = 'agent'`,
		convID, agent.ID).Scan(&agentRole)
	if agentRole != "member" {
		t.Errorf("agent role = %s, want member", agentRole)
	}
}

// TestConversationHandler_Create_AgentSession_RequiresOwner 验证 user 不是 agent owner 时返 403。
func TestConversationHandler_Create_AgentSession_RequiresOwner(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	mrepo := repository.NewMessageRepo(db)
	prepo := repository.NewParticipantRepo(db)
	frepo := repository.NewFriendshipRepo(db)

	owner, _ := urepo.Create(t.Context(), shortName(t, "asown"), "$2a$10$hash")
	other, _ := urepo.Create(t.Context(), shortName(t, "asoth"), "$2a$10$hash")
	agent, _ := arepo.Create(t.Context(), owner.ID, shortName(t, "asag2"), "sk", "opencode")

	drepo := repository.NewDeliveryRepo(db)
	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, drepo, arepo, urepo, nil, nil, repository.NewAgentTypeRepo(db))
	r := gin.New()
	r.POST("/api/conversations", func(c *gin.Context) {
		c.Set("userID", other.ID) // other 不是 owner
		h.Create(c)
	})

	body := fmt.Sprintf(
		`{"type":"agent_session","member_ids":["%s"],"member_types":["agent"]}`,
		agent.ID,
	)
	req := httptest.NewRequest("POST", "/api/conversations", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusForbidden, "forbidden")
}

// TestConversationHandler_Create_AgentSession_RejectsBadMember 校验 member 配置错。
func TestConversationHandler_Create_AgentSession_RejectsBadMember(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	mrepo := repository.NewMessageRepo(db)
	prepo := repository.NewParticipantRepo(db)
	frepo := repository.NewFriendshipRepo(db)

	user, _ := urepo.Create(t.Context(), shortName(t, "asbm"), "$2a$10$hash")

	drepo := repository.NewDeliveryRepo(db)
	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, drepo, arepo, urepo, nil, nil, repository.NewAgentTypeRepo(db))
	r := gin.New()
	r.POST("/api/conversations", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.Create(c)
	})

	cases := []struct {
		name string
		body string
	}{
		{"zero member", `{"type":"agent_session","member_ids":[],"member_types":[]}`},
		{"two member", `{"type":"agent_session","member_ids":["a","b"],"member_types":["agent","agent"]}`},
		{"non-agent type", `{"type":"agent_session","member_ids":["a"],"member_types":["user"]}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest("POST", "/api/conversations", strings.NewReader(tc.body))
			req.Header.Set("Content-Type", "application/json")
			w := httptest.NewRecorder()
			r.ServeHTTP(w, req)
			AssertErr(t, w, http.StatusBadRequest, "bad_request")
		})
	}
}

// TestConversationHandler_Create_AgentSession_404UnknownAgent 校验 agent 不存在返 404。
func TestConversationHandler_Create_AgentSession_404UnknownAgent(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	mrepo := repository.NewMessageRepo(db)
	prepo := repository.NewParticipantRepo(db)
	frepo := repository.NewFriendshipRepo(db)

	user, _ := urepo.Create(t.Context(), shortName(t, "as404"), "$2a$10$hash")

	drepo := repository.NewDeliveryRepo(db)
	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, drepo, arepo, urepo, nil, nil, repository.NewAgentTypeRepo(db))
	r := gin.New()
	r.POST("/api/conversations", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.Create(c)
	})

	body := `{"type":"agent_session","member_ids":["00000000-0000-0000-0000-000000000000"],"member_types":["agent"]}`
	req := httptest.NewRequest("POST", "/api/conversations", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusNotFound, "not_found")
}

// === Get 测试 ===

// TestConversationHandler_Get_AsParticipant 验证 participant 能拿会话详情。
func TestConversationHandler_Get_AsParticipant(t *testing.T) {
	f := seedUserAgentConv(t, "get")

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.Get(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations/"+f.convID, nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	if !strings.Contains(w.Body.String(), `"type":"dm_user_agent"`) {
		t.Errorf("响应缺少 type: %s", w.Body.String())
	}
}

// TestConversationHandler_Get_NonParticipant_403 验证非 participant 访问返 403。
func TestConversationHandler_Get_NonParticipant_403(t *testing.T) {
	f := seedUserAgentConv(t, "getnp")

	// 另一个 user 不在该会话
	other, _ := repository.NewUserRepo(f.db).Create(t.Context(), shortName(t, "other"), "$2a$10$hash")

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id", func(c *gin.Context) {
		c.Set("userID", other.ID)
		h.Get(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations/"+f.convID, nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusForbidden, "forbidden")
}

// TestConversationHandler_Get_AgentSession_ReturnsAgentSummary 验证 agent_session 详情
// 也回填 agent 摘要(含 type + status),修复 buildDetail 仅 dm_user_agent 才填的遗漏。
func TestConversationHandler_Get_AgentSession_ReturnsAgentSummary(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	mrepo := repository.NewMessageRepo(db)
	prepo := repository.NewParticipantRepo(db)
	drepo := repository.NewDeliveryRepo(db)
	frepo := repository.NewFriendshipRepo(db)

	user, _ := urepo.Create(t.Context(), shortName(t, "asget"), "$2a$10$hash")
	agent, _ := arepo.Create(t.Context(), user.ID, shortName(t, "asagget"), "sk", "opencode")
	conv, err := crepo.CreateAgentSession(t.Context(), user.ID, agent.ID, "s1", "")
	if err != nil {
		t.Fatalf("CreateAgentSession 失败: %v", err)
	}

	hubInstance := hub.NewHub(nil, arepo, prepo, nil)
	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, drepo, arepo, urepo, hubInstance, nil, repository.NewAgentTypeRepo(db))
	r := gin.New()
	r.GET("/api/conversations/:id", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.Get(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations/"+conv.ID, nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	body := w.Body.String()
	if !strings.Contains(body, `"agent":{`) {
		t.Fatalf("agent_session 详情缺少 agent 摘要: %s", body)
	}
	if !strings.Contains(body, `"type":"opencode"`) {
		t.Errorf("agent.type 缺失/错误: %s", body)
	}
	if !strings.Contains(body, `"status":"offline"`) && !strings.Contains(body, `"status":"online"`) {
		t.Errorf("agent.status 缺失: %s", body)
	}
}

// TestConversationHandler_Get_DMUserUser_ReturnsOtherUser 验证 dm_user_user 详情
// 回填 other_user 摘要(对方 = user 参与者中非请求者):client displayName 优先
// other_user,缺失时 fallback participants 首个 user(不排除自己),
// 会把标题/输入框占位显示成自己的昵称。
func TestConversationHandler_Get_DMUserUser_ReturnsOtherUser(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	mrepo := repository.NewMessageRepo(db)
	prepo := repository.NewParticipantRepo(db)
	drepo := repository.NewDeliveryRepo(db)
	frepo := repository.NewFriendshipRepo(db)

	user, _ := urepo.Create(t.Context(), shortName(t, "dmou1"), "$2a$10$hash")
	other, _ := urepo.Create(t.Context(), shortName(t, "dmou2"), "$2a$10$hash")

	// 建好友关系:发请求 + accept
	fr, err := frepo.CreateRequest(t.Context(), user.ID, other.ID)
	if err != nil {
		t.Fatalf("CreateRequest: %v", err)
	}
	if err := frepo.Accept(t.Context(), fr.ID, other.ID); err != nil {
		t.Fatalf("Accept: %v", err)
	}

	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, drepo, arepo, urepo, nil, nil, repository.NewAgentTypeRepo(db))
	r := gin.New()
	r.POST("/api/conversations", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.Create(c)
	})
	r.GET("/api/conversations/:id", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.Get(c)
	})

	body := fmt.Sprintf(`{"type":"dm_user_user","member_ids":["%s"],"member_types":["user"]}`, other.ID)
	req := httptest.NewRequest("POST", "/api/conversations", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("创建 dm_user_user 应 200, 实际: %d body: %s", w.Code, w.Body.String())
	}
	var created struct {
		Data struct {
			ID string `json:"id"`
		} `json:"data"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil || created.Data.ID == "" {
		t.Fatalf("解析创建响应失败: %v body: %s", err, w.Body.String())
	}

	req2 := httptest.NewRequest("GET", "/api/conversations/"+created.Data.ID, nil)
	w2 := httptest.NewRecorder()
	r.ServeHTTP(w2, req2)
	if w2.Code != http.StatusOK {
		t.Fatalf("详情状态码: %d body: %s", w2.Code, w2.Body.String())
	}

	var resp struct {
		Data struct {
			OtherUser *struct {
				Username string `json:"username"`
			} `json:"other_user"`
		} `json:"data"`
	}
	if err := json.Unmarshal(w2.Body.Bytes(), &resp); err != nil {
		t.Fatalf("解析详情响应: %v", err)
	}
	if resp.Data.OtherUser == nil {
		t.Fatalf("dm_user_user 详情缺少 other_user: %s", w2.Body.String())
	}
	if resp.Data.OtherUser.Username != other.Username {
		t.Errorf("other_user.username = %s, want %s(不能是请求者自己)", resp.Data.OtherUser.Username, other.Username)
	}
}

// === CreateAsAgent 测试 ===

// TestCreateAsAgentSuccess 验证 agent 视角 findOrCreate:能正确建 dm_user_agent,
// 响应里含 conv id 和 user 详情(不含 password_hash)。
func TestCreateAsAgentSuccess(t *testing.T) {
	f := seedUserAgentConv(t, "caas")

	h := newConvHandler(f)

	body, _ := json.Marshal(map[string]string{"user_id": f.user.ID})
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/api/agents/me/conversations", bytes.NewReader(body))
	c.Set("userID", f.agent.ID)
	c.Set("role", "agent")

	h.CreateAsAgent(c)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	resp := w.Body.String()
	if !strings.Contains(resp, `"id":`) {
		t.Errorf("missing conv id: %s", resp)
	}
	if !strings.Contains(resp, `"username":"`) {
		t.Errorf("missing user.username in response: %s", resp)
	}
	if strings.Contains(resp, "password_hash") {
		t.Errorf("password_hash leaked: %s", resp)
	}
}

// TestCreateAsAgentRejectsNonexistentUser 验证对端 user 不存在时返 404(而非 500)。
func TestCreateAsAgentRejectsNonexistentUser(t *testing.T) {
	f := seedUserAgentConv(t, "caan")

	h := newConvHandler(f)

	body, _ := json.Marshal(map[string]string{"user_id": "00000000-0000-0000-0000-000000000000"})
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/api/agents/me/conversations", bytes.NewReader(body))
	c.Set("userID", f.agent.ID)
	c.Set("role", "agent")

	h.CreateAsAgent(c)

	AssertErr(t, w, http.StatusNotFound, "not_found")
}

// TestCreateAsAgentIdempotent 验证同一 (agent, user) 二次调用不新建会话,返回同一 conv_id。
func TestCreateAsAgentIdempotent(t *testing.T) {
	f := seedUserAgentConv(t, "caai")

	h := newConvHandler(f)

	call := func() string {
		body, _ := json.Marshal(map[string]string{"user_id": f.user.ID})
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Request = httptest.NewRequest("POST", "/", bytes.NewReader(body))
		c.Set("userID", f.agent.ID)
		h.CreateAsAgent(c)
		// envelope: {ok:true, data:{id, ...}}
		data := AssertOk(t, w, http.StatusOK)
		id, _ := data["id"].(string)
		return id
	}

	id1 := call()
	id2 := call()
	if id1 == "" || id2 == "" {
		t.Fatalf("expected non-empty ids, got %q and %q", id1, id2)
	}
	if id1 != id2 {
		t.Errorf("expected idempotent conv_id, got %s then %s", id1, id2)
	}
}

// TestCreateAsAgentRejectsNonOwner 验证 owner 强制约束(P0 修复):
// agent 只能跟自己的 owner 建 dm,body 传非 owner 的 user_id 时返 403 forbidden。
// 防 client 把 user_id 配错成别人的 id 导致消息发到错的 user。
func TestCreateAsAgentRejectsNonOwner(t *testing.T) {
	f := seedUserAgentConv(t, "caarn")

	// 再建一个 user(非 owner),模拟 client 配错 WANLING_USER_ID 的场景
	urepo := repository.NewUserRepo(f.db)
	nonOwner, err := urepo.Create(t.Context(), shortName(t, "nonowner"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create non-owner user 失败: %v", err)
	}

	h := newConvHandler(f)

	body, _ := json.Marshal(map[string]string{"user_id": nonOwner.ID})
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/api/agents/me/conversations", bytes.NewReader(body))
	c.Set("userID", f.agent.ID)
	c.Set("role", "agent")

	h.CreateAsAgent(c)

	AssertErr(t, w, http.StatusForbidden, "forbidden")
}

// TestCreateAsAgent_AgentSession_NotDedup 验收红线:同 (owner, agent) 连建 3 个
// agent_session 必须返 3 个不同 conv_id。
// 防止误用 FindOrCreateDM(其 (type+member set) 去重会合成 1 个)。
func TestCreateAsAgent_AgentSession_NotDedup(t *testing.T) {
	f := seedUserAgentConv(t, "caasess")

	h := newConvHandler(f)

	create := func() string {
		body, _ := json.Marshal(map[string]string{
			"user_id": f.user.ID,
			"type":    "agent_session",
			"title":   "session-xxx",
		})
		w := httptest.NewRecorder()
		c, _ := gin.CreateTestContext(w)
		c.Request = httptest.NewRequest("POST", "/", bytes.NewReader(body))
		c.Set("userID", f.agent.ID)
		c.Set("role", "agent")
		h.CreateAsAgent(c)
		data := AssertOk(t, w, http.StatusOK)
		id, _ := data["id"].(string)
		return id
	}

	id1 := create()
	id2 := create()
	id3 := create()
	if id1 == "" || id2 == "" || id3 == "" {
		t.Fatalf("expected non-empty ids: %q %q %q", id1, id2, id3)
	}
	seen := map[string]bool{}
	for _, id := range []string{id1, id2, id3} {
		if seen[id] {
			t.Errorf("发现重复 conv_id(被错误去重): %s", id)
		}
		seen[id] = true
	}
	if len(seen) != 3 {
		t.Errorf("期望 3 个不同 conv_id,实际 %d", len(seen))
	}
}

// TestCreateAsAgent_DefaultStillDM agent_session 默认(不传 type)仍走老 dm 分支,保持向后兼容。
func TestCreateAsAgent_DefaultStillDM(t *testing.T) {
	f := seedUserAgentConv(t, "caadm")
	h := newConvHandler(f)

	body, _ := json.Marshal(map[string]string{"user_id": f.user.ID})
	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("POST", "/", bytes.NewReader(body))
	c.Set("userID", f.agent.ID)
	c.Set("role", "agent")
	h.CreateAsAgent(c)

	data := AssertOk(t, w, http.StatusOK)
	if tp, _ := data["type"].(string); tp != "dm_user_agent" {
		t.Errorf("默认 type = %q, want dm_user_agent", tp)
	}
}

// === Messages 测试(游标分页 + 越权) ===

// TestConversationHandler_Messages_BeforeCursor 验证 before 游标分页:
//   - before 参数优先于 offset;
//   - cursor 过滤 + 排序正确;
//   - limit 截断生效。
func TestConversationHandler_Messages_BeforeCursor(t *testing.T) {
	f := seedUserAgentConv(t, "mbc")

	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "hi"},
	})
	var ids []string
	for i := 0; i < 3; i++ {
		m, err := f.mRepo.Create(t.Context(), f.convID, "user", f.user.ID, content)
		if err != nil {
			t.Fatalf("Create m%d: %v", i, err)
		}
		ids = append(ids, m.ID)
		time.Sleep(2 * time.Millisecond)
	}

	m2, _ := f.mRepo.Get(t.Context(), ids[1])

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id/messages", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.Messages(c)
	})

	url := "/api/conversations/" + f.convID + "/messages?before=" + m2.CreatedAt.UTC().Format(time.RFC3339Nano) + "&limit=1"
	req := httptest.NewRequest("GET", url, nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	got := AssertOkList(t, w, http.StatusOK)
	if len(got) != 1 {
		t.Fatalf("期望 1 条,实际 %d", len(got))
	}
	first, _ := got[0].(map[string]any)
	if first["id"] != ids[0] {
		t.Errorf("期望 m1(%s),实际 %v", ids[0], first["id"])
	}
}

// TestConversationHandler_Messages_BeforeBadFormat 验证 before 参数格式错误返 400。
func TestConversationHandler_Messages_BeforeBadFormat(t *testing.T) {
	f := seedUserAgentConv(t, "mbf")

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id/messages", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.Messages(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations/"+f.convID+"/messages?before=not-a-time", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusBadRequest, "bad_request")
}

// TestConversationHandler_Messages_NonParticipant_403 验证越权访问返 403。
func TestConversationHandler_Messages_NonParticipant_403(t *testing.T) {
	f := seedUserAgentConv(t, "mnp")

	other, _ := repository.NewUserRepo(f.db).Create(t.Context(), shortName(t, "other"), "$2a$10$hash")

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id/messages", func(c *gin.Context) {
		c.Set("userID", other.ID)
		h.Messages(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations/"+f.convID+"/messages", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusForbidden, "forbidden")
}

// TestConversationHandler_Messages_AfterCursor 验证 after 游标分页(更新方向,定位首条未读场景)。
func TestConversationHandler_Messages_AfterCursor(t *testing.T) {
	f := seedUserAgentConv(t, "mac")

	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "hi"},
	})
	var ids []string
	for i := 0; i < 4; i++ {
		m, err := f.mRepo.Create(t.Context(), f.convID, "user", f.user.ID, content)
		if err != nil {
			t.Fatalf("Create m%d: %v", i, err)
		}
		ids = append(ids, m.ID)
		time.Sleep(2 * time.Millisecond)
	}

	m2, _ := f.mRepo.Get(t.Context(), ids[1])

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id/messages", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.Messages(c)
	})

	url := "/api/conversations/" + f.convID + "/messages?after=" +
		m2.CreatedAt.Add(-time.Millisecond).UTC().Format(time.RFC3339Nano) + "&limit=10"
	req := httptest.NewRequest("GET", url, nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	got := AssertOkList(t, w, http.StatusOK)
	if len(got) != 3 {
		t.Fatalf("期望 3 条(m2~m4),实际 %d", len(got))
	}
	first, _ := got[0].(map[string]any)
	if first["id"] != ids[1] {
		t.Errorf("ASC 第一条期望 m2(%s),实际 %v", ids[1], first["id"])
	}
	last, _ := got[2].(map[string]any)
	if last["id"] != ids[3] {
		t.Errorf("ASC 最后一条期望 m4(%s),实际 %v", ids[3], last["id"])
	}
}

// TestConversationHandler_Messages_AfterBadFormat 验证 after 参数格式错误返 400。
func TestConversationHandler_Messages_AfterBadFormat(t *testing.T) {
	f := seedUserAgentConv(t, "mab")

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id/messages", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.Messages(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations/"+f.convID+"/messages?after=not-a-time", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusBadRequest, "bad_request")
}

// TestConversationHandler_Messages_DefaultFilterParentNull 验证无 root_msg_id 时
// Messages handler 默认过滤 parent_msg_id IS NULL 的子 agent 事件,主聊天列表只返主消息。
func TestConversationHandler_Messages_DefaultFilterParentNull(t *testing.T) {
	f := seedUserAgentConv(t, "mdf")

	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "main"},
	})
	rootMsg, err := f.mRepo.Create(t.Context(), f.convID, "user", f.user.ID, content)
	if err != nil {
		t.Fatalf("Create root 失败: %v", err)
	}
	time.Sleep(2 * time.Millisecond)

	childContent := json.RawMessage(`{"msg_type":"reasoning","data":{"text":"child"}}`)
	if _, err := f.mRepo.CreateWithParent(
		t.Context(), f.convID, "agent", f.agent.ID, childContent,
		rootMsg.ID, rootMsg.ID,
	); err != nil {
		t.Fatalf("CreateWithParent 失败: %v", err)
	}

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id/messages", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.Messages(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations/"+f.convID+"/messages", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	got := AssertOkList(t, w, http.StatusOK)
	if len(got) != 1 {
		t.Fatalf("主列表期望 1 条(只含主消息,子事件被过滤), 实际 %d", len(got))
	}
	first, _ := got[0].(map[string]any)
	if first["id"] != rootMsg.ID {
		t.Errorf("主列表应只含主消息 %s, 实际 %v", rootMsg.ID, first["id"])
	}
}

// TestConversationHandler_Messages_WithRootMsgID 验证 ?root_msg_id=X 调用 ListByRoot
// 返回子树(child subtree,不含根本身)。
func TestConversationHandler_Messages_WithRootMsgID(t *testing.T) {
	f := seedUserAgentConv(t, "mrm")

	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "tool_card",
		"data":     map[string]string{"name": "task", "status": "starting"},
	})
	rootMsg, err := f.mRepo.Create(t.Context(), f.convID, "agent", f.agent.ID, content)
	if err != nil {
		t.Fatalf("Create root 失败: %v", err)
	}
	time.Sleep(2 * time.Millisecond)

	childContent := json.RawMessage(`{"msg_type":"reasoning","data":{"text":"子 agent 思考"}}`)
	childMsg, err := f.mRepo.CreateWithParent(
		t.Context(), f.convID, "agent", f.agent.ID, childContent,
		rootMsg.ID, rootMsg.ID,
	)
	if err != nil {
		t.Fatalf("CreateWithParent 失败: %v", err)
	}

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id/messages", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.Messages(c)
	})

	url := "/api/conversations/" + f.convID + "/messages?root_msg_id=" + rootMsg.ID
	req := httptest.NewRequest("GET", url, nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	got := AssertOkList(t, w, http.StatusOK)
	if len(got) != 1 {
		t.Fatalf("子树查询期望 1 条(只含子事件,不含根), 实际 %d", len(got))
	}
	first, _ := got[0].(map[string]any)
	if first["id"] != childMsg.ID {
		t.Errorf("子树应返子事件 %s, 实际 %v", childMsg.ID, first["id"])
	}
	// 反向校验:子树结果不应包含根本身
	for _, item := range got {
		m, _ := item.(map[string]any)
		if m["id"] == rootMsg.ID {
			t.Errorf("子树结果不应包含根本身 %s", rootMsg.ID)
		}
	}
}

// === MarkRead / MarkMessagesRead 测试 ===

// TestConversationHandler_MarkRead_ClearsUnreadCount 验证整会话标已读:
//   - 200 响应;
//   - participant 行的 unread_count 重置为 0。
func TestConversationHandler_MarkRead_ClearsUnreadCount(t *testing.T) {
	f := seedUserAgentConv(t, "mrc")
	// 制造 2 条 agent → user 未读
	for i := 0; i < 2; i++ {
		f.addUnreadAgentMessage(t)
	}
	// 校验起点:unread_count = 2
	assertConvUnread(t, f.db, f.convID, f.user.ID, "user", 2)

	h := newConvHandler(f)
	r := gin.New()
	r.POST("/api/conversations/:id/read", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.MarkRead(c)
	})

	req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/read", f.convID), nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	// participant 行 unread_count 应为 0
	assertConvUnread(t, f.db, f.convID, f.user.ID, "user", 0)
}

// TestConversationHandler_MarkRead_NonParticipant_403 验证越权返 403。
func TestConversationHandler_MarkRead_NonParticipant_403(t *testing.T) {
	f := seedUserAgentConv(t, "mrnp")

	other, _ := repository.NewUserRepo(f.db).Create(t.Context(), shortName(t, "other"), "$2a$10$hash")

	h := newConvHandler(f)
	r := gin.New()
	r.POST("/api/conversations/:id/read", func(c *gin.Context) {
		c.Set("userID", other.ID)
		h.MarkRead(c)
	})

	req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/read", f.convID), nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusForbidden, "forbidden")
}

// TestConversationHandler_MarkMessagesRead 验证按 messageId 部分标记:
// 3 条未读 → 标记 2 条 → 响应 unread_count=1 + DB participant.unread_count=1。
func TestConversationHandler_MarkMessagesRead(t *testing.T) {
	f := seedUserAgentConv(t, "mmr")
	msgIDs := make([]string, 3)
	for i := 0; i < 3; i++ {
		msgIDs[i] = f.addUnreadAgentMessage(t)
	}

	h := newConvHandler(f)
	r := gin.New()
	r.POST("/api/conversations/:id/messages/read", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.MarkMessagesRead(c)
	})

	body, _ := json.Marshal(map[string][]string{"message_ids": {msgIDs[0], msgIDs[1]}})
	req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/messages/read", f.convID), bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	// envelope: {ok:true, data:{unread_count: N}}
	data := AssertOk(t, w, http.StatusOK)
	unreadCount, _ := data["unread_count"].(float64)
	if int(unreadCount) != 1 {
		t.Errorf("响应 unread_count = %v, want 1", data["unread_count"])
	}
	assertConvUnread(t, f.db, f.convID, f.user.ID, "user", 1)
}

// TestConversationHandler_MarkMessagesRead_ValidatesBody 校验请求体边界:
//   - 空 body / 缺 message_ids → 400;
//   - 超过 100 条 → 400。
func TestConversationHandler_MarkMessagesRead_ValidatesBody(t *testing.T) {
	f := seedUserAgentConv(t, "mvb")

	h := newConvHandler(f)
	r := gin.New()
	r.POST("/api/conversations/:id/messages/read", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.MarkMessagesRead(c)
	})

	t.Run("空 body", func(t *testing.T) {
		req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/messages/read", f.convID), nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertErr(t, w, http.StatusBadRequest, "bad_request")
	})

	t.Run("缺 message_ids 字段", func(t *testing.T) {
		req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/messages/read", f.convID),
			bytes.NewReader([]byte(`{"other":"x"}`)))
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertErr(t, w, http.StatusBadRequest, "bad_request")
	})

	t.Run("超过 100 条", func(t *testing.T) {
		ids := make([]string, 101)
		for i := range ids {
			ids[i] = "x"
		}
		body, _ := json.Marshal(map[string][]string{"message_ids": ids})
		req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/messages/read", f.convID), bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertErr(t, w, http.StatusBadRequest, "bad_request")
	})
}

// TestConversationHandler_MarkMessagesRead_NonParticipant_403 越权返 403。
func TestConversationHandler_MarkMessagesRead_NonParticipant_403(t *testing.T) {
	f := seedUserAgentConv(t, "mmrnp")

	other, _ := repository.NewUserRepo(f.db).Create(t.Context(), shortName(t, "other"), "$2a$10$hash")

	h := newConvHandler(f)
	r := gin.New()
	r.POST("/api/conversations/:id/messages/read", func(c *gin.Context) {
		c.Set("userID", other.ID)
		h.MarkMessagesRead(c)
	})

	body, _ := json.Marshal(map[string][]string{"message_ids": {"00000000-0000-0000-0000-000000000000"}})
	req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/messages/read", f.convID), bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusForbidden, "forbidden")
}

// === Pin / Unpin / Hide 测试 ===

// TestConversationHandler_PinUnpinHide 校验 Pin/Unpin/Hide 个人维度操作正常 + 越权 403。
func TestConversationHandler_PinUnpinHide(t *testing.T) {
	f := seedUserAgentConv(t, "puh")

	h := newConvHandler(f)
	r := gin.New()
	r.POST("/api/conversations/:id/pin", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.Pin(c)
	})
	r.DELETE("/api/conversations/:id/pin", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.Unpin(c)
	})
	r.DELETE("/api/conversations/:id", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.Hide(c)
	})

	// Pin
	req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/pin", f.convID), nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("Pin 失败: %d body: %s", w.Code, w.Body.String())
	}
	var pinned *time.Time
	_ = f.db.QueryRow(`SELECT pinned_at FROM conversation_participants WHERE conv_id=$1 AND member_id=$2 AND member_type='user'`,
		f.convID, f.user.ID).Scan(&pinned)
	if pinned == nil {
		t.Errorf("Pin 后 pinned_at 应非 nil")
	}

	// Unpin
	req = httptest.NewRequest("DELETE", fmt.Sprintf("/api/conversations/%s/pin", f.convID), nil)
	w = httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("Unpin 失败: %d body: %s", w.Code, w.Body.String())
	}
	_ = f.db.QueryRow(`SELECT pinned_at FROM conversation_participants WHERE conv_id=$1 AND member_id=$2 AND member_type='user'`,
		f.convID, f.user.ID).Scan(&pinned)
	if pinned != nil {
		t.Errorf("Unpin 后 pinned_at 应 nil")
	}

	// Hide
	req = httptest.NewRequest("DELETE", fmt.Sprintf("/api/conversations/%s", f.convID), nil)
	w = httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusOK {
		t.Fatalf("Hide 失败: %d body: %s", w.Code, w.Body.String())
	}
	var hidden *time.Time
	_ = f.db.QueryRow(`SELECT hidden_at FROM conversation_participants WHERE conv_id=$1 AND member_id=$2 AND member_type='user'`,
		f.convID, f.user.ID).Scan(&hidden)
	if hidden == nil {
		t.Errorf("Hide 后 hidden_at 应非 nil")
	}
}

// TestConversationHandler_Pin_NonParticipant_403 验证越权返 403。
func TestConversationHandler_Pin_NonParticipant_403(t *testing.T) {
	f := seedUserAgentConv(t, "pnp")

	other, _ := repository.NewUserRepo(f.db).Create(t.Context(), shortName(t, "other"), "$2a$10$hash")

	h := newConvHandler(f)
	r := gin.New()
	r.POST("/api/conversations/:id/pin", func(c *gin.Context) {
		c.Set("userID", other.ID)
		h.Pin(c)
	})

	req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/pin", f.convID), nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusForbidden, "forbidden")
}

// === UnreadInfo 测试 ===

// TestConversationHandler_UnreadInfo_HasUnread 校验有未读时返回:
//   - 200;
//   - unread_count > 0;
//   - first_unread_message_id + first_unread_created_at 非 null。
func TestConversationHandler_UnreadInfo_HasUnread(t *testing.T) {
	f := seedUserAgentConv(t, "uih")
	mID := f.addUnreadAgentMessage(t)

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id/unread", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.UnreadInfo(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations/"+f.convID+"/unread", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	body := w.Body.String()
	if !strings.Contains(body, `"unread_count":1`) {
		t.Errorf("响应缺少 unread_count:1: %s", body)
	}
	if !strings.Contains(body, `"first_unread_message_id":"`+mID+`"`) {
		t.Errorf("响应缺少 first_unread_message_id: %s", body)
	}
	if !strings.Contains(body, `"first_unread_created_at":"`) {
		t.Errorf("响应缺少 first_unread_created_at: %s", body)
	}
}

// TestConversationHandler_UnreadInfo_NoUnread 校验无未读时:
//   - first_unread_message_id 为空字符串;
//   - first_unread_created_at 为 null。
func TestConversationHandler_UnreadInfo_NoUnread(t *testing.T) {
	f := seedUserAgentConv(t, "uin")

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id/unread", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.UnreadInfo(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations/"+f.convID+"/unread", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	body := w.Body.String()
	if !strings.Contains(body, `"first_unread_created_at":null`) {
		t.Errorf("无未读时 first_unread_created_at 应为 null: %s", body)
	}
	if !strings.Contains(body, `"first_unread_message_id":""`) {
		t.Errorf("无未读时 first_unread_message_id 应为空字符串: %s", body)
	}
}

// TestConversationHandler_UnreadInfo_NonParticipant_403 校验越权访问返 403。
func TestConversationHandler_UnreadInfo_NonParticipant_403(t *testing.T) {
	f := seedUserAgentConv(t, "uinp")

	other, _ := repository.NewUserRepo(f.db).Create(t.Context(), shortName(t, "other"), "$2a$10$hash")

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id/unread", func(c *gin.Context) {
		c.Set("userID", other.ID)
		h.UnreadInfo(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations/"+f.convID+"/unread", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusForbidden, "forbidden")
}

// TestConversationHandler_Messages_RecalledSanitized 验证撤回消息在 API 出口处被 sanitize:
//   - 撤回的消息仍出现在 Messages 响应中(spec §1);
//   - content 改写为 {"msg_type":"recalled","data":{}};
//   - 原文 "hello" 不应泄漏。
func TestConversationHandler_Messages_RecalledSanitized(t *testing.T) {
	f := seedUserAgentConv(t, "mrs")

	// 造一条 user 消息(content 含敏感原文 "hello")
	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "hello"},
	})
	m, err := f.mRepo.Create(t.Context(), f.convID, "user", f.user.ID, content)
	if err != nil {
		t.Fatalf("Create msg: %v", err)
	}

	// 撤回该消息（与 production handler 一致走 SoftDeleteTx + 事务）
	tx, err := f.convRepo.BeginTx(t.Context())
	if err != nil {
		t.Fatalf("BeginTx: %v", err)
	}
	if err := f.mRepo.SoftDeleteTx(t.Context(), tx, m.ID); err != nil {
		_ = tx.Rollback()
		t.Fatalf("SoftDeleteTx: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit: %v", err)
	}

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id/messages", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.Messages(c)
	})

	req := httptest.NewRequest("GET", fmt.Sprintf("/api/conversations/%s/messages?limit=50", f.convID), nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	body := w.Body.String()
	// 撤回占位 content 应出现
	if !strings.Contains(body, `"msg_type":"recalled"`) {
		t.Errorf("撤回消息 content 应为 recalled 占位, body: %s", body)
	}
	// 原文 "hello" 不应泄漏
	if strings.Contains(body, "hello") {
		t.Errorf("撤回消息原文不应泄漏, body: %s", body)
	}
}

// TestListAsAgentReturnsAgentConvs 验证 agent 视角列会话:
//   - 初始 fixture 已建 1 条 dm_user_agent(seedUserAgentConv)
//   - 响应 data 应是数组,含至少 1 条,且 id 与 fixture.conv.ID 匹配
func TestListAsAgentReturnsAgentConvs(t *testing.T) {
	f := seedUserAgentConv(t, "laa")
	h := newConvHandler(f)

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("GET", "/api/agents/me/conversations", nil)
	c.Set("userID", f.agent.ID)
	c.Set("role", "agent")

	h.ListAsAgent(c)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	arr := AssertOkList(t, w, http.StatusOK)
	if len(arr) == 0 {
		t.Fatalf("fixture 已建 conv,期望至少 1 条,实际 0")
	}
	first := arr[0].(map[string]any)
	if first["id"] != f.conv.ID {
		t.Errorf("conv id 不一致: 期望 %s 实际 %v", f.conv.ID, first["id"])
	}
}

// TestListAsAgentEmpty 验证 agent 无会话时返空数组(非 nil)。
func TestListAsAgentEmpty(t *testing.T) {
	f := seedUserAgentConv(t, "laae")
	h := newConvHandler(f)

	w := httptest.NewRecorder()
	c, _ := gin.CreateTestContext(w)
	c.Request = httptest.NewRequest("GET", "/api/agents/me/conversations", nil)
	// 用一个 fixture 中不存在的 agent_id(随便拼一个 UUID)
	c.Set("userID", "00000000-0000-0000-0000-000000000000")
	c.Set("role", "agent")

	h.ListAsAgent(c)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}
	arr := AssertOkList(t, w, http.StatusOK)
	if len(arr) != 0 {
		t.Errorf("无 conv agent 应返空数组,实际 %d 条", len(arr))
	}
}

// TestConversationHandler_Messages_ReturnsSenderInfo 验证历史消息也返
// sender_name + sender_avatar_url(跟 WS MESSAGE_CREATE payload 字段一致)。
// 这是 B 方案:server 端补齐字段,让 client 端实时/历史统一从 message 渲染。
func TestConversationHandler_Messages_ReturnsSenderInfo(t *testing.T) {
	f := seedUserAgentConv(t, "msi")

	// 给 user 设昵称 + 头像,验证 COALESCE 优先 nickname
	_, err := f.db.Exec(`
UPDATE users SET nickname = $1, avatar_url = $2 WHERE id = $3`,
		"小明昵称", "/api/files/user-avatar", f.user.ID)
	if err != nil {
		t.Fatalf("update user: %v", err)
	}

	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "hi"},
	})
	_, err = f.mRepo.Create(t.Context(), f.convID, "user", f.user.ID, content)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id/messages", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.Messages(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations/"+f.convID+"/messages?limit=10", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	got := AssertOkList(t, w, http.StatusOK)
	if len(got) != 1 {
		t.Fatalf("期望 1 条,实际 %d", len(got))
	}
	first, _ := got[0].(map[string]any)
	if first["sender_name"] != "小明昵称" {
		t.Errorf("sender_name: 期望 小明昵称, 实际 %v", first["sender_name"])
	}
	if first["sender_avatar_url"] != "/api/files/user-avatar" {
		t.Errorf("sender_avatar_url: 期望 /api/files/user-avatar, 实际 %v", first["sender_avatar_url"])
	}
}

// TestConversationHandler_Messages_ReturnsSenderInfo_AgentSender 验证
// agent sender 走 agents 表 JOIN,返 agent.Name + agents.avatar_url。
func TestConversationHandler_Messages_ReturnsSenderInfo_AgentSender(t *testing.T) {
	f := seedUserAgentConv(t, "msa")

	// 给 agent 设头像
	_, err := f.db.Exec(`UPDATE agents SET avatar_url = $1 WHERE id = $2`,
		"/api/files/agent-avatar", f.agent.ID)
	if err != nil {
		t.Fatalf("update agent: %v", err)
	}

	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "agent hi"},
	})
	_, err = f.mRepo.Create(t.Context(), f.convID, "agent", f.agent.ID, content)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id/messages", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.Messages(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations/"+f.convID+"/messages?limit=10", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	got := AssertOkList(t, w, http.StatusOK)
	if len(got) != 1 {
		t.Fatalf("期望 1 条,实际 %d", len(got))
	}
	first, _ := got[0].(map[string]any)
	if first["sender_name"] != f.agent.Name {
		t.Errorf("sender_name: 期望 %s, 实际 %v", f.agent.Name, first["sender_name"])
	}
	if first["sender_avatar_url"] != "/api/files/agent-avatar" {
		t.Errorf("sender_avatar_url: 期望 /api/files/agent-avatar, 实际 %v", first["sender_avatar_url"])
	}
}

// TestConversationHandler_Messages_FallbackUserNoNickname 验证 user 没 nickname 时
// fallback 用 username(跟 WS processor.senderDisplayName 同语义)。
func TestConversationHandler_Messages_FallbackUserNoNickname(t *testing.T) {
	f := seedUserAgentConv(t, "mfn")
	// user 不设 nickname(默认 NULL),fallback 用 username

	content, _ := json.Marshal(map[string]interface{}{
		"msg_type": "text",
		"data":     map[string]string{"text": "hi"},
	})
	_, err := f.mRepo.Create(t.Context(), f.convID, "user", f.user.ID, content)
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id/messages", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.Messages(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations/"+f.convID+"/messages?limit=10", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	got := AssertOkList(t, w, http.StatusOK)
	first, _ := got[0].(map[string]any)
	if first["sender_name"] != f.user.Username {
		t.Errorf("sender_name: 期望 username(%s), 实际 %v", f.user.Username, first["sender_name"])
	}
}

// === ListAgentSessions 测试 ===

// TestListAgentSessions_HappyPath 验证 user 视角查某 agent 的 agent_session 群:
//   - 建 2 个 agent_session + 1 个 dm_user_agent
//   - GET /api/agents/:id/sessions 应只返 2 个 agent_session,排除 dm
//   - 返回的每条 type=agent_session
func TestListAgentSessions_HappyPath(t *testing.T) {
	f := seedUserAgentConv(t, "las")
	// fixture 已建 1 个 dm_user_agent(f.user ↔ f.agent),作为干扰项不应出现

	// 再建 2 个 agent_session(同 user+agent,多实例)
	conv1, err := f.convRepo.CreateAgentSession(t.Context(), f.user.ID, f.agent.ID, "s1", "")
	if err != nil {
		t.Fatalf("CreateAgentSession s1: %v", err)
	}
	conv2, err := f.convRepo.CreateAgentSession(t.Context(), f.user.ID, f.agent.ID, "s2", "")
	if err != nil {
		t.Fatalf("CreateAgentSession s2: %v", err)
	}

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/agents/:id/sessions", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.ListAgentSessions(c)
	})

	req := httptest.NewRequest("GET", "/api/agents/"+f.agent.ID+"/sessions", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	arr := AssertOkList(t, w, http.StatusOK)
	if len(arr) != 2 {
		t.Fatalf("期望 2 个 agent_session,实际 %d: %s", len(arr), w.Body.String())
	}
	ids := map[string]bool{}
	for _, it := range arr {
		m := it.(map[string]any)
		if m["type"] != model.ConvTypeAgentSession {
			t.Errorf("混入非 agent_session: %v", m["type"])
		}
		ids[m["id"].(string)] = true
	}
	if !ids[conv1.ID] || !ids[conv2.ID] {
		t.Errorf("返回的 session id 不全: got=%v, want %s + %s", ids, conv1.ID, conv2.ID)
	}
}

// TestListAgentSessions_Empty 验证无 agent_session 时返空数组(非 null),
// 且不把 dm_user_agent 误返(只有 dm 时应空)。
func TestListAgentSessions_Empty(t *testing.T) {
	f := seedUserAgentConv(t, "lase")
	// fixture 只有 dm_user_agent,无 agent_session

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/agents/:id/sessions", func(c *gin.Context) {
		c.Set("userID", f.user.ID)
		h.ListAgentSessions(c)
	})

	req := httptest.NewRequest("GET", "/api/agents/"+f.agent.ID+"/sessions", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	arr := AssertOkList(t, w, http.StatusOK)
	if len(arr) != 0 {
		t.Errorf("无 agent_session 应返空数组(排除 dm),实际 %d: %s", len(arr), w.Body.String())
	}
}

// === UpdateTitleAsAgent 测试 ===

// TestUpdateTitleAsAgent_Success 验证 agent 视角改会话标题:
//   - agent 是 participant → 200;
//   - DB 中 conversations.title 实际更新。
func TestUpdateTitleAsAgent_Success(t *testing.T) {
	f := seedUserAgentConv(t, "utaas")

	h := newConvHandler(f)
	r := gin.New()
	r.PATCH("/api/agents/me/conversations/:id/title", func(c *gin.Context) {
		c.Set("userID", f.agent.ID)
		c.Set("role", "agent")
		h.UpdateTitleAsAgent(c)
	})

	body := strings.NewReader(`{"title":"我的 OpenCode 会话"}`)
	req := httptest.NewRequest("PATCH", "/api/agents/me/conversations/"+f.convID+"/title", body)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	// 验证 DB 中 title 实际更新
	conv, err := f.convRepo.GetByID(t.Context(), f.convID)
	if err != nil || conv == nil {
		t.Fatalf("GetByID: %v %v", conv, err)
	}
	if conv.Title != "我的 OpenCode 会话" {
		t.Errorf("title = %q, want 我的 OpenCode 会话", conv.Title)
	}
}

// TestUpdateTitleAsAgent_NonParticipant_403 验证非 participant agent 改标题返 403。
func TestUpdateTitleAsAgent_NonParticipant_403(t *testing.T) {
	f := seedUserAgentConv(t, "utanp")

	// 再建一个 agent(非该会话 participant)
	otherAgent, _ := repository.NewAgentRepo(f.db).Create(t.Context(), f.user.ID, "other-agent", "sk", "")

	h := newConvHandler(f)
	r := gin.New()
	r.PATCH("/api/agents/me/conversations/:id/title", func(c *gin.Context) {
		c.Set("userID", otherAgent.ID)
		c.Set("role", "agent")
		h.UpdateTitleAsAgent(c)
	})

	body := strings.NewReader(`{"title":"hacked"}`)
	req := httptest.NewRequest("PATCH", "/api/agents/me/conversations/"+f.convID+"/title", body)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusForbidden, "forbidden")

	// 验证 DB 中 title 未被篡改
	conv, _ := f.convRepo.GetByID(t.Context(), f.convID)
	if conv.Title == "hacked" {
		t.Error("非 participant 的 title 篡改不应生效")
	}
}

// TestUpdateTitleAsAgent_BroadcastsOnlyToUser 验证 OC→万灵 单向同步的断环点:
// agent 改标题后,user 端收到 CONVERSATION_UPDATE(实时刷新),agent 端收不到
// (否则插件会收到自己触发的标题又去改 OC,形成回声循环)。
func TestUpdateTitleAsAgent_BroadcastsOnlyToUser(t *testing.T) {
	f := seedUserAgentConv(t, "utabou")

	realHub := hub.NewHub(nil, repository.NewAgentRepo(f.db), repository.NewParticipantRepo(f.db), nil)
	userClient := hub.NewClient(t.Context(), f.user.ID, "user", nil)
	agentClient := hub.NewClient(t.Context(), f.agent.ID, "agent", nil)
	realHub.RegisterClient(userClient)
	realHub.RegisterClient(agentClient)

	h := NewConversationHandler(
		f.db, f.convRepo, f.pRepo, nil, f.mRepo, f.dRepo,
		repository.NewAgentRepo(f.db), repository.NewUserRepo(f.db), realHub, nil, repository.NewAgentTypeRepo(f.db),
	)
	r := gin.New()
	r.PATCH("/api/agents/me/conversations/:id/title", func(c *gin.Context) {
		c.Set("userID", f.agent.ID)
		c.Set("role", "agent")
		h.UpdateTitleAsAgent(c)
	})

	body := strings.NewReader(`{"title":"OC 起的新名"}`)
	req := httptest.NewRequest("PATCH", "/api/agents/me/conversations/"+f.convID+"/title", body)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	// user 端收到广播
	select {
	case data := <-userClient.Send:
		var msg model.WSMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		if msg.T != model.EventConversationUpdate {
			t.Fatalf("expected CONVERSATION_UPDATE, got %s", msg.T)
		}
		var payload map[string]any
		if err := json.Unmarshal(msg.D, &payload); err != nil {
			t.Fatalf("unmarshal payload: %v", err)
		}
		if payload["title"] != "OC 起的新名" {
			t.Fatalf("expected title=OC 起的新名, got %v", payload["title"])
		}
	case <-time.After(200 * time.Millisecond):
		t.Fatal("user 端应收到 CONVERSATION_UPDATE")
	}

	// agent 端必须收不到(物理断回环)
	select {
	case data := <-agentClient.Send:
		t.Fatalf("agent 端不应收到自己触发的广播,但收到: %s", string(data))
	case <-time.After(50 * time.Millisecond):
		// 预期:无消息
	}
}

// === UpdateSessionMetaAsAgent 测试 ===

// TestUpdateSessionMetaAsAgent_CwdAndGitBranch 验证 agent 视角更新 session_meta 时,
// git_branch 透传字段被正确写入 JSONB;cwd 已升级到 conversations.directory 一级列,
// 即便 plugin 仍传 cwd,server 也彻底剔除不写入 session_meta。
func TestUpdateSessionMetaAsAgent_CwdAndGitBranch(t *testing.T) {
	f := seedUserAgentConv(t, "usmcwd")

	h := newConvHandler(f)
	r := gin.New()
	r.PATCH("/api/agents/me/conversations/:id/session-meta", func(c *gin.Context) {
		c.Set("userID", f.agent.ID)
		c.Set("role", "agent")
		h.UpdateSessionMetaAsAgent(c)
	})

	body := strings.NewReader(`{"mode":"build","modelId":"glm-5.2","providerId":"zhipuai","cwd":"/home/u/proj","gitBranch":"main"}`)
	req := httptest.NewRequest("PATCH", "/api/agents/me/conversations/"+f.convID+"/session-meta", body)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	// 读回 session_meta 验证:cwd 应被剔除,git_branch 应透传
	conv, err := f.convRepo.GetByID(t.Context(), f.convID)
	if err != nil || conv == nil {
		t.Fatalf("GetByID: %v %v", conv, err)
	}
	if !conv.SessionMeta.Valid {
		t.Fatalf("session_meta 应为非 NULL,实际 Valid=false")
	}
	var meta map[string]any
	if err := json.Unmarshal(conv.SessionMeta.RawMessage, &meta); err != nil {
		t.Fatalf("unmarshal session_meta: %v", err)
	}
	// 关键断言:cwd 字段已升级为一级列,session_meta 中不应出现
	if _, exists := meta["cwd"]; exists {
		t.Errorf("cwd 应被剔除出 session_meta(已升级到 conversations.directory),实际存在: %v", meta["cwd"])
	}
	if meta["git_branch"] != "main" {
		t.Errorf("git_branch = %v, want main", meta["git_branch"])
	}
	// 兼顾回归:既有字段仍正确透传
	if meta["mode"] != "build" {
		t.Errorf("mode = %v, want build", meta["mode"])
	}
	if meta["model_id"] != "glm-5.2" {
		t.Errorf("model_id = %v, want glm-5.2", meta["model_id"])
	}
}

// TestUpdateSessionMetaAsAgent_BroadcastsOnlyToUser 验证 agent 视角写完 session_meta 后,
// server 广播 SESSION_META_UPDATE 给本会话 user 端(实时刷新 SessionMetaStrip/EnvMetaStrip),
// 不发 agent 端(断回环 plugin→OC,与 UpdateTitleAsAgent 同口径)。
func TestUpdateSessionMetaAsAgent_BroadcastsOnlyToUser(t *testing.T) {
	f := seedUserAgentConv(t, "usmabou")

	realHub := hub.NewHub(nil, repository.NewAgentRepo(f.db), repository.NewParticipantRepo(f.db), nil)
	userClient := hub.NewClient(t.Context(), f.user.ID, "user", nil)
	agentClient := hub.NewClient(t.Context(), f.agent.ID, "agent", nil)
	realHub.RegisterClient(userClient)
	realHub.RegisterClient(agentClient)

	h := NewConversationHandler(
		f.db, f.convRepo, f.pRepo, nil, f.mRepo, f.dRepo,
		repository.NewAgentRepo(f.db), repository.NewUserRepo(f.db), realHub, nil, repository.NewAgentTypeRepo(f.db),
	)
	r := gin.New()
	r.PATCH("/api/agents/me/conversations/:id/session-meta", func(c *gin.Context) {
		c.Set("userID", f.agent.ID)
		c.Set("role", "agent")
		h.UpdateSessionMetaAsAgent(c)
	})

	body := strings.NewReader(`{"mode":"build","modelId":"glm-5.2","providerId":"zhipuai","cwd":"/home/u/proj","gitBranch":"main"}`)
	req := httptest.NewRequest("PATCH", "/api/agents/me/conversations/"+f.convID+"/session-meta", body)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	// user 端收到广播
	select {
	case data := <-userClient.Send:
		var msg model.WSMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			t.Fatalf("unmarshal: %v", err)
		}
		if msg.T != model.EventSessionMetaUpdate {
			t.Fatalf("expected SESSION_META_UPDATE, got %s", msg.T)
		}
		var payload map[string]any
		if err := json.Unmarshal(msg.D, &payload); err != nil {
			t.Fatalf("unmarshal payload: %v", err)
		}
		if payload["conv_id"] != f.convID {
			t.Fatalf("expected conv_id=%s, got %v", f.convID, payload["conv_id"])
		}
		metaField, ok := payload["session_meta"].(map[string]any)
		if !ok {
			t.Fatalf("session_meta 应为 map,实际 %T", payload["session_meta"])
		}
		if metaField["git_branch"] != "main" {
			t.Errorf("git_branch = %v, want main", metaField["git_branch"])
		}
		// cwd 已升级到 conversations.directory 一级列,session_meta 不应含 cwd
		if _, exists := metaField["cwd"]; exists {
			t.Errorf("cwd 应被剔除出 session_meta(已升级到 conversations.directory),实际存在: %v", metaField["cwd"])
		}
	case <-time.After(200 * time.Millisecond):
		t.Fatal("user 端应收到 SESSION_META_UPDATE")
	}

	// agent 端必须收不到(物理断回环)
	select {
	case data := <-agentClient.Send:
		t.Fatalf("agent 端不应收到自己触发的广播,但收到: %s", string(data))
	case <-time.After(50 * time.Millisecond):
		// 预期:无消息
	}
}

// TestUpdateSessionMetaAsAgent_TokensFields 验证 agent 视角 PATCH 时,
// 新增的 tokensTotal / contextUsed / contextLimit 字段透传到 session_meta JSONB。
func TestUpdateSessionMetaAsAgent_TokensFields(t *testing.T) {
	f := seedUserAgentConv(t, "usmtokens")

	h := newConvHandler(f)
	r := gin.New()
	r.PATCH("/api/agents/me/conversations/:id/session-meta", func(c *gin.Context) {
		c.Set("userID", f.agent.ID)
		c.Set("role", "agent")
		h.UpdateSessionMetaAsAgent(c)
	})

	body := strings.NewReader(`{"mode":"build","modelId":"glm-5.2","providerId":"zhipuai","cwd":"/p","gitBranch":"main","tokensTotal":1200000,"contextUsed":30000,"contextLimit":128000}`)
	req := httptest.NewRequest("PATCH", "/api/agents/me/conversations/"+f.convID+"/session-meta", body)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", w.Code, w.Body.String())
	}

	conv, err := f.convRepo.GetByID(t.Context(), f.convID)
	if err != nil || conv == nil {
		t.Fatalf("GetByID: %v %v", conv, err)
	}
	// session_meta 是混合 schema(既有 string 字段,也有 int64 token 字段),
	// 用 map[string]any 解码后按 float64 断言(JSON number → float64)。
	var meta map[string]any
	if err := json.Unmarshal(conv.SessionMeta.RawMessage, &meta); err != nil {
		t.Fatalf("unmarshal session_meta: %v", err)
	}
	if v, ok := meta["tokens_total"].(float64); !ok || v != 1200000 {
		t.Errorf("tokens_total = %v, want 1200000", meta["tokens_total"])
	}
	if v, ok := meta["context_used"].(float64); !ok || v != 30000 {
		t.Errorf("context_used = %v, want 30000", meta["context_used"])
	}
	if v, ok := meta["context_limit"].(float64); !ok || v != 128000 {
		t.Errorf("context_limit = %v, want 128000", meta["context_limit"])
	}
}
