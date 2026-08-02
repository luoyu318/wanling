package handler

import (
	"context"
	"database/sql"
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/hub"
	logpkg "github.com/wanling/server/internal/log"
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
//   - DELETE /api/users/me/friends/:username        (RemoveFriend)
//
// 关键设计:
//   - 加好友 body 用 to_username(不暴露 user_id 到 client);server 用 GetIDByUsername 反查。
//   - WS 通知在 DB 操作成功后才推,避免 DB 失败但通知已发。
//   - ListFriends / ListIncoming / ListOutgoing 用 BatchGetSummaryByID 批量取摘要。
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
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	// username → user_id 反查
	toUserID, err := h.userRepo.GetIDByUsername(c.Request.Context(), req.ToUsername)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			Err(c, http.StatusNotFound, "not_found", "user not found")
			return
		}
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "friend-request GetIDByUsername 失败", "username", req.ToUsername, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	// 不能加自己为好友
	if toUserID == fromUserID {
		Err(c, http.StatusBadRequest, "bad_request", "cannot friend yourself")
		return
	}

	// 双向校验在 repo 层 CreateRequest 内完成（from≠to + 已有关系检查）
	friendship, err := h.friendshipRepo.CreateRequest(c.Request.Context(), fromUserID, toUserID)
	if err != nil {
		if errors.Is(err, repository.ErrFriendshipAlreadyExists) {
			Err(c, http.StatusConflict, "invalid_state", "friendship already exists")
			return
		}
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "friend-request CreateRequest 失败", "from_user_id", fromUserID, "to_user_id", toUserID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	// 取双方 user 摘要:from 摘要用于通知接收方(让其知道谁加的他),
	// to 摘要用于响应给发起方(确认请求的对象)。
	fromSummary, err := h.userRepo.GetSummaryByID(c.Request.Context(), fromUserID)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "friend-request GetSummaryByID from 失败", "user_id", fromUserID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	toSummary, err := h.userRepo.GetSummaryByID(c.Request.Context(), toUserID)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "friend-request GetSummaryByID to 失败", "user_id", toUserID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
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

	Ok(c, gin.H{
		"request_id": friendship.ID,
		"status":     friendship.Status,
		"to_user":    toSummary, // 接收方摘要(不含 id,防泄漏)
	})
}

// ListIncoming GET /api/users/me/friend-requests/incoming
// 返回我收到的 pending 请求,按 created_at DESC 排序,带发起方摘要。
func (h *FriendshipHandler) ListIncoming(c *gin.Context) {
	userID := c.GetString("userID")
	requests, err := h.friendshipRepo.ListIncomingRequests(c.Request.Context(), userID)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "friend-incoming ListIncomingRequests 失败", "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	result := h.enrichFriendRequests(c.Request.Context(), requests, "from")
	Ok(c, result)
}

// ListOutgoing GET /api/users/me/friend-requests/outgoing
// 返回我发出的 pending 请求,按 created_at DESC 排序,带接收方摘要。
func (h *FriendshipHandler) ListOutgoing(c *gin.Context) {
	userID := c.GetString("userID")
	requests, err := h.friendshipRepo.ListOutgoingRequests(c.Request.Context(), userID)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "friend-outgoing ListOutgoingRequests 失败", "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	result := h.enrichFriendRequests(c.Request.Context(), requests, "to")
	Ok(c, result)
}

// ListFriends GET /api/users/me/friends
// 返回我的 accepted 好友列表(摘要,不含 id 由 UserSummary 自身约束)。
func (h *FriendshipHandler) ListFriends(c *gin.Context) {
	userID := c.GetString("userID")
	friendIDs, err := h.friendshipRepo.ListFriends(c.Request.Context(), userID)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "friend-list ListFriends 失败", "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	friends := []model.UserSummary{}
	if len(friendIDs) > 0 {
		summaries, err := h.userRepo.BatchGetSummaryByID(c.Request.Context(), friendIDs)
		if err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "friend-list BatchGetSummaryByID 失败", "user_id", userID, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "服务器错误")
			return
		}
		for _, id := range friendIDs {
			if s, ok := summaries[id]; ok && s != nil {
				friends = append(friends, *s)
			}
		}
	}
	Ok(c, friends)
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
	if err := h.friendshipRepo.Cancel(c.Request.Context(), requestID, userID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			Err(c, http.StatusNotFound, "not_found", "request not found or not pending")
			return
		}
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "friend-cancel Cancel 失败", "request_id", requestID, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	// Cancel 由发起方操作,通知接收方
	req, err := h.friendshipRepo.GetByID(c.Request.Context(), requestID)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "friend-cancel GetByID 失败", "request_id", requestID, "err", err)
	} else if req != nil && h.hub != nil {
		h.hub.SendFriendRequestDecided(req.FriendID, requestID, "canceled", userID)
	}
	Ok(c, nil)
}

// decide 是 Accept/Reject 的共享实现(都由接收方操作)。
// newState: accepted / rejected。成功后通知发起方(user_id)。
func (h *FriendshipHandler) decide(c *gin.Context, newState string) {
	userID := c.GetString("userID")
	requestID := c.Param("id")

	var err error
	if newState == "accepted" {
		err = h.friendshipRepo.Accept(c.Request.Context(), requestID, userID)
	} else {
		err = h.friendshipRepo.Reject(c.Request.Context(), requestID, userID)
	}
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			Err(c, http.StatusNotFound, "not_found", "request not found or not pending")
			return
		}
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "friend-decide 状态推进失败", "new_state", newState, "request_id", requestID, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	// Accept/Reject 由接收方操作,通知发起方(user_id)
	req, err := h.friendshipRepo.GetByID(c.Request.Context(), requestID)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "friend-decide GetByID 失败", "request_id", requestID, "err", err)
	} else if req != nil && h.hub != nil {
		h.hub.SendFriendRequestDecided(req.UserID, requestID, newState, userID)
	}
	Ok(c, nil)
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
		Err(c, http.StatusBadRequest, "bad_request", "username required")
		return
	}
	friendID, err := h.userRepo.GetIDByUsername(c.Request.Context(), friendUsername)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			Err(c, http.StatusNotFound, "not_found", "user not found")
			return
		}
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "friend-remove GetIDByUsername 失败", "username", friendUsername, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if err := h.friendshipRepo.RemoveFriend(c.Request.Context(), userID, friendID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			Err(c, http.StatusNotFound, "not_found", "not friend")
			return
		}
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "friend-remove RemoveFriend 失败", "user_id", userID, "friend_id", friendID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if h.hub != nil {
		h.hub.SendFriendRemoved(friendID, userID)
	}
	Ok(c, nil)
}

// enrichFriendRequests 拼装请求的对方摘要。
// direction: "from" = 我收到的(对方是发起方 UserID),"to" = 我发出的(对方是接收方 FriendID)。
// 批量查摘要，单条缺失时 entry 不带 user 字段。
func (h *FriendshipHandler) enrichFriendRequests(ctx context.Context, requests []model.Friendship, direction string) []map[string]interface{} {
	result := []map[string]interface{}{}
	ids := make([]string, 0, len(requests))
	for _, req := range requests {
		if direction == "from" {
			ids = append(ids, req.UserID)
		} else {
			ids = append(ids, req.FriendID)
		}
	}
	summaries := map[string]*model.UserSummary{}
	if len(ids) > 0 {
		if s, err := h.userRepo.BatchGetSummaryByID(ctx, ids); err == nil {
			summaries = s
		}
	}
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
		if summary, ok := summaries[otherUserID]; ok && summary != nil {
			entry["user"] = summary
		}
		result = append(result, entry)
	}
	return result
}
