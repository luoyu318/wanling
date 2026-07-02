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
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// shortName 复用同包 user_handler_test.go 里的定义，本文件不再重复声明。

// seedConvFixture 是 handler 测试常用 seed:user + agent + dm_user_agent 会话。
// 返回的 conv 已存在 user/agent 两个 participant。
type seedConvFixture struct {
	db      *sql.DB
	user    *model.User
	agent   *model.Agent
	conv    *model.Conversation
	convID  string
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

	user, err := urepo.Create(shortName(t, usernamePrefix), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}
	agent, err := arepo.Create(user.ID, shortName(t, "ag"), "secret-key")
	if err != nil {
		t.Fatalf("Create agent 失败: %v", err)
	}
	conv, err := crepo.FindOrCreateDM("dm_user_agent", repository.DMMembers{
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

	m, err := f.mRepo.CreateTx(tx, f.convID, "agent", f.agent.ID, json.RawMessage(`{"msg_type":"text","data":{"text":"hi"}}`))
	if err != nil {
		t.Fatalf("CreateTx msg: %v", err)
		return ""
	}
	// delivery 给 user
	parts, err := f.pRepo.ListByConversationTx(tx, f.convID)
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
	if err := f.dRepo.CreateBatchTx(tx, m.ID, recipients); err != nil {
		t.Fatalf("CreateBatchTx: %v", err)
		return ""
	}
	if err := f.pRepo.IncrUnreadTx(tx, f.convID, f.agent.ID, "agent"); err != nil {
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

// newConvHandler 构造一个完整依赖的 ConversationHandler(hub 可空,本测试不需要广播)。
func newConvHandler(f *seedConvFixture) *ConversationHandler {
	urepo := repository.NewUserRepo(f.db)
	arepo := repository.NewAgentRepo(f.db)
	frepo := repository.NewFriendshipRepo(f.db)
	return NewConversationHandler(
		f.db, f.convRepo, f.pRepo, frepo,
		f.mRepo, arepo, urepo, nil, // hub=nil,本测试不验证 WS 广播
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
	if _, err := f.mRepo.Create(f.convID, "user", f.user.ID, content); err != nil {
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

// TestConversationHandler_List_ExcludesNoMessageConversations 验证 IM 列表过滤:
//   - 没有任何消息的会话(last_message_content IS NULL)不应进入列表;
//   - 空结果应返回 [] 而非 null(避免 APP 端反序列化成 null 后报错)。
func TestConversationHandler_List_ExcludesNoMessageConversations(t *testing.T) {
	f := seedUserAgentConv(t, "excl")
	// 会话已建但无消息,不应进列表

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
	if body != "[]" {
		t.Errorf("无消息会话不应进列表,期望 [] 实际: %s", body)
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

	user, err := urepo.Create(shortName(t, "cna"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user: %v", err)
	}
	agent, err := arepo.Create(user.ID, shortName(t, "ag"), "secret-key")
	if err != nil {
		t.Fatalf("Create agent: %v", err)
	}

	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, arepo, urepo, nil)
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

	user, _ := urepo.Create(shortName(t, "duf1"), "$2a$10$hash")
	other, _ := urepo.Create(shortName(t, "duf2"), "$2a$10$hash")
	// 不建好友关系

	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, arepo, urepo, nil)
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

	if w.Code != http.StatusForbidden {
		t.Errorf("非好友应返 403, 实际: %d body: %s", w.Code, w.Body.String())
	}
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

	user, _ := urepo.Create(shortName(t, "dufs1"), "$2a$10$hash")
	other, _ := urepo.Create(shortName(t, "dufs2"), "$2a$10$hash")

	// 建好友关系:发请求 + accept
	fr, err := frepo.CreateRequest(user.ID, other.ID)
	if err != nil {
		t.Fatalf("CreateRequest: %v", err)
	}
	if err := frepo.Accept(fr.ID, other.ID); err != nil {
		t.Fatalf("Accept: %v", err)
	}

	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, arepo, urepo, nil)
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

	creator, _ := urepo.Create(shortName(t, "gcr"), "$2a$10$hash")
	m1, _ := urepo.Create(shortName(t, "gm1"), "$2a$10$hash")
	m2, _ := urepo.Create(shortName(t, "gm2"), "$2a$10$hash")

	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, arepo, urepo, nil)
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

// TestConversationHandler_Create_InvalidType 验证未知 type 返 400。
func TestConversationHandler_Create_InvalidType(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	mrepo := repository.NewMessageRepo(db)
	prepo := repository.NewParticipantRepo(db)
	frepo := repository.NewFriendshipRepo(db)

	user, _ := urepo.Create(shortName(t, "cit"), "$2a$10$hash")

	h := NewConversationHandler(db, crepo, prepo, frepo, mrepo, arepo, urepo, nil)
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

	if w.Code != http.StatusBadRequest {
		t.Errorf("未知 type 应 400, 实际 %d", w.Code)
	}
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
	other, _ := repository.NewUserRepo(f.db).Create(shortName(t, "other"), "$2a$10$hash")

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id", func(c *gin.Context) {
		c.Set("userID", other.ID)
		h.Get(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations/"+f.convID, nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("非 participant 应 403, 实际 %d", w.Code)
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

	if w.Code != http.StatusNotFound {
		t.Fatalf("expected 404 for nonexistent user, got %d: %s", w.Code, w.Body.String())
	}
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
		var resp map[string]interface{}
		_ = json.Unmarshal(w.Body.Bytes(), &resp)
		id, _ := resp["id"].(string)
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
		m, err := f.mRepo.Create(f.convID, "user", f.user.ID, content)
		if err != nil {
			t.Fatalf("Create m%d: %v", i, err)
		}
		ids = append(ids, m.ID)
		time.Sleep(2 * time.Millisecond)
	}

	m2, _ := f.mRepo.Get(ids[1])

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
	var got []map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("反序列化失败: %v body: %s", err, w.Body.String())
	}
	if len(got) != 1 {
		t.Fatalf("期望 1 条,实际 %d", len(got))
	}
	if got[0]["id"] != ids[0] {
		t.Errorf("期望 m1(%s),实际 %v", ids[0], got[0]["id"])
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

	if w.Code != http.StatusBadRequest {
		t.Errorf("before 格式错误应 400,实际 %d", w.Code)
	}
}

// TestConversationHandler_Messages_NonParticipant_403 验证越权访问返 403。
func TestConversationHandler_Messages_NonParticipant_403(t *testing.T) {
	f := seedUserAgentConv(t, "mnp")

	other, _ := repository.NewUserRepo(f.db).Create(shortName(t, "other"), "$2a$10$hash")

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id/messages", func(c *gin.Context) {
		c.Set("userID", other.ID)
		h.Messages(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations/"+f.convID+"/messages", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("非 participant 应 403,实际 %d", w.Code)
	}
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
		m, err := f.mRepo.Create(f.convID, "user", f.user.ID, content)
		if err != nil {
			t.Fatalf("Create m%d: %v", i, err)
		}
		ids = append(ids, m.ID)
		time.Sleep(2 * time.Millisecond)
	}

	m2, _ := f.mRepo.Get(ids[1])

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
	var got []map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("反序列化失败: %v body: %s", err, w.Body.String())
	}
	if len(got) != 3 {
		t.Fatalf("期望 3 条(m2~m4),实际 %d", len(got))
	}
	if got[0]["id"] != ids[1] {
		t.Errorf("ASC 第一条期望 m2(%s),实际 %v", ids[1], got[0]["id"])
	}
	if got[2]["id"] != ids[3] {
		t.Errorf("ASC 最后一条期望 m4(%s),实际 %v", ids[3], got[2]["id"])
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

	if w.Code != http.StatusBadRequest {
		t.Errorf("after 格式错误应 400,实际 %d", w.Code)
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

	other, _ := repository.NewUserRepo(f.db).Create(shortName(t, "other"), "$2a$10$hash")

	h := newConvHandler(f)
	r := gin.New()
	r.POST("/api/conversations/:id/read", func(c *gin.Context) {
		c.Set("userID", other.ID)
		h.MarkRead(c)
	})

	req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/read", f.convID), nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("非 participant 应 403,实际 %d", w.Code)
	}
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
	var resp struct {
		OK          bool `json:"ok"`
		UnreadCount int  `json:"unread_count"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("反序列化响应失败: %v", err)
	}
	if !resp.OK {
		t.Errorf("ok 应为 true")
	}
	if resp.UnreadCount != 1 {
		t.Errorf("响应 unread_count = %d, want 1", resp.UnreadCount)
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
		if w.Code != http.StatusBadRequest {
			t.Errorf("空 body 应 400,实际 %d", w.Code)
		}
	})

	t.Run("缺 message_ids 字段", func(t *testing.T) {
		req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/messages/read", f.convID),
			bytes.NewReader([]byte(`{"other":"x"}`)))
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		if w.Code != http.StatusBadRequest {
			t.Errorf("缺 message_ids 应 400,实际 %d", w.Code)
		}
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
		if w.Code != http.StatusBadRequest {
			t.Errorf("超过 100 条应 400,实际 %d", w.Code)
		}
	})
}

// TestConversationHandler_MarkMessagesRead_NonParticipant_403 越权返 403。
func TestConversationHandler_MarkMessagesRead_NonParticipant_403(t *testing.T) {
	f := seedUserAgentConv(t, "mmrnp")

	other, _ := repository.NewUserRepo(f.db).Create(shortName(t, "other"), "$2a$10$hash")

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

	if w.Code != http.StatusForbidden {
		t.Errorf("非 participant 应 403,实际 %d body: %s", w.Code, w.Body.String())
	}
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

	other, _ := repository.NewUserRepo(f.db).Create(shortName(t, "other"), "$2a$10$hash")

	h := newConvHandler(f)
	r := gin.New()
	r.POST("/api/conversations/:id/pin", func(c *gin.Context) {
		c.Set("userID", other.ID)
		h.Pin(c)
	})

	req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/pin", f.convID), nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("非 participant Pin 应 403,实际 %d", w.Code)
	}
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

	other, _ := repository.NewUserRepo(f.db).Create(shortName(t, "other"), "$2a$10$hash")

	h := newConvHandler(f)
	r := gin.New()
	r.GET("/api/conversations/:id/unread", func(c *gin.Context) {
		c.Set("userID", other.ID)
		h.UnreadInfo(c)
	})

	req := httptest.NewRequest("GET", "/api/conversations/"+f.convID+"/unread", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("非 participant 应 403,实际 %d", w.Code)
	}
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
	m, err := f.mRepo.Create(f.convID, "user", f.user.ID, content)
	if err != nil {
		t.Fatalf("Create msg: %v", err)
	}

	// 撤回该消息
	if err := f.mRepo.SoftDelete(m.ID); err != nil {
		t.Fatalf("SoftDelete: %v", err)
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
