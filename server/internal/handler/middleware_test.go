package handler

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"

	"github.com/wanling/server/internal/auth"
)

const mwTestSecret = "mw-test-secret"

// newMWTestStore 起 miniredis + TokenStore，用于 middleware 集成测试。
func newMWTestStore(t *testing.T) *auth.TokenStore {
	t.Helper()
	mr := miniredis.RunT(t)
	rdb := redis.NewClient(&redis.Options{Addr: mr.Addr()})
	t.Cleanup(func() { rdb.Close() })
	return auth.NewTokenStore(rdb)
}

// newMWToken 用统一 helper 签发测试 token，避免每个用例重复参数。
func newMWToken(t *testing.T, userID, jti string, ver int) string {
	t.Helper()
	tok, err := auth.GenerateToken(mwTestSecret, userID, "user", "", 2*time.Hour, jti, ver)
	if err != nil {
		t.Fatalf("GenerateToken: %v", err)
	}
	return tok
}

// doMWRequest 构造一个带 Bearer token 的 GET 请求，跑通中间件后命中 200 handler（放行）或被中间件拦截。
func doMWRequest(t *testing.T, store *auth.TokenStore, token string) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.GET("/ping", AuthMiddlewareWithStore(mwTestSecret, store), func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"ok": true})
	})

	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

// TestAuthMiddlewareWithStore_TokenVersionMismatch 验证改密后旧 token（ver 不匹配）被拦截。
// 场景：用户首次改密 IncrTokenVersion(0→1)，但旧 access token 仍是 ver=0 → middleware 应返 401。
// 这条测试专门覆盖原 bug：旧代码 `claims.Version > 0` 条件导致 ver=0 token 永远绕过 tokenver 检查。
func TestAuthMiddlewareWithStore_TokenVersionMismatch(t *testing.T) {
	store := newMWTestStore(t)
	ctx := context.Background()

	if _, err := store.IncrTokenVersion(ctx, "user-mismatch"); err != nil {
		t.Fatalf("IncrTokenVersion: %v", err)
	}

	tok := newMWToken(t, "user-mismatch", "jti-mismatch", 0)
	w := doMWRequest(t, store, tok)

	AssertErr(t, w, http.StatusUnauthorized, "token_version_mismatch")
}

// TestAuthMiddlewareWithStore_TokenVersionMatch 验证未改密用户（ver=0，Redis 无 key）正常放行。
// GetTokenVersion 对不存在 key 返回 0，0==0 → 放行。
func TestAuthMiddlewareWithStore_TokenVersionMatch(t *testing.T) {
	store := newMWTestStore(t)

	tok := newMWToken(t, "user-match", "jti-match", 0)
	w := doMWRequest(t, store, tok)

	AssertOk(t, w, http.StatusOK)
}

// TestAuthMiddlewareWithStore_BlacklistHit 验证 jti 已加黑名单的 token 被拦截（401）。
func TestAuthMiddlewareWithStore_BlacklistHit(t *testing.T) {
	store := newMWTestStore(t)
	ctx := context.Background()

	if err := store.BlacklistToken(ctx, "jti-black", 2*time.Hour); err != nil {
		t.Fatalf("BlacklistToken: %v", err)
	}

	tok := newMWToken(t, "user-black", "jti-black", 0)
	w := doMWRequest(t, store, tok)

	AssertErr(t, w, http.StatusUnauthorized, "token_revoked")
}

// TestAuthMiddlewareWithStore_NilStoreSkip 验证 store=nil 时中间件降级为纯 JWT 校验，
// 跳过 Redis 黑名单/tokenver 检查，正常鉴权放行。
func TestAuthMiddlewareWithStore_NilStoreSkip(t *testing.T) {
	tok := newMWToken(t, "user-nil-store", "jti-nil", 0)
	w := doMWRequest(t, nil, tok)

	AssertOk(t, w, http.StatusOK)
}

// TestAuthMiddlewareWithStore_Ver0AfterIncr 额外回归：旧 bug 的精确复现。
// 注册签 ver=0 token → IncrTokenVersion(0→1) → 旧 ver=0 token 必须失效（原代码会放行）。
func TestAuthMiddlewareWithStore_Ver0AfterIncr(t *testing.T) {
	store := newMWTestStore(t)
	ctx := context.Background()

	tok := newMWToken(t, "user-reg", "jti-reg", 0)

	// 改密前放行
	w1 := doMWRequest(t, store, tok)
	AssertOk(t, w1, http.StatusOK)

	// 改密后必须拦截
	if _, err := store.IncrTokenVersion(ctx, "user-reg"); err != nil {
		t.Fatalf("IncrTokenVersion: %v", err)
	}
	w2 := doMWRequest(t, store, tok)
	AssertErr(t, w2, http.StatusUnauthorized, "token_version_mismatch")
}
