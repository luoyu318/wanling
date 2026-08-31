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

// newMWAdminToken 签发 admin 角色 token(admin 兼作 user 的超集测试用)。
func newMWAdminToken(t *testing.T, userID, jti string, ver int) string {
	t.Helper()
	tok, err := auth.GenerateToken(mwTestSecret, userID, "admin", "", 2*time.Hour, jti, ver)
	if err != nil {
		t.Fatalf("GenerateToken: %v", err)
	}
	return tok
}

// doMWRequest 构造一个带 Bearer token 的 GET 请求，跑通中间件后命中 200 handler（放行）或被中间件拦截。
func doMWRequest(t *testing.T, store *auth.TokenStore, token string) *httptest.ResponseRecorder {
	t.Helper()
	return doMWRequestRoles(t, store, token)
}

// doMWRequestRoles 与 doMWRequest 同款,但可指定允许角色组(测 admin 超集放行)。
func doMWRequestRoles(t *testing.T, store *auth.TokenStore, token string, allowedRoles ...string) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.GET("/ping", AuthMiddlewareWithStore(mwTestSecret, store, allowedRoles...), func(c *gin.Context) {
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

// doMWRequestCaptureRole 与 doMWRequestRoles 同款,但 handler 把下游读到的 role 带回响应体
// (测 admin 归一化:下游消费 role 当 memberType,必须读到 user)。
func doMWRequestCaptureRole(t *testing.T, token string, allowedRoles ...string) (int, string) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	r := gin.New()
	var role string
	r.GET("/ping", AuthMiddlewareWithStore(mwTestSecret, nil, allowedRoles...), func(c *gin.Context) {
		role = c.GetString("role")
		c.JSON(http.StatusOK, gin.H{"ok": true})
	})

	req := httptest.NewRequest(http.MethodGet, "/ping", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w.Code, role
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

// TestAuthMiddleware_AdminIsUserSuperset 方案 a:admin 是 user 的超集,
// admin token 请求 user 组路由应放行(平台管理员可用 APP 全部用户能力)。
func TestAuthMiddleware_AdminIsUserSuperset(t *testing.T) {
	tok := newMWAdminToken(t, "admin-superset", "jti-admin-user", 0)
	w := doMWRequestRoles(t, nil, tok, "user")
	AssertOk(t, w, http.StatusOK)
}

// TestAuthMiddleware_AdminNotAgent agent 组保持严格隔离,admin token 不能当 agent。
func TestAuthMiddleware_AdminNotAgent(t *testing.T) {
	tok := newMWAdminToken(t, "admin-agent", "jti-admin-agent", 0)
	w := doMWRequestRoles(t, nil, tok, "agent")
	AssertErr(t, w, http.StatusForbidden, "forbidden")
}

// TestAuthMiddleware_AdminRoleNormalizedToUser 终审 I1 收尾:下游 handler 把 role 当
// memberType 消费(participant 查询等,值域 user/agent),admin 进 user 组后 context role
// 必须归一为 user,否则群消息等接口全部 403(真机暴露的回归)。
func TestAuthMiddleware_AdminRoleNormalizedToUser(t *testing.T) {
	tok := newMWAdminToken(t, "admin-normalize", "jti-admin-norm", 0)
	code, role := doMWRequestCaptureRole(t, tok, "user")
	if code != http.StatusOK {
		t.Fatalf("admin 进 user 组应放行,实际 %d", code)
	}
	if role != "user" {
		t.Errorf("下游 role 应归一为 user,实际 %q", role)
	}

	// user 角色行为不变
	tokU := newMWToken(t, "norm-user", "jti-norm-user", 0)
	codeU, roleU := doMWRequestCaptureRole(t, tokU, "user")
	if codeU != http.StatusOK || roleU != "user" {
		t.Errorf("user 角色应原样透出,实际 %d %q", codeU, roleU)
	}
}
