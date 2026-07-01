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

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/repository"
)

// seedGroupFixture 建一个 group_user 群(creator=owner + 2 个 user member),返回关键 id。
type seedGroupFixture struct {
	db       *sql.DB
	creator  string
	m1       string
	m2       string
	convID   string
	convRepo *repository.ConversationRepo
	pRepo    *repository.ParticipantRepo
}

func seedGroup(t *testing.T) *seedGroupFixture {
	t.Helper()
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	crepo := repository.NewConversationRepo(db)
	prepo := repository.NewParticipantRepo(db)

	creator, err := urepo.Create(shortName(t, "gcr"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create creator: %v", err)
	}
	m1, err := urepo.Create(shortName(t, "gm1"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create m1: %v", err)
	}
	m2, err := urepo.Create(shortName(t, "gm2"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create m2: %v", err)
	}

	tx, err := db.Begin()
	if err != nil {
		t.Fatalf("Begin: %v", err)
	}
	conv, err := crepo.CreateTx(tx, "group_user", "测试群", "")
	if err != nil {
		t.Fatalf("CreateTx: %v", err)
	}
	if err := prepo.AddParticipantsTx(tx, conv.ID, []repository.ParticipantInput{
		{MemberID: creator.ID, MemberType: "user", Role: "owner"},
		{MemberID: m1.ID, MemberType: "user", Role: "member"},
		{MemberID: m2.ID, MemberType: "user", Role: "member"},
	}); err != nil {
		t.Fatalf("AddParticipantsTx: %v", err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatalf("Commit: %v", err)
	}

	return &seedGroupFixture{
		db:       db,
		creator:  creator.ID,
		m1:       m1.ID,
		m2:       m2.ID,
		convID:   conv.ID,
		convRepo: crepo,
		pRepo:    prepo,
	}
}

// newGroupHandler 构造 GroupHandler(hub=nil,本测试不验证 WS 广播)。
func newGroupHandler(f *seedGroupFixture) *GroupHandler {
	return NewGroupHandler(f.db, f.convRepo, f.pRepo, nil)
}

// === InviteMember 测试 ===

// TestGroupHandler_InviteMember_HappyPath 验证 participant 邀请新成员成功。
func TestGroupHandler_InviteMember_HappyPath(t *testing.T) {
	f := seedGroup(t)
	// 另一个 user 作为被邀请人
	newUser, err := repository.NewUserRepo(f.db).Create(shortName(t, "invitee"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create invitee: %v", err)
	}

	h := newGroupHandler(f)
	r := gin.New()
	r.POST("/api/conversations/:id/participants", func(c *gin.Context) {
		c.Set("userID", f.creator)
		h.InviteMember(c)
	})

	body, _ := json.Marshal(map[string]string{"member_id": newUser.ID, "member_type": "user"})
	req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/participants", f.convID), bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	// 校验新成员已入群
	var role string
	err = f.db.QueryRow(`SELECT role FROM conversation_participants WHERE conv_id=$1 AND member_id=$2 AND member_type='user'`,
		f.convID, newUser.ID).Scan(&role)
	if err != nil {
		t.Errorf("新成员查询失败: %v", err)
	}
	if role != "member" {
		t.Errorf("新成员 role = %s, want member", role)
	}
}

// TestGroupHandler_InviteMember_NonParticipant_403 验证非 participant 邀请返 403。
func TestGroupHandler_InviteMember_NonParticipant_403(t *testing.T) {
	f := seedGroup(t)
	// 一个完全在群外的 user
	outsider, err := repository.NewUserRepo(f.db).Create(shortName(t, "outsider"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create outsider: %v", err)
	}
	invitee, err := repository.NewUserRepo(f.db).Create(shortName(t, "invitee2"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create invitee: %v", err)
	}

	h := newGroupHandler(f)
	r := gin.New()
	r.POST("/api/conversations/:id/participants", func(c *gin.Context) {
		c.Set("userID", outsider.ID) // 外人发起邀请
		h.InviteMember(c)
	})

	body, _ := json.Marshal(map[string]string{"member_id": invitee.ID, "member_type": "user"})
	req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/participants", f.convID), bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("非 participant 邀请应 403, 实际 %d body: %s", w.Code, w.Body.String())
	}
}

// TestGroupHandler_InviteMember_BadBody 验证 body 校验(member_type 受 oneof 约束)。
func TestGroupHandler_InviteMember_BadBody(t *testing.T) {
	f := seedGroup(t)

	h := newGroupHandler(f)
	r := gin.New()
	r.POST("/api/conversations/:id/participants", func(c *gin.Context) {
		c.Set("userID", f.creator)
		h.InviteMember(c)
	})

	// member_type=foo 不在 oneof(user agent) 中
	body := `{"member_id":"00000000-0000-0000-0000-000000000000","member_type":"foo"}`
	req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/participants", f.convID), strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("非法 member_type 应 400, 实际 %d", w.Code)
	}
}

// === KickMember 测试 ===

// TestGroupHandler_KickMember_OwnerCanKickMember 验证 owner 能踢 member。
func TestGroupHandler_KickMember_OwnerCanKickMember(t *testing.T) {
	f := seedGroup(t)

	h := newGroupHandler(f)
	r := gin.New()
	r.DELETE("/api/conversations/:id/participants/:member_id", func(c *gin.Context) {
		c.Set("userID", f.creator)
		h.KickMember(c)
	})

	req := httptest.NewRequest("DELETE", fmt.Sprintf("/api/conversations/%s/participants/%s", f.convID, f.m1), nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("owner 踢 member 应 200, 实际 %d body: %s", w.Code, w.Body.String())
	}
	// 校验 m1 已不在群
	var n int
	_ = f.db.QueryRow(`SELECT COUNT(*) FROM conversation_participants WHERE conv_id=$1 AND member_id=$2 AND member_type='user'`,
		f.convID, f.m1).Scan(&n)
	if n != 0 {
		t.Errorf("m1 应被移除, 实际仍有 %d 行", n)
	}
}

// TestGroupHandler_KickMember_MemberCannotKick 验证普通 member 不能踢人。
func TestGroupHandler_KickMember_MemberCannotKick(t *testing.T) {
	f := seedGroup(t)

	h := newGroupHandler(f)
	r := gin.New()
	r.DELETE("/api/conversations/:id/participants/:member_id", func(c *gin.Context) {
		c.Set("userID", f.m1) // m1 是普通 member,无权踢
		h.KickMember(c)
	})

	req := httptest.NewRequest("DELETE", fmt.Sprintf("/api/conversations/%s/participants/%s", f.convID, f.m2), nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("member 踢人应 403, 实际 %d", w.Code)
	}
}

// TestGroupHandler_KickMember_CannotKickOwner 验证不能踢 owner。
func TestGroupHandler_KickMember_CannotKickOwner(t *testing.T) {
	f := seedGroup(t)

	// 把 m1 升级为 admin(让 m1 有权 kick,但 kick owner 仍应失败)
	_, err := f.db.Exec(`UPDATE conversation_participants SET role='admin' WHERE conv_id=$1 AND member_id=$2 AND member_type='user'`,
		f.convID, f.m1)
	if err != nil {
		t.Fatalf("升级 admin: %v", err)
	}

	h := newGroupHandler(f)
	r := gin.New()
	r.DELETE("/api/conversations/:id/participants/:member_id", func(c *gin.Context) {
		c.Set("userID", f.m1) // admin 想踢 creator(owner)
		h.KickMember(c)
	})

	req := httptest.NewRequest("DELETE", fmt.Sprintf("/api/conversations/%s/participants/%s", f.convID, f.creator), nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("踢 owner 应 403, 实际 %d", w.Code)
	}
}

// TestGroupHandler_KickMember_TargetNotInConv 验证 target 不在群返 404。
func TestGroupHandler_KickMember_TargetNotInConv(t *testing.T) {
	f := seedGroup(t)
	outsider, _ := repository.NewUserRepo(f.db).Create(shortName(t, "out"), "$2a$10$hash")

	h := newGroupHandler(f)
	r := gin.New()
	r.DELETE("/api/conversations/:id/participants/:member_id", func(c *gin.Context) {
		c.Set("userID", f.creator)
		h.KickMember(c)
	})

	req := httptest.NewRequest("DELETE", fmt.Sprintf("/api/conversations/%s/participants/%s", f.convID, outsider.ID), nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("踢不存在成员应 404, 实际 %d", w.Code)
	}
}

// === Leave 测试 ===

// TestGroupHandler_Leave_MemberRemovesSelf 验证普通 member 退群只删自己 participant 行。
func TestGroupHandler_Leave_MemberRemovesSelf(t *testing.T) {
	f := seedGroup(t)

	h := newGroupHandler(f)
	r := gin.New()
	r.POST("/api/conversations/:id/leave", func(c *gin.Context) {
		c.Set("userID", f.m1)
		h.Leave(c)
	})

	req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/leave", f.convID), nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("退群应 200, 实际 %d body: %s", w.Code, w.Body.String())
	}
	// m1 已退群
	var n int
	_ = f.db.QueryRow(`SELECT COUNT(*) FROM conversation_participants WHERE conv_id=$1 AND member_id=$2 AND member_type='user'`,
		f.convID, f.m1).Scan(&n)
	if n != 0 {
		t.Errorf("m1 应已退群, 实际仍有 %d 行", n)
	}
	// 群本身还在(creator + m2)
	_ = f.db.QueryRow(`SELECT COUNT(*) FROM conversation_participants WHERE conv_id=$1`, f.convID).Scan(&n)
	if n != 2 {
		t.Errorf("退群后剩 2 participant, 实际 %d", n)
	}
}

// TestGroupHandler_Leave_OwnerDestroysConversation 验证 owner 退群 → 销群。
func TestGroupHandler_Leave_OwnerDestroysConversation(t *testing.T) {
	f := seedGroup(t)

	h := newGroupHandler(f)
	r := gin.New()
	r.POST("/api/conversations/:id/leave", func(c *gin.Context) {
		c.Set("userID", f.creator) // owner 退群
		h.Leave(c)
	})

	req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/leave", f.convID), nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("owner 退群应 200, 实际 %d body: %s", w.Code, w.Body.String())
	}
	// 群应被删除(conversations 表 + 级联 participants)
	var n int
	_ = f.db.QueryRow(`SELECT COUNT(*) FROM conversations WHERE id=$1`, f.convID).Scan(&n)
	if n != 0 {
		t.Errorf("owner 退群应销群, conversations 仍存在")
	}
	_ = f.db.QueryRow(`SELECT COUNT(*) FROM conversation_participants WHERE conv_id=$1`, f.convID).Scan(&n)
	if n != 0 {
		t.Errorf("owner 退群后 participants 应级联删, 实际剩 %d 行", n)
	}
}

// TestGroupHandler_Leave_NonParticipant_404 验证非 participant 退群返 404。
func TestGroupHandler_Leave_NonParticipant_404(t *testing.T) {
	f := seedGroup(t)
	outsider, _ := repository.NewUserRepo(f.db).Create(shortName(t, "out"), "$2a$10$hash")

	h := newGroupHandler(f)
	r := gin.New()
	r.POST("/api/conversations/:id/leave", func(c *gin.Context) {
		c.Set("userID", outsider.ID)
		h.Leave(c)
	})

	req := httptest.NewRequest("POST", fmt.Sprintf("/api/conversations/%s/leave", f.convID), nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("非 participant 退群应 404, 实际 %d", w.Code)
	}
}

// === Update 测试 ===

// TestGroupHandler_Update_OwnerCanUpdate 验证 owner 改群名 / 头像。
func TestGroupHandler_Update_OwnerCanUpdate(t *testing.T) {
	f := seedGroup(t)

	h := newGroupHandler(f)
	r := gin.New()
	r.PATCH("/api/conversations/:id", func(c *gin.Context) {
		c.Set("userID", f.creator)
		h.Update(c)
	})

	body := `{"title":"新群名","avatar_url":"http://x/new.png"}`
	req := httptest.NewRequest("PATCH", fmt.Sprintf("/api/conversations/%s", f.convID), strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("owner 改群应 200, 实际 %d body: %s", w.Code, w.Body.String())
	}
	// 校验 DB 已更新
	var title, avatar string
	_ = f.db.QueryRow(`SELECT title, avatar_url FROM conversations WHERE id=$1`, f.convID).Scan(&title, &avatar)
	if title != "新群名" {
		t.Errorf("title = %s, want '新群名'", title)
	}
	if avatar != "http://x/new.png" {
		t.Errorf("avatar_url = %s, want 'http://x/new.png'", avatar)
	}
}

// TestGroupHandler_Update_MemberCannotUpdate 验证普通 member 不能改群信息。
func TestGroupHandler_Update_MemberCannotUpdate(t *testing.T) {
	f := seedGroup(t)

	h := newGroupHandler(f)
	r := gin.New()
	r.PATCH("/api/conversations/:id", func(c *gin.Context) {
		c.Set("userID", f.m1)
		h.Update(c)
	})

	body := `{"title":"被篡改"}`
	req := httptest.NewRequest("PATCH", fmt.Sprintf("/api/conversations/%s", f.convID), strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("member 改群应 403, 实际 %d", w.Code)
	}
}

// TestGroupHandler_Update_PartialTitleOnly 验证只传 title 不动 avatar_url(COALESCE NULLIF 模式)。
func TestGroupHandler_Update_PartialTitleOnly(t *testing.T) {
	f := seedGroup(t)
	// 先把 avatar_url 设为非空,以便测试 PATCH 只改 title 时 avatar_url 不动
	_, err := f.db.Exec(`UPDATE conversations SET avatar_url='http://x/orig.png' WHERE id=$1`, f.convID)
	if err != nil {
		t.Fatalf("seed avatar_url: %v", err)
	}

	h := newGroupHandler(f)
	r := gin.New()
	r.PATCH("/api/conversations/:id", func(c *gin.Context) {
		c.Set("userID", f.creator)
		h.Update(c)
	})

	body := `{"title":"只改标题"}`
	req := httptest.NewRequest("PATCH", fmt.Sprintf("/api/conversations/%s", f.convID), strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("PATCH 应 200, 实际 %d body: %s", w.Code, w.Body.String())
	}
	var title, avatar string
	_ = f.db.QueryRow(`SELECT title, avatar_url FROM conversations WHERE id=$1`, f.convID).Scan(&title, &avatar)
	if title != "只改标题" {
		t.Errorf("title = %s, want '只改标题'", title)
	}
	if avatar != "http://x/orig.png" {
		t.Errorf("avatar_url 应保留原值, 实际 = %s", avatar)
	}
}
