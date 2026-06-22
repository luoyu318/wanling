package handler

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/repository"
	"golang.org/x/crypto/bcrypt"
)

// shortName 把测试函数名压成不超过 32 字符的稳定短串，避免超出 users.username varchar(64) 限制。
// 与 repository 包的 uniqueShortName 同语义，因为跨包不可复用私有 helper，handler 测试包内自备一份。
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

// TestUserHandler_GetMe_ReturnsCurrentUserWithoutPasswordHash 验证核心场景：
//   - 200 状态码；
//   - 响应包含 username；
//   - 响应不泄露 password_hash（依靠 User.PasswordHash 的 json:"-" tag）。
func TestUserHandler_GetMe_ReturnsCurrentUserWithoutPasswordHash(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	user, err := urepo.Create(shortName(t, "meu_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user 失败: %v", err)
	}

	h := NewUserHandler(urepo)
	r := gin.New()
	// 直接复用真实中间件语义：把 userID 注入上下文，模拟 AuthMiddleware 已通过的下游。
	r.GET("/api/users/me", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.GetMe(c)
	})

	req := httptest.NewRequest("GET", "/api/users/me", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	body := w.Body.String()
	// shortName 输出形如 "meu_userhandler.getme_return..."，断言前缀足够
	if !strings.Contains(body, `"username":"meu_`) {
		t.Errorf("响应缺少 username: %s", body)
	}
	if strings.Contains(body, "password_hash") {
		t.Errorf("响应泄露 password_hash: %s", body)
	}
}

// TestUserHandler_GetMe_Returns404IfUserMissing 验证：上下文里 userID 指向不存在的用户时返回 404。
// 这条路径在 token 未过期但用户被删除的场景下会触发。
func TestUserHandler_GetMe_Returns404IfUserMissing(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	h := NewUserHandler(urepo)

	r := gin.New()
	r.GET("/api/users/me", func(c *gin.Context) {
		// 全 0 UUID：GetByID 找不到 → 返回 (nil, nil) → handler 输出 404
		c.Set("userID", "00000000-0000-0000-0000-000000000000")
		h.GetMe(c)
	})

	req := httptest.NewRequest("GET", "/api/users/me", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("期望 404，实际: %d", w.Code)
	}
}

// TestUserHandler_GetMe_Returns500OnDBError 验证 DB 错误时返回 500。
// 用关闭的 *sql.DB 触发查询失败，确保 500 分支不会因 nil err 被误判成 404。
func TestUserHandler_GetMe_Returns500OnDBError(t *testing.T) {
	db := repository.SetupTestDB(t)
	// 关闭底层连接，后续 QueryRow 必然失败
	if err := db.Close(); err != nil {
		t.Fatalf("关闭 DB 失败: %v", err)
	}
	urepo := repository.NewUserRepo(db)
	h := NewUserHandler(urepo)

	r := gin.New()
	r.GET("/api/users/me", func(c *gin.Context) {
		c.Set("userID", "00000000-0000-0000-0000-000000000000")
		h.GetMe(c)
	})

	req := httptest.NewRequest("GET", "/api/users/me", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusInternalServerError {
		t.Errorf("期望 500，实际: %d body: %s", w.Code, w.Body.String())
	}
}

// TestUserHandler_ChangePassword_UpdatesHashAndReturns200 验证：
//   - 200 响应；
//   - 数据库里 password_hash 已变（用 bcrypt 比对新旧密码验证）。
func TestUserHandler_ChangePassword_UpdatesHashAndReturns200(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	oldHash, _ := bcrypt.GenerateFromPassword([]byte("oldpw"), bcrypt.DefaultCost)
	user, err := urepo.Create(shortName(t, "cpu_"), string(oldHash))
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	h := NewUserHandler(urepo)
	r := gin.New()
	r.PUT("/api/users/me/password", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.ChangePassword(c)
	})

	body := `{"new_password":"newpw123"}`
	req := httptest.NewRequest("PUT", "/api/users/me/password", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}

	reloaded, _ := urepo.GetByID(user.ID)
	if bcrypt.CompareHashAndPassword([]byte(reloaded.PasswordHash), []byte("newpw123")) != nil {
		t.Errorf("新密码未生效")
	}
}

// TestUserHandler_ChangePassword_Returns400OnShortPassword 验证密码 <6 位返回 400。
func TestUserHandler_ChangePassword_Returns400OnShortPassword(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	oldHash, _ := bcrypt.GenerateFromPassword([]byte("oldpw"), bcrypt.DefaultCost)
	user, _ := urepo.Create(shortName(t, "cps_"), string(oldHash))

	h := NewUserHandler(urepo)
	r := gin.New()
	r.PUT("/api/users/me/password", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.ChangePassword(c)
	})

	req := httptest.NewRequest("PUT", "/api/users/me/password",
		strings.NewReader(`{"new_password":"123"}`)) // 3 位
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("期望 400，实际: %d body: %s", w.Code, w.Body.String())
	}
}

// TestUserHandler_ChangePassword_Returns404OnMissingUser 验证 token 指向的用户
// 不存在时返回 404（token 未过期但用户被删的场景）。
func TestUserHandler_ChangePassword_Returns404OnMissingUser(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	h := NewUserHandler(urepo)

	r := gin.New()
	r.PUT("/api/users/me/password", func(c *gin.Context) {
		c.Set("userID", "00000000-0000-0000-0000-000000000000")
		h.ChangePassword(c)
	})

	req := httptest.NewRequest("PUT", "/api/users/me/password",
		strings.NewReader(`{"new_password":"newpw123"}`))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("期望 404，实际: %d body: %s", w.Code, w.Body.String())
	}
}

// TestUserHandler_UpdateMe_UpdatesNicknameAndReturnsUser 验证 PUT /api/users/me
// 能更新 nickname/bio 并返回完整 User。
func TestUserHandler_UpdateMe_UpdatesNicknameAndReturnsUser(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	user, err := urepo.Create(shortName(t, "upd_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	h := NewUserHandler(urepo)
	r := gin.New()
	r.PUT("/api/users/me", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.UpdateMe(c)
	})

	body := `{"nickname":"我的昵称","bio":"我的简介"}`
	req := httptest.NewRequest("PUT", "/api/users/me", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("状态码: %d body: %s", w.Code, w.Body.String())
	}
	resp := w.Body.String()
	if !strings.Contains(resp, `"nickname":"我的昵称"`) {
		t.Errorf("响应缺少更新后的 nickname: %s", resp)
	}
	if !strings.Contains(resp, `"bio":"我的简介"`) {
		t.Errorf("响应缺少更新后的 bio: %s", resp)
	}
}

// TestUserHandler_UpdateMe_Returns400OnTooLongNickname 验证 nickname 超 64 字符返 400。
func TestUserHandler_UpdateMe_Returns400OnTooLongNickname(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	user, _ := urepo.Create(shortName(t, "upl_"), "$2a$10$hash")

	h := NewUserHandler(urepo)
	r := gin.New()
	r.PUT("/api/users/me", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.UpdateMe(c)
	})

	longName := strings.Repeat("a", 65)
	body := `{"nickname":"` + longName + `"}`
	req := httptest.NewRequest("PUT", "/api/users/me", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("期望 400，实际: %d body: %s", w.Code, w.Body.String())
	}
}
