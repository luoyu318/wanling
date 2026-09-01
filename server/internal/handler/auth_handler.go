package handler

import (
	"context"
	"crypto/subtle"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"github.com/wanling/server/internal/auth"
	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/repository"
	"golang.org/x/crypto/bcrypt"
)

// bcryptCost 密码哈希成本。bcrypt.DefaultCost=10 偏低，升到 12 提高暴力破解成本。
// 登录时检测旧 hash 的 cost < bcryptCost 会自动 rehash 升级。
const bcryptCost = 12

// AuthHandler 认证处理器
type AuthHandler struct {
	userRepo   *repository.UserRepo
	agentRepo  *repository.AgentRepo
	jwtSecret  string
	tokenStore *auth.TokenStore
	accessTTL  time.Duration
	refreshTTL time.Duration
}

// NewAuthHandler 创建认证处理器
func NewAuthHandler(userRepo *repository.UserRepo, agentRepo *repository.AgentRepo, jwtSecret string, tokenStore *auth.TokenStore, accessTTL, refreshTTL time.Duration) *AuthHandler {
	return &AuthHandler{userRepo: userRepo, agentRepo: agentRepo, jwtSecret: jwtSecret, tokenStore: tokenStore, accessTTL: accessTTL, refreshTTL: refreshTTL}
}

// issueTokenPair 签发 access + refresh token。store 为 nil 时跳过 Redis 读写，仅签发 access。
func (h *AuthHandler) issueTokenPair(userID, role, owner string) (string, string, error) {
	jti := uuid.New().String()
	ver := 0
	if h.tokenStore != nil {
		ver, _ = h.tokenStore.GetTokenVersion(context.Background(), userID)
	}
	access, err := auth.GenerateToken(h.jwtSecret, userID, role, owner, h.accessTTL, jti, ver)
	if err != nil {
		return "", "", err
	}
	refresh := auth.GenerateRefreshToken()
	if h.tokenStore != nil {
		if err := h.tokenStore.CreateRefresh(context.Background(), refresh, userID, role, ver, h.refreshTTL); err != nil {
			return "", "", err
		}
	}
	return access, refresh, nil
}

// RegisterRequest 注册请求
type RegisterRequest struct {
	Username string `json:"username" binding:"required,min=3,max=64"`
	Password string `json:"password" binding:"required,min=8,max=64"`
}

// Register 用户注册
func (h *AuthHandler) Register(c *gin.Context) {
	var req RegisterRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	if err := validatePasswordStrength(req.Password); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	existing, err := h.userRepo.GetByUsername(c.Request.Context(), req.Username)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if existing != nil {
		Err(c, http.StatusConflict, "invalid_state", "用户名已存在")
		return
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcryptCost)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	user, err := h.userRepo.Create(c.Request.Context(), req.Username, string(hash))
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	access, refresh, err := h.issueTokenPair(user.ID, user.Role, "")
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	OkCreated(c, gin.H{"user": user, "token": access, "refresh_token": refresh, "role": user.Role})
}

// LoginRequest 登录请求
type LoginRequest struct {
	Username string `json:"username" binding:"required"`
	Password string `json:"password" binding:"required"`
}

// Login 用户登录
func (h *AuthHandler) Login(c *gin.Context) {
	var req LoginRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	user, err := h.userRepo.GetByUsername(c.Request.Context(), req.Username)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if user == nil {
		Err(c, http.StatusUnauthorized, "unauthorized", "用户名或密码错误")
		return
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(req.Password)); err != nil {
		Err(c, http.StatusUnauthorized, "unauthorized", "用户名或密码错误")
		return
	}

	// bcrypt cost 升级：旧 hash 的 cost < bcryptCost 时，用新 cost 重新 hash 并更新。
	// rehash 失败不阻塞登录（用户已验证成功），仅记 warn 日志。
	if hashCost, err := bcrypt.Cost([]byte(user.PasswordHash)); err == nil && hashCost < bcryptCost {
		newHash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcryptCost)
		if err == nil {
			if err := h.userRepo.UpdatePassword(c.Request.Context(), user.ID, string(newHash)); err != nil {
				logpkg.FromCtx(c.Request.Context()).WarnContext(c.Request.Context(), "bcrypt rehash 更新失败", "err", err)
			}
		}
	}

	access, refresh, err := h.issueTokenPair(user.ID, user.Role, "")
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	Ok(c, gin.H{"user": user, "token": access, "refresh_token": refresh, "role": user.Role})
}

// AgentTokenRequest Agent token 换取请求
type AgentTokenRequest struct {
	AgentID   string `json:"agent_id" binding:"required"`
	SecretKey string `json:"secret_key" binding:"required"`
}

