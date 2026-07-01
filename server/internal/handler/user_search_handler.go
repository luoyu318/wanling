package handler

import (
	"log"
	"net/http"

	"github.com/gin-gonic/gin"
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
// 不存在的 username 返回空列表(不报错)。空 username → 400。
func (h *UserSearchHandler) Search(c *gin.Context) {
	username := c.Query("username")
	if username == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "username required"})
		return
	}
	users, err := h.userRepo.SearchByUsername(username, 20)
	if err != nil {
		log.Printf("[user-search] SearchByUsername error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"users": users})
}
