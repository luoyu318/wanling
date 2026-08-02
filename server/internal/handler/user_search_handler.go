package handler

import (
	"database/sql"
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/repository"
)

// UserSearchHandler 处理 user 模糊搜索 API(spec §4.2)。
//
// 路由:GET /api/users/search?username=xxx
//
// 关键设计:响应不含 user_id(防枚举),只返 UserSummary(username/nickname/avatar_url)。
// 客户端拿到候选列表后,选定的 username 走 POST /api/users/me/friend-requests
// (body: {to_username}),server 内部反查 user_id 写 friendships。
type UserSearchHandler struct {
	userRepo *repository.UserRepo
}

// NewUserSearchHandler 构造 UserSearchHandler。
func NewUserSearchHandler(userRepo *repository.UserRepo) *UserSearchHandler {
	return &UserSearchHandler{userRepo: userRepo}
}

// Search GET /api/users/search?username=xxx
// 前缀模糊匹配(ILIKE query%),上限 20 条,大小写不敏感。
// 排除当前 user 自己（避免搜到自己加自己）。
// 不存在的 username 返回空列表(不报错)。空 username → 400。
func (h *UserSearchHandler) Search(c *gin.Context) {
	username := c.Query("username")
	if username == "" {
		Err(c, http.StatusBadRequest, "bad_request", "username required")
		return
	}
	userID := c.GetString("userID")
	users, err := h.userRepo.SearchByUsername(c.Request.Context(), username, userID, 20)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "user-search SearchByUsername 失败",
			"username", username, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	// 剥集合 envelope：旧 {users: [...]} → 新 data: [...]
	Ok(c, users)
}

// GetByUsername GET /api/users/by-username/:username
// 按 username 查 UserSummary（不含 user_id）。client 端「用户详情页」用。
// 用户不存在返 404。
func (h *UserSearchHandler) GetByUsername(c *gin.Context) {
	username := c.Param("username")
	if username == "" {
		Err(c, http.StatusBadRequest, "bad_request", "username required")
		return
	}
	user, err := h.userRepo.GetSummaryByUsername(c.Request.Context(), username)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			Err(c, http.StatusNotFound, "not_found", "user not found")
			return
		}
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "user-get GetSummaryByUsername 失败",
			"username", username, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if user == nil {
		Err(c, http.StatusNotFound, "not_found", "user not found")
		return
	}
	Ok(c, user)
}
