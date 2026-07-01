package handler

import (
	"database/sql"
	"errors"
	"log"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/hub"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// FriendshipHandler 处理 user → user 好友关系全流程 API(spec §4.2)。
//
// 路由前缀:
//   - POST   /api/users/me/friend-requests          (CreateRequest)
//   - GET    /api/users/me/friend-requests/incoming (ListIncoming)
//   - GET    /api/users/me/friend-requests/outgoing (ListOutgoing)
//   - GET    /api/users/me/friends                  (ListFriends)
//   - POST   /api/friend-requests/:id/accept        (Accept)
//   - POST   /api/friend-requests/:id/reject        (Reject)
//   - POST   /api/friend-requests/:id/cancel        (Cancel)
//   - DELETE /api/users/me/friends/:id              (RemoveFriend)
//
// 关键设计:
//   - 加好友 body 用 to_username(不暴露 user_id 到 client);server 用 GetIDByUsername 反查。
//   - WS 通知在 DB 操作成功后才推,避免 DB 失败但通知已发。
//   - ListFriends / ListIncoming / ListOutgoing 用循环逐个取摘要(本 task 接受 N+1,数量小)。
type FriendshipHandler struct {
	friendshipRepo *repository.FriendshipRepo
	userRepo       *repository.UserRepo
	hub            *hub.Hub
}

// NewFriendshipHandler 构造 FriendshipHandler。hub 可为 nil(测试场景)。
func NewFriendshipHandler(
	friendshipRepo *repository.FriendshipRepo,
	userRepo *repository.UserRepo,
	hub *hub.Hub,
) *FriendshipHandler {
	return &FriendshipHandler{
		friendshipRepo: friendshipRepo,
		userRepo:       userRepo,
		hub:            hub,
	}
}

// CreateRequest POST /api/users/me/friend-requests body:{to_username}
// body 用 to_username(不是 to_user_id),因为 user 搜索不暴露 user_id(spec §4.2)。
// 不能加自己为好友(400);双向已存在好友关系返 409 Conflict。
func (h *FriendshipHandler) CreateRequest(c *gin.Context) {
	fromUserID := c.GetString("userID")

	var req struct {
		ToUsername string `json:"to_username" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// username → user_id 反查
	toUserID, err := h.userRepo.GetIDByUsername(req.ToUsername)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
			return
		}
		log.Printf("[friend-request] GetIDByUsername error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}

	// 不能加自己为好友
	if toUserID == fromUserID {
		c.JSON(http.StatusBadRequest, gin.H{"error": "cannot friend yourself"})
		return
	}

	// CreateRequest(双向校验)
	friendship, err := h.friendshipRepo.CreateRequest(fromUserID, toUserID)
	if err != nil {
		if errors.Is(err, repository.ErrFriendshipAlreadyExists) {
			c.JSON(http.StatusConflict, gin.H{"error": "friendship already exists"})
			return
		}
		log.Printf("[friend-request] CreateRequest error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}

	// 取双方 user 摘要:from 摘要用于通知接收方(让其知道谁加的他),
	// to 摘要用于响应给发起方(确认请求的对象)。
	fromSummary, err := h.userRepo.GetSummaryByID(fromUserID)
	if err != nil {
		log.Printf("[friend-request] GetSummaryByID from error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	toSummary, err := h.userRepo.GetSummaryByID(toUserID)
	if err != nil {
		log.Printf("[friend-request] GetSummaryByID to error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}

	// WS 通知接收方(DB 成功后才推)
	if h.hub != nil && fromSummary != nil {
		nickname := ""
		if fromSummary.Nickname != nil {
			nickname = *fromSummary.Nickname
		}
		h.hub.SendFriendRequestReceived(
			toUserID, friendship.ID, fromUserID,
			fromSummary.Username, nickname, fromSummary.AvatarURL,
			friendship.CreatedAt,
		)
	}

	c.JSON(http.StatusOK, gin.H{
		"request_id": friendship.ID,
		"status":     friendship.Status,
		"to_user":    toSummary, // 接收方摘要(不含 id,防泄漏)
	})
}

// ListIncoming GET /api/users/me/friend-requests/incoming
// 返回我收到的 pending 请求,按 created_at DESC 排序,带发起方摘要。
func (h *FriendshipHandler) ListIncoming(c *gin.Context) {
	userID := c.GetString("userID")
	requests, err := h.friendshipRepo.ListIncomingRequests(userID)
	if err != nil {
		log.Printf("[friend-incoming] ListIncomingRequests error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	result := h.enrichFriendRequests(requests, "from")
	c.JSON(http.StatusOK, gin.H{"requests": result})
}

// ListOutgoing GET /api/users/me/friend-requests/outgoing
// 返回我发出的 pending 请求,按 created_at DESC 排序,带接收方摘要。
func (h *FriendshipHandler) ListOutgoing(c *gin.Context) {
	userID := c.GetString("userID")
	requests, err := h.friendshipRepo.ListOutgoingRequests(userID)
	if err != nil {
		log.Printf("[friend-outgoing] ListOutgoingRequests error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	result := h.enrichFriendRequests(requests, "to")
	c.JSON(http.StatusOK, gin.H{"requests": result})
}

// ListFriends GET /api/users/me/friends
// 返回我的 accepted 好友列表(摘要,不含 id 由 UserSummary 自身约束)。
func (h *FriendshipHandler) ListFriends(c *gin.Context) {
	userID := c.GetString("userID")
	friendIDs, err := h.friendshipRepo.ListFriends(userID)
	if err != nil {
		log.Printf("[friend-list] ListFriends error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	friends := []model.UserSummary{}
	for _, id := range friendIDs {
		s, err := h.userRepo.GetSummaryByID(id)
		if err != nil {
			log.Printf("[friend-list] GetSummaryByID %s error: %v", id, err)
			continue
		}
		if s != nil {
			friends = append(friends, *s)
		}
	}
	c.JSON(http.StatusOK, gin.H{"friends": friends})
}

// Accept POST /api/friend-requests/:id/accept
// 只有接收方(friend_id)才能接受;非 receiver / 非 pending / 不存在 → 404。
// 成功后 WS 通知发起方(decision=accepted)。
func (h *FriendshipHandler) Accept(c *gin.Context) {
	h.decide(c, "accepted")
}

// Reject POST /api/friend-requests/:id/reject
// 只有接收方(friend_id)才能拒绝;非 receiver / 非 pending / 不存在 → 404。
// 成功后 WS 通知发起方(decision=rejected)。
func (h *FriendshipHandler) Reject(c *gin.Context) {
	h.decide(c, "rejected")
}

// Cancel POST /api/friend-requests/:id/cancel
// 只有发起方(user_id)才能取消;非 sender / 非 pending / 不存在 → 404。
// 成功后 WS 通知接收方(decision=canceled)。
func (h *FriendshipHandler) Cancel(c *gin.Context) {
	userID := c.GetString("userID")
	requestID := c.Param("id")
	if err := h.friendshipRepo.Cancel(requestID, userID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			c.JSON(http.StatusNotFound, gin.H{"error": "request not found or not pending"})
			return
		}
		log.Printf("[friend-cancel] Cancel error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	// Cancel 由发起方操作,通知接收方
	req, err := h.friendshipRepo.GetByID(requestID)
	if err != nil {
		log.Printf("[friend-cancel] GetByID error: %v", err)
	} else if req != nil && h.hub != nil {
		h.hub.SendFriendRequestDecided(req.FriendID, requestID, "canceled", userID)
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// decide 是 Accept/Reject 的共享实现(都由接收方操作)。
// newState: accepted / rejected。成功后通知发起方(user_id)。
func (h *FriendshipHandler) decide(c *gin.Context, newState string) {
	userID := c.GetString("userID")
	requestID := c.Param("id")

	var err error
	if newState == "accepted" {
		err = h.friendshipRepo.Accept(requestID, userID)
	} else {
		err = h.friendshipRepo.Reject(requestID, userID)
	}
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			c.JSON(http.StatusNotFound, gin.H{"error": "request not found or not pending"})
			return
		}
		log.Printf("[friend-decide] %s error: %v", newState, err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	// Accept/Reject 由接收方操作,通知发起方(user_id)
	req, err := h.friendshipRepo.GetByID(requestID)
	if err != nil {
		log.Printf("[friend-decide] GetByID error: %v", err)
	} else if req != nil && h.hub != nil {
		h.hub.SendFriendRequestDecided(req.UserID, requestID, newState, userID)
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// RemoveFriend DELETE /api/users/me/friends/:username
// 删除好友关系(双向)。非 accepted / 无关系 → 404。成功后 WS 通知对方。
//
// path 参数用 username 而非 user_id:client 端不持有 user_id(防 user_id 枚举泄漏,
// spec §4.2),好友列表 API 返 UserSummary 不含 id。client 调本接口时传 username,
// server 内部用 userRepo.GetIDByUsername 反查 friend_user_id。
func (h *FriendshipHandler) RemoveFriend(c *gin.Context) {
	userID := c.GetString("userID")
	friendUsername := c.Param("username")
	if friendUsername == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "username required"})
		return
	}
	friendID, err := h.userRepo.GetIDByUsername(friendUsername)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
			return
		}
		log.Printf("[friend-remove] GetIDByUsername error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	if err := h.friendshipRepo.RemoveFriend(userID, friendID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			c.JSON(http.StatusNotFound, gin.H{"error": "not friend"})
			return
		}
		log.Printf("[friend-remove] RemoveFriend error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	if h.hub != nil {
		h.hub.SendFriendRemoved(friendID, userID)
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// enrichFriendRequests 拼装请求的对方摘要。
// direction: "from" = 我收到的(对方是发起方 UserID),"to" = 我发出的(对方是接收方 FriendID)。
// 单条 GetSummaryByID 失败不影响其他条目(摘要缺失时 entry 不带 user 字段)。
func (h *FriendshipHandler) enrichFriendRequests(requests []model.Friendship, direction string) []map[string]interface{} {
	result := []map[string]interface{}{}
	for _, req := range requests {
		var otherUserID string
		if direction == "from" {
			otherUserID = req.UserID
		} else {
			otherUserID = req.FriendID
		}
		entry := map[string]interface{}{
			"request_id": req.ID,
			"status":     req.Status,
			"created_at": req.CreatedAt,
		}
		if summary, err := h.userRepo.GetSummaryByID(otherUserID); err == nil && summary != nil {
			entry["user"] = summary
		}
		result = append(result, entry)
	}
	return result
}
