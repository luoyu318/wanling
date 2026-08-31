package handler

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"

	"github.com/wanling/server/internal/auth"
)

// TestValidatePasswordStrength 仅测函数本身(handler 集成测试需 mock repo,跳过)。
// 本函数不校验长度(由 binding:"min=8,max=64" 兜底),只校验字符组成规则:
// 必须含字母 + 必须含数字 + 必须含特殊字符，且不在常见弱密码黑名单中。
func TestValidatePasswordStrength(t *testing.T) {
	cases := []struct {
		name    string
		input   string
		wantErr bool
	}{
		{"合法_字母数字特殊", "abc12345!", false},
		{"无特殊字符", "abc12345", true},
		{"全数字", "12345678", true},
		{"全字母", "abcdefgh", true},
		{"太短且无数字", "ab", true},
		{"常见弱密码", "p@ssw0rd", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			err := validatePasswordStrength(tc.input)
			if (err != nil) != tc.wantErr {
				t.Fatalf("input=%q err=%v wantErr=%v", tc.input, err, tc.wantErr)
			}
		})
	}
}

const (
	authTestSecret = "auth-test-secret"
	authAccessTTL  = 2 * time.Hour
	authRefreshTTL = 30 * 24 * time.Hour
)

// newAuthTestStore 起 miniredis + TokenStore，用于 auth handler 集成测试。
func newAuthTestStore(t *testing.T) *auth.TokenStore {
	t.Helper()
	mr := miniredis.RunT(t)
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	t.Cleanup(func() { rdb.Close() })
	return auth.NewTokenStore(rdb)
}

// newAuthHandlerWithStore 构造带 Redis store 的 AuthHandler。
// userRepo/agentRepo 传 nil：Refresh/Logout 路径不碰 DB（只读/写 Redis）。
func newAuthHandlerWithStore(t *testing.T) *AuthHandler {
	t.Helper()
	return NewAuthHandler(nil, nil, authTestSecret, newAuthTestStore(t), authAccessTTL, authRefreshTTL, nil)
}

