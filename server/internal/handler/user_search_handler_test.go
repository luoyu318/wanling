package handler

import (
	"database/sql"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// seedUserSearchFixture 建若干 user 用于搜索测试。
type seedUserSearchFixture struct {
	db       *sql.DB
	userRepo *repository.UserRepo
	alice    *model.User
	bob      *model.User
	carol    *model.User
}

func seedUserSearch(t *testing.T) *seedUserSearchFixture {
	t.Helper()
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)

	alice, err := urepo.Create(shortName(t, "alice"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create alice: %v", err)
	}
	bob, err := urepo.Create(shortName(t, "bob"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create bob: %v", err)
	}
	carol, err := urepo.Create(shortName(t, "carol"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create carol: %v", err)
	}
	return &seedUserSearchFixture{
		db:       db,
		userRepo: urepo,
		alice:    alice,
		bob:      bob,
		carol:    carol,
	}
}

func newUserSearchHandler(f *seedUserSearchFixture) *UserSearchHandler {
	return NewUserSearchHandler(f.userRepo)
}

// TestUserSearchHandler_Search_PrefixMatch 验证前缀匹配返回候选。
func TestUserSearchHandler_Search_PrefixMatch(t *testing.T) {
	f := seedUserSearch(t)
	h := newUserSearchHandler(f)

	r := gin.New()
	r.GET("/api/users/search", func(c *gin.Context) {
		c.Set("userID", f.alice.ID)
		h.Search(c)
	})

	req := httptest.NewRequest("GET", "/api/users/search?username=al", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	var resp struct {
		Users []map[string]interface{} `json:"users"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if len(resp.Users) != 1 {
		t.Fatalf("搜索结果数 = %d, want 1", len(resp.Users))
	}
	if resp.Users[0]["username"] != f.alice.Username {
		t.Errorf("username = %v, want %s", resp.Users[0]["username"], f.alice.Username)
	}
}

// TestUserSearchHandler_Search_ResponseHasNoUserID 验证响应不含 user_id(防枚举)。
func TestUserSearchHandler_Search_ResponseHasNoUserID(t *testing.T) {
	f := seedUserSearch(t)
	h := newUserSearchHandler(f)

	r := gin.New()
	r.GET("/api/users/search", func(c *gin.Context) {
		c.Set("userID", f.alice.ID)
		h.Search(c)
	})

	req := httptest.NewRequest("GET", "/api/users/search?username=a", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	// 原始 body 校验不含 "id" 字段(防泄漏 user_id)
	bodyStr := w.Body.String()
	// 反序列化后逐条校验
	var resp struct {
		Users []map[string]interface{} `json:"users"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if len(resp.Users) == 0 {
		t.Fatal("无搜索结果")
	}
	for _, u := range resp.Users {
		if _, hasID := u["id"]; hasID {
			t.Errorf("搜索结果不应含 id 字段(防泄漏), 实际: %v. body: %s", u, bodyStr)
		}
		if _, hasUserID := u["user_id"]; hasUserID {
			t.Errorf("搜索结果不应含 user_id 字段(防泄漏), 实际: %v", u)
		}
	}
}

// TestUserSearchHandler_Search_EmptyUsername_400 验证空 username 返 400。
func TestUserSearchHandler_Search_EmptyUsername_400(t *testing.T) {
	f := seedUserSearch(t)
	h := newUserSearchHandler(f)

	r := gin.New()
	r.GET("/api/users/search", func(c *gin.Context) {
		c.Set("userID", f.alice.ID)
		h.Search(c)
	})

	req := httptest.NewRequest("GET", "/api/users/search", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("空 username 状态码: %d, want 400", w.Code)
	}
}

// TestUserSearchHandler_Search_NoMatchReturnsEmpty 验证无匹配返回空列表(不报错)。
func TestUserSearchHandler_Search_NoMatchReturnsEmpty(t *testing.T) {
	f := seedUserSearch(t)
	h := newUserSearchHandler(f)

	r := gin.New()
	r.GET("/api/users/search", func(c *gin.Context) {
		c.Set("userID", f.alice.ID)
		h.Search(c)
	})

	req := httptest.NewRequest("GET", "/api/users/search?username=zzz_nomatch", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d, want 200", w.Code)
	}
	var resp struct {
		Users []map[string]interface{} `json:"users"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if len(resp.Users) != 0 {
		t.Errorf("无匹配结果数 = %d, want 0", len(resp.Users))
	}
}
