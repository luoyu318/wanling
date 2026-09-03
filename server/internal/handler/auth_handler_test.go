package handler

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/alicebob/miniredis/v2"
	"github.com/gin-gonic/gin"
	"github.com/redis/go-redis/v9"
	"golang.org/x/crypto/bcrypt"

	"github.com/wanling/server/internal/auth"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
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
// userRepo/agentRepo 传 nil：仅适用于不触发 Refresh DB 重读的路径（Logout、无效 token 拒绝等）。
// 需要 userRepo 的用例（Refresh happy path / role 重算）须自建真库 repo。
func newAuthHandlerWithStore(t *testing.T) *AuthHandler {
	t.Helper()
	return NewAuthHandler(nil, nil, nil, authTestSecret, newAuthTestStore(t), authAccessTTL, authRefreshTTL)
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
//   - 真库建用户（role=user），用 CreateRefresh 预置有效 refresh token（ver=0）；
//   - POST /api/auth/refresh 携带该 token → 期望 200 + 返回新 token pair + 顶层 role；
//   - 旧 refresh token 应被删除（GetRefresh 返 nil）。
func TestRefresh_HappyPath(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	user, err := urepo.Create(t.Context(), shortName(t, "ref_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user: %v", err)
	}

	store := newAuthTestStore(t)
	h := NewAuthHandler(urepo, nil, nil, authTestSecret, store, authAccessTTL, authRefreshTTL)
	ctx := context.Background()

	const oldRefresh = "old-refresh-abc"
	if err := store.CreateRefresh(ctx, oldRefresh, user.ID, "user", 0, authRefreshTTL); err != nil {
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
	// 顶层 role 与 DB 用户一致
	if data["role"] != "user" {
		t.Fatalf("响应顶层 role 应为 user: %v", data["role"])
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
	if newData == nil || newData.UserID != user.ID {
		t.Fatalf("新 refresh token 缺失或数据错误: %+v", newData)
	}

	// 新 access token 应能被 ParseToken 解析
	claims, err := auth.ParseToken(authTestSecret, newAccess)
	if err != nil {
		t.Fatalf("ParseToken(new access): %v", err)
	}
	if claims.Subject != user.ID {
		t.Fatalf("新 access token subject 错误: %s", claims.Subject)
	}
}

// TestRefresh_RoleFromDBNotToken 验证 role 以 DB 为准：
// 旧 refresh token 内 role=admin（历史签发），但 DB 用户 role=user（已被撤销）→
// 刷新后响应 role=user，且新 access token claims.Role=user，证明 data.Role 被弃用。
func TestRefresh_RoleFromDBNotToken(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	user, err := urepo.Create(t.Context(), shortName(t, "demote_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user: %v", err)
	}

	store := newAuthTestStore(t)
	h := NewAuthHandler(urepo, nil, nil, authTestSecret, store, authAccessTTL, authRefreshTTL)
	ctx := context.Background()

	// 构造历史 refresh token：data.Role="admin"，与 DB 当前 role=user 不符
	const staleRefresh = "stale-admin-refresh"
	if err := store.CreateRefresh(ctx, staleRefresh, user.ID, "admin", 0, authRefreshTTL); err != nil {
		t.Fatalf("CreateRefresh: %v", err)
	}

	body := `{"refresh_token":"` + staleRefresh + `"}`
	w := doRefreshRequest(t, h, body)

	data := AssertOk(t, w, http.StatusOK)
	if data["role"] != "user" {
		t.Fatalf("刷新后 role 应以 DB 为准(user),实际: %v", data["role"])
	}

	newAccess, _ := data["token"].(string)
	claims, err := auth.ParseToken(authTestSecret, newAccess)
	if err != nil {
		t.Fatalf("ParseToken(new access): %v", err)
	}
	if claims.Role != "user" {
		t.Fatalf("新 access token claims.Role 应为 user,实际: %s", claims.Role)
	}
}

// TestRefresh_StoreNil_503 验证 Redis 不可用（store=nil）时 refresh 返回 503。
// refresh 体系强依赖 Redis（rotation + 黑名单），无 store 时直接拒绝。
func TestRefresh_StoreNil_503(t *testing.T) {
	h := NewAuthHandler(nil, nil, nil, authTestSecret, nil, authAccessTTL, authRefreshTTL)

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
	h := NewAuthHandler(nil, nil, nil, authTestSecret, store, authAccessTTL, authRefreshTTL)
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

// doAuthRequest 构造 POST /api/auth/<path>（register/login）请求。
func doAuthRequest(t *testing.T, path string, hf gin.HandlerFunc, body string) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.POST("/api/auth/"+path, hf)

	req := httptest.NewRequest(http.MethodPost, "/api/auth/"+path, strings.NewReader(body))
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
	h := NewAuthHandler(nil, nil, nil, authTestSecret, store, authAccessTTL, authRefreshTTL)
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
	h := NewAuthHandler(nil, nil, nil, authTestSecret, nil, authAccessTTL, authRefreshTTL)

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
	h := NewAuthHandler(nil, nil, nil, authTestSecret, store, authAccessTTL, authRefreshTTL)

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

// --- Login / Register 响应顶层 role 测试 ---

// TestLogin_ResponseTopLevelRole 验证登录响应顶层带 role，口径与 DB 一致（非 admin 账号 → user）。
func TestLogin_ResponseTopLevelRole(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	h := NewAuthHandler(urepo, nil, nil, authTestSecret, nil, authAccessTTL, authRefreshTTL)

	username := shortName(t, "login_")
	hash, err := bcrypt.GenerateFromPassword([]byte("Str0ng!Pass"), bcrypt.DefaultCost)
	if err != nil {
		t.Fatalf("bcrypt hash: %v", err)
	}
	if _, err := urepo.Create(t.Context(), username, string(hash)); err != nil {
		t.Fatalf("Create user: %v", err)
	}

	body := `{"username":"` + username + `","password":"Str0ng!Pass"}`
	w := doAuthRequest(t, "login", h.Login, body)

	data := AssertOk(t, w, http.StatusOK)
	if data["role"] != "user" {
		t.Fatalf("登录响应顶层 role 应为 user,实际: %v", data["role"])
	}
}

// TestRegister_ResponseTopLevelRole 验证注册响应顶层带 role（新用户默认 user）。
func TestRegister_ResponseTopLevelRole(t *testing.T) {
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	h := NewAuthHandler(urepo, nil, nil, authTestSecret, nil, authAccessTTL, authRefreshTTL)

	body := `{"username":"` + shortName(t, "reg_") + `","password":"Str0ng!Pass"}`
	w := doAuthRequest(t, "register", h.Register, body)

	data := AssertOk(t, w, http.StatusCreated)
	if data["role"] != "user" {
		t.Fatalf("注册响应顶层 role 应为 user,实际: %v", data["role"])
	}
}

// --- AgentToken（子密钥前缀路由）测试 ---

// newAgentTokenFixture 构造 AgentToken 场景的真库环境：
// 返回 handler 与子密钥 repo,及预建的 agent（属主 user 一并创建）。
// agentSecret 是 agent 主密钥,调用方按需用其换 token。
func newAgentTokenFixture(t *testing.T, agentSecret string) (*AuthHandler, *repository.AgentSubKeyRepo, *model.Agent) {
	t.Helper()
	db := repository.SetupTestDB(t)
	urepo := repository.NewUserRepo(db)
	arepo := repository.NewAgentRepo(db)
	skrepo := repository.NewAgentSubKeyRepo(db)

	u, err := urepo.Create(t.Context(), shortName(t, "at_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("Create user: %v", err)
	}
	a, err := arepo.Create(t.Context(), u.ID, "agent-token-agent", agentSecret, "")
	if err != nil {
		t.Fatalf("Create agent: %v", err)
	}
	h := NewAuthHandler(nil, arepo, skrepo, authTestSecret, newAuthTestStore(t), authAccessTTL, authRefreshTTL)
	return h, skrepo, a
}

// doAgentTokenRequest 构造 POST /api/agents/:id/token 请求。
func doAgentTokenRequest(t *testing.T, h *AuthHandler, agentID, secretKey string) *httptest.ResponseRecorder {
	t.Helper()
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.POST("/api/agents/:id/token", h.AgentToken)

	body, err := json.Marshal(map[string]string{"agent_id": agentID, "secret_key": secretKey})
	if err != nil {
		t.Fatalf("marshal body: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/agents/"+agentID+"/token", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	return w
}

// TestAgentToken_MasterKeyClaims 主密钥（无 wlsk_ 前缀）换 token:
// claims 带 key_kind=master,key_id 为空。
func TestAgentToken_MasterKeyClaims(t *testing.T) {
	const masterSecret = "master-secret-key-hex"
	h, _, a := newAgentTokenFixture(t, masterSecret)

	w := doAgentTokenRequest(t, h, a.ID, masterSecret)
	data := AssertOk(t, w, http.StatusOK)
	token, _ := data["token"].(string)
	if token == "" {
		t.Fatalf("响应缺少 token: %v", data)
	}

	claims, err := auth.ParseToken(authTestSecret, token)
	if err != nil {
		t.Fatalf("ParseToken: %v", err)
	}
	if claims.Subject != a.ID || claims.Role != "agent" {
		t.Fatalf("claims 身份错误: sub=%s role=%s", claims.Subject, claims.Role)
	}
	if claims.KeyKind != "master" {
		t.Fatalf("主密钥 token key_kind 应为 master,实际 %q", claims.KeyKind)
	}
	if claims.KeyID != "" {
		t.Fatalf("主密钥 token key_id 应为空,实际 %q", claims.KeyID)
	}
}

// TestAgentToken_SubKeyClaimsAndTouchLastUsed 子密钥（wlsk_ 前缀）换 token:
// claims 带 key_kind=sub + key_id=子密钥 ID,且 last_used_at 被 TouchLastUsed 写入。
func TestAgentToken_SubKeyClaimsAndTouchLastUsed(t *testing.T) {
	const masterSecret = "master-secret-key-hex"
	h, skrepo, a := newAgentTokenFixture(t, masterSecret)
	sk, err := skrepo.Create(t.Context(), a.ID, "CI 密钥", auth.SubKeyPrefix+"test_sub_key")
	if err != nil {
		t.Fatalf("Create sub key: %v", err)
	}

	w := doAgentTokenRequest(t, h, a.ID, sk.SecretKey)
	data := AssertOk(t, w, http.StatusOK)
	token, _ := data["token"].(string)
	if token == "" {
		t.Fatalf("响应缺少 token: %v", data)
	}

	claims, err := auth.ParseToken(authTestSecret, token)
	if err != nil {
		t.Fatalf("ParseToken: %v", err)
	}
	if claims.Subject != a.ID || claims.Role != "agent" {
		t.Fatalf("claims 身份错误: sub=%s role=%s", claims.Subject, claims.Role)
	}
	if claims.KeyKind != "sub" {
		t.Fatalf("子密钥 token key_kind 应为 sub,实际 %q", claims.KeyKind)
	}
	if claims.KeyID != sk.ID {
		t.Fatalf("子密钥 token key_id 应为 %q,实际 %q", sk.ID, claims.KeyID)
	}

	// last_used_at 应被写入（fail-soft 不阻断,但正常路径必须落库）
	got, err := skrepo.GetByKey(t.Context(), sk.SecretKey)
	if err != nil {
		t.Fatalf("GetByKey: %v", err)
	}
	if got == nil || got.LastUsedAt == nil {
		t.Fatalf("last_used_at 应被写入,实际: %+v", got)
	}
}

// TestAgentToken_RevokedSubKey401 已吊销子密钥换 token → 401。
func TestAgentToken_RevokedSubKey401(t *testing.T) {
	const masterSecret = "master-secret-key-hex"
	h, skrepo, a := newAgentTokenFixture(t, masterSecret)
	sk, err := skrepo.Create(t.Context(), a.ID, "已吊销密钥", auth.SubKeyPrefix+"revoked_key")
	if err != nil {
		t.Fatalf("Create sub key: %v", err)
	}
	if err := skrepo.Revoke(t.Context(), sk.ID); err != nil {
		t.Fatalf("Revoke: %v", err)
	}

	w := doAgentTokenRequest(t, h, a.ID, sk.SecretKey)

	AssertErr(t, w, http.StatusUnauthorized, "unauthorized")
}

// TestAgentToken_FakeSubKey401 前缀是 wlsk_ 但凭据不存在的伪子密钥 → 401。
func TestAgentToken_FakeSubKey401(t *testing.T) {
	const masterSecret = "master-secret-key-hex"
	h, _, a := newAgentTokenFixture(t, masterSecret)

	w := doAgentTokenRequest(t, h, a.ID, auth.SubKeyPrefix+"nonexistent")

	AssertErr(t, w, http.StatusUnauthorized, "unauthorized")
}

// TestAgentToken_LegacyTokenNoKeyKind 存量 token 由 GenerateToken 签发,
// 无 key_kind/key_id 字段;解析后两字段为空串,消费方以 KeyKind=="" 判定为 master（向后兼容）。
func TestAgentToken_LegacyTokenNoKeyKind(t *testing.T) {
	legacy, err := auth.GenerateToken(authTestSecret, "agent-legacy", "agent", "owner-legacy", time.Hour, "jti-legacy", 0)
	if err != nil {
		t.Fatalf("GenerateToken: %v", err)
	}

	claims, err := auth.ParseToken(authTestSecret, legacy)
	if err != nil {
		t.Fatalf("ParseToken: %v", err)
	}
	if claims.KeyKind != "" {
		t.Fatalf("存量 token key_kind 应为空串（视为 master）,实际 %q", claims.KeyKind)
	}
	if claims.KeyID != "" {
		t.Fatalf("存量 token key_id 应为空串,实际 %q", claims.KeyID)
	}
}