// AgentToken Agent 通过密钥换取 token
func (h *AuthHandler) AgentToken(c *gin.Context) {
	var req AgentTokenRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	agent, err := h.agentRepo.GetByID(c.Request.Context(), req.AgentID)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	// 恒定时间比较防时序攻击。secret_key 是 64 字符 hex(256 bit),
	// 实际利用时序差异逐字节猜需极高精度,且有 IP 限流(10/min)兜底,
	// 但写一行代码堵上是免费的安全加固。
	if agent == nil || subtle.ConstantTimeCompare([]byte(agent.SecretKey), []byte(req.SecretKey)) != 1 {
		Err(c, http.StatusUnauthorized, "unauthorized", "无效凭证")
		return
	}

	jti := uuid.New().String()
	token, err := auth.GenerateToken(h.jwtSecret, agent.ID, "agent", agent.OwnerID, 72*time.Hour, jti, 0)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	Ok(c, gin.H{"token": token})
}

// RefreshRequest refresh token 换取新 access token
type RefreshRequest struct {
	RefreshToken string `json:"refresh_token" binding:"required"`
}

// Refresh 凭 refresh token 换取新 access + refresh token（rotation：旧 refresh 立即失效）。
// store 为 nil（Redis 不可用）时返回 503，因 refresh 体系强依赖 Redis。
func (h *AuthHandler) Refresh(c *gin.Context) {
	var req RefreshRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	if h.tokenStore == nil {
		ErrMsg(c, http.StatusServiceUnavailable, "token store 不可用")
		return
	}

	data, err := h.tokenStore.GetRefresh(c.Request.Context(), req.RefreshToken)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if data == nil {
		Err(c, http.StatusUnauthorized, "invalid_refresh", "refresh token 无效或已过期")
		return
	}

	curVer, err := h.tokenStore.GetTokenVersion(c.Request.Context(), data.UserID)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if curVer != data.Ver {
		Err(c, http.StatusUnauthorized, "invalid_refresh", "token 版本不匹配")
		return
	}

	if err := h.tokenStore.DeleteRefresh(c.Request.Context(), req.RefreshToken); err != nil {
		logpkg.FromCtx(c.Request.Context()).WarnContext(c.Request.Context(),
			"rotation 删旧 refresh token 失败", "err", err)
	}

	// role DB 为准:refresh 重读当前 role 签发,旧 refresh token 内的 role 不再信任。
	// 改 env/DB 撤销 admin 后,下次刷新即生效,无需重新登录。
	u, err := h.userRepo.GetByID(c.Request.Context(), data.UserID)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if u == nil {
		Err(c, http.StatusUnauthorized, "invalid_refresh", "refresh token 无效或已过期")
		return
	}

	access, refresh, err := h.issueTokenPair(data.UserID, u.Role, "")
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	Ok(c, gin.H{"token": access, "refresh_token": refresh, "role": u.Role})
}

// LogoutRequest 登出请求（refresh_token 可选，传了则一并删除）
type LogoutRequest struct {
	RefreshToken string `json:"refresh_token"`
}

// Logout 登出：把当前 access token 的 jti 加入黑名单（剩余 TTL），并删除 body 携带的 refresh token。
func (h *AuthHandler) Logout(c *gin.Context) {
	claimsVal, exists := c.Get("claims")
	if !exists {
		Err(c, http.StatusUnauthorized, "unauthorized", "未认证")
		return
	}
	claims, ok := claimsVal.(*auth.Claims)
	if !ok {
		Err(c, http.StatusUnauthorized, "unauthorized", "claims 类型错误")
		return
	}

	if h.tokenStore != nil && claims.ID != "" && claims.ExpiresAt != nil {
		ttl := time.Until(claims.ExpiresAt.Time)
		if ttl > 0 {
			if err := h.tokenStore.BlacklistToken(c.Request.Context(), claims.ID, ttl); err != nil {
				logpkg.FromCtx(c.Request.Context()).WarnContext(c.Request.Context(),
					"黑名单写入失败", "jti", claims.ID, "err", err)
			}
		}
	}

	var req LogoutRequest
	if err := c.ShouldBindJSON(&req); err == nil && req.RefreshToken != "" && h.tokenStore != nil {
		if err := h.tokenStore.DeleteRefresh(c.Request.Context(), req.RefreshToken); err != nil {
			logpkg.FromCtx(c.Request.Context()).WarnContext(c.Request.Context(),
				"登出删 refresh token 失败", "err", err)
		}
	}

	Ok(c, nil)
}
