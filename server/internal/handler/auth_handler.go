package handler

import (
	"net/http"
	"time"

	"github.com/gin-gonic/gin"

	"github.com/wanling/server/internal/auth"
	"github.com/wanling/server/internal/repository"
	"golang.org/x/crypto/bcrypt"
)

// AuthHandler 认证处理器
type AuthHandler struct {
	userRepo  *repository.UserRepo
	agentRepo *repository.AgentRepo
	jwtSecret string
}

// NewAuthHandler 创建认证处理器
func NewAuthHandler(userRepo *repository.UserRepo, agentRepo *repository.AgentRepo, jwtSecret string) *AuthHandler {
	return &AuthHandler{userRepo: userRepo, agentRepo: agentRepo, jwtSecret: jwtSecret}
}

// RegisterRequest 注册请求
type RegisterRequest struct {
	Username string `json:"username" binding:"required,min=3,max=64"`
	Password string `json:"password" binding:"required,min=6"`
}

// Register 用户注册
func (h *AuthHandler) Register(c *gin.Context) {
	var req RegisterRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	existing, err := h.userRepo.GetByUsername(req.Username)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	if existing != nil {
		c.JSON(http.StatusConflict, gin.H{"error": "用户名已存在"})
		return
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}

	user, err := h.userRepo.Create(req.Username, string(hash))
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}

	token, err := auth.GenerateToken(h.jwtSecret, user.ID, "user", "", 72*24*time.Hour)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}

	c.JSON(http.StatusCreated, gin.H{"user": user, "token": token})
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
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	user, err := h.userRepo.GetByUsername(req.Username)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "用户名或密码错误"})
		return
	}

	if err := bcrypt.CompareHashAndPassword([]byte(user.PasswordHash), []byte(req.Password)); err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "用户名或密码错误"})
		return
	}

	token, err := auth.GenerateToken(h.jwtSecret, user.ID, "user", "", 72*24*time.Hour)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"user": user, "token": token})
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
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	agent, err := h.agentRepo.GetByID(req.AgentID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	if agent == nil || agent.SecretKey != req.SecretKey {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "无效凭证"})
		return
	}

	token, err := auth.GenerateToken(h.jwtSecret, agent.ID, "agent", agent.OwnerID, 72*24*time.Hour)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"token": token})
}