// doRefreshRequest 构造 POST /api/auth/refresh 请求。
func doRefreshRequest(t *testing.T, h *AuthHandler, body string) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.POST("/api/auth/refresh", h.Refresh)

	req := httptest.NewRequest(http.MethodPost, "/api/auth/refresh", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

// TestRefresh_HappyPath 验证完整 rotation 流程：
//   - 用 CreateRefresh 预置一个有效 refresh token（ver=0）；
//   - POST /api/auth/refresh 携带该 token → 期望 200 + 返回新 token pair；
//   - 旧 refresh token 应被删除（GetRefresh 返 nil）。
func TestRefresh_HappyPath(t *testing.T) {
	store := newAuthTestStore(t)
	h := NewAuthHandler(nil, nil, authTestSecret, store, authAccessTTL, authRefreshTTL, nil)
	ctx := context.Background()

	const oldRefresh = "old-refresh-abc"
	if err := store.CreateRefresh(ctx, oldRefresh, "user-happy", "user", 0, authRefreshTTL); err != nil {
		t.Fatalf("CreateRefresh: %v", err)
	}

	body := `{"refresh_token":"` + oldRefresh + `"}`
	w := doRefreshRequest(t, h, body)

	data := AssertOk(t, w, http.StatusOK)
	newAccess, _ := data["token"].(string)
	newRefresh, _ := data["refresh_token"].(string)
	if newAccess == "" || newRefresh == "" {
		t.Fatalf("响应缺少 token/refresh_token: %v", data)
	}
	if newRefresh == oldRefresh {
		t.Fatal("refresh token 未 rotation：新旧相同")
	}

	// 旧 refresh token 必须已被删除
	oldData, err := store.GetRefresh(ctx, oldRefresh)
	if err != nil {
		t.Fatalf("GetRefresh(old): %v", err)
	}
	if oldData != nil {
		t.Fatalf("旧 refresh token 应已删除,仍存在: %+v", oldData)
	}

	// 新 refresh token 应可读
	newData, err := store.GetRefresh(ctx, newRefresh)
	if err != nil {
		t.Fatalf("GetRefresh(new): %v", err)
	}
	if newData == nil || newData.UserID != "user-happy" {
		t.Fatalf("新 refresh token 缺失或数据错误: %+v", newData)
	}

	// 新 access token 应能被 ParseToken 解析
	claims, err := auth.ParseToken(authTestSecret, newAccess)
	if err != nil {
		t.Fatalf("ParseToken(new access): %v", err)
	}
	if claims.Subject != "user-happy" {
		t.Fatalf("新 access token subject 错误: %s", claims.Subject)
	}
}

// TestRefresh_StoreNil_503 验证 Redis 不可用（store=nil）时 refresh 返回 503。
// refresh 体系强依赖 Redis（rotation + 黑名单），无 store 时直接拒绝。
func TestRefresh_StoreNil_503(t *testing.T) {
	h := NewAuthHandler(nil, nil, authTestSecret, nil, authAccessTTL, authRefreshTTL, nil)

	body := `{"refresh_token":"whatever"}`
	w := doRefreshRequest(t, h, body)

	AssertErr(t, w, http.StatusServiceUnavailable, "internal_error")
}

// TestRefresh_InvalidToken 验证不存在的 refresh token 返回 401。
func TestRefresh_InvalidToken(t *testing.T) {
	h := newAuthHandlerWithStore(t)

	body := `{"refresh_token":"nonexistent-token"}`
	w := doRefreshRequest(t, h, body)

	AssertErr(t, w, http.StatusUnauthorized, "invalid_refresh")
}

// TestRefresh_TokenVersionMismatch 验证改密后旧 refresh token（ver 不匹配）被拒绝。
// 场景：refresh token 绑定 ver=0，IncrTokenVersion 后 Redis 中 ver=1 → refresh 时版本不匹配 → 401。
func TestRefresh_TokenVersionMismatch(t *testing.T) {
	store := newAuthTestStore(t)
	h := NewAuthHandler(nil, nil, authTestSecret, store, authAccessTTL, authRefreshTTL, nil)
	ctx := context.Background()

	const oldRefresh = "ver-mismatch-refresh"
	if err := store.CreateRefresh(ctx, oldRefresh, "user-ver", "user", 0, authRefreshTTL); err != nil {
		t.Fatalf("CreateRefresh: %v", err)
	}
	if _, err := store.IncrTokenVersion(ctx, "user-ver"); err != nil {
		t.Fatalf("IncrTokenVersion: %v", err)
	}

	body := `{"refresh_token":"` + oldRefresh + `"}`
	w := doRefreshRequest(t, h, body)

	AssertErr(t, w, http.StatusUnauthorized, "invalid_refresh")
}

// TestRefresh_BadRequest 验证 body 缺 refresh_token 字段时返回 400。
func TestRefresh_BadRequest(t *testing.T) {
	h := newAuthHandlerWithStore(t)

	w := doRefreshRequest(t, h, `{}`)

	AssertErr(t, w, http.StatusBadRequest, "bad_request")
}

// --- Logout 测试 ---

// doLogoutRequest 构造 POST /api/auth/logout 请求。
// claims 注入模拟 AuthMiddleware 已通过：把 claims 写入 gin.Context。
func doLogoutRequest(t *testing.T, h *AuthHandler, store *auth.TokenStore, claims *auth.Claims, body string) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.POST("/api/auth/logout", func(c *gin.Context) {
		c.Set("claims", claims)
		c.Set("userID", claims.Subject)
		c.Set("role", claims.Role)
		h.Logout(c)
	})

	req := httptest.NewRequest(http.MethodPost, "/api/auth/logout", strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

// TestLogout_BlacklistAndDeleteRefresh 验证 logout 完整流程：
//   - access token 的 jti 被加入黑名单（剩余 TTL）；
//   - body 携带的 refresh token 被删除；
//   - 返回 200。
func TestLogout_BlacklistAndDeleteRefresh(t *testing.T) {
	store := newAuthTestStore(t)
	h := NewAuthHandler(nil, nil, authTestSecret, store, authAccessTTL, authRefreshTTL, nil)
	ctx := context.Background()

	const refreshToken = "logout-refresh"
	if err := store.CreateRefresh(ctx, refreshToken, "user-logout", "user", 0, authRefreshTTL); err != nil {
		t.Fatalf("CreateRefresh: %v", err)
	}

	// 签一个有效 access token（jti 已知），模拟中间件已通过
	access, err := auth.GenerateToken(authTestSecret, "user-logout", "user", "", 2*time.Hour, "jti-logout", 0)
	if err != nil {
		t.Fatalf("GenerateToken: %v", err)
	}
	claims, err := auth.ParseToken(authTestSecret, access)
	if err != nil {
		t.Fatalf("ParseToken: %v", err)
	}

	body := `{"refresh_token":"` + refreshToken + `"}`
	w := doLogoutRequest(t, h, store, claims, body)

	AssertOk(t, w, http.StatusOK)

	// jti 应在黑名单
	black, err := store.IsBlacklisted(ctx, claims.ID)
	if err != nil {
		t.Fatalf("IsBlacklisted: %v", err)
	}
	if !black {
		t.Fatal("logout 后 jti 未加入黑名单")
	}

	// refresh token 应已删除
	rd, err := store.GetRefresh(ctx, refreshToken)
	if err != nil {
		t.Fatalf("GetRefresh: %v", err)
	}
	if rd != nil {
		t.Fatalf("logout 后 refresh token 应已删除,仍存在: %+v", rd)
	}
}

// TestLogout_NoStoreSkipsRedis 验证 store=nil 时 logout 不 panic、不碰 Redis，直接返 200。
func TestLogout_NoStoreSkipsRedis(t *testing.T) {
	h := NewAuthHandler(nil, nil, authTestSecret, nil, authAccessTTL, authRefreshTTL, nil)

	access, err := auth.GenerateToken(authTestSecret, "user-nostore", "user", "", 2*time.Hour, "jti-nostore", 0)
	if err != nil {
		t.Fatalf("GenerateToken: %v", err)
	}
	claims, err := auth.ParseToken(authTestSecret, access)
	if err != nil {
		t.Fatalf("ParseToken: %v", err)
	}

	w := doLogoutRequest(t, h, nil, claims, `{}`)
	AssertOk(t, w, http.StatusOK)
}

// TestLogout_BlacklistedTokenRejectedByMiddleware 端到端验证：
// logout 把 jti 拉黑后，再用同 token 过 AuthMiddlewareWithStore 应被拦截（401 token_revoked）。
func TestLogout_BlacklistedTokenRejectedByMiddleware(t *testing.T) {
	store := newAuthTestStore(t)
	h := NewAuthHandler(nil, nil, authTestSecret, store, authAccessTTL, authRefreshTTL, nil)

	access, err := auth.GenerateToken(authTestSecret, "user-e2e", "user", "", 2*time.Hour, "jti-e2e", 0)
	if err != nil {
		t.Fatalf("GenerateToken: %v", err)
	}
	claims, err := auth.ParseToken(authTestSecret, access)
	if err != nil {
		t.Fatalf("ParseToken: %v", err)
	}

	// 先 logout（拉黑 jti）
	wLogout := doLogoutRequest(t, h, store, claims, `{}`)
	AssertOk(t, wLogout, http.StatusOK)

	// 再用同 token 过中间件 → 应 401
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.GET("/ping", AuthMiddlewareWithStore(authTestSecret, store), func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"ok": true})
	})
	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	req.Header.Set("Authorization", "Bearer "+access)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	AssertErr(t, w, http.StatusUnauthorized, "token_revoked")
}
