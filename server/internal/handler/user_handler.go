package handler

import (
	"database/sql"
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/repository"
	"golang.org/x/crypto/bcrypt"
)

// UserHandler 用户相关的 HTTP 处理器。当前仅 GetMe 一个接口。
type UserHandler struct {
	userRepo *repository.UserRepo
}

// NewUserHandler 构造 UserHandler。
func NewUserHandler(userRepo *repository.UserRepo) *UserHandler {
	return &UserHandler{userRepo: userRepo}
}

// GetMe 返回当前登录用户信息。
//
// 分支约定：
//   - DB 错误（GetByID 返回非 nil err） → 500；
//   - 用户不存在（GetByID 返回 (nil, nil)，例如 token 未过期但用户被删） → 404；
//   - 正常 → 200 + User JSON。
//
// 脱敏：User.PasswordHash 字段标注 json:"-"，序列化时自动忽略 password_hash。
func (h *UserHandler) GetMe(c *gin.Context) {
	userID := c.GetString("userID")
	user, err := h.userRepo.GetByID(userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}
	if user == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	c.JSON(http.StatusOK, user)
}

// ChangePasswordRequest 修改密码请求。不需要旧密码（按业务澄清）。
type ChangePasswordRequest struct {
	NewPassword string `json:"new_password" binding:"required,min=6"`
}

// ChangePassword 当前登录用户改自己的密码。
//
// 业务约定：
//   - 不需要旧密码（session 已通过 JWT 验证）
//   - 新密码 ≥ 6 位（与 Register 口径一致）
//   - 用户不存在 → 404；DB 错误 → 500；绑定失败 → 400
//
// 改密成功后当前 token 仍有效（不强制重登）；前端可自行决定是否登出。
//
// 注意：UpdatePassword 返回 sql.ErrNoRows 表示"用户不存在"（不同于 GetByID 返回 nil,nil），
// 必须用 errors.Is(err, sql.ErrNoRows) 区分 404 vs 500。
func (h *UserHandler) ChangePassword(c *gin.Context) {
	var req ChangePasswordRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "新密码至少 6 位"})
		return
	}

	userID := c.GetString("userID")

	hash, err := bcrypt.GenerateFromPassword([]byte(req.NewPassword), bcrypt.DefaultCost)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}

	if err := h.userRepo.UpdatePassword(userID, string(hash)); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// UpdateMeRequest 更新当前用户资料。部分更新语义：
// Nickname/Bio 用指针：nil=不动，&""=清空；AvatarURL 空串=不动（不支持清空）。
type UpdateMeRequest struct {
	Nickname  *string `json:"nickname"   binding:"omitempty,max=64"`
	Bio       *string `json:"bio"        binding:"omitempty,max=200"`
	AvatarURL string  `json:"avatar_url" binding:"omitempty,max=256"`
}

// UpdateMe 更新当前登录用户的资料（昵称/简介/头像）。
// 成功返回更新后的完整 User JSON（脱敏 password_hash）。
// 用户不存在（token 未过期但用户被删）→ 404；绑定失败（超长等）→ 400；DB 错误 → 500。
func (h *UserHandler) UpdateMe(c *gin.Context) {
	var req UpdateMeRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	userID := c.GetString("userID")
	user, err := h.userRepo.Update(userID, repository.UpdateUserParams{
		Nickname:  req.Nickname,
		Bio:       req.Bio,
		AvatarURL: req.AvatarURL,
	})
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新失败"})
		return
	}
	if user == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "用户不存在"})
		return
	}
	c.JSON(http.StatusOK, user)
}
