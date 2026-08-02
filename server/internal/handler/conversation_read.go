package handler

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/model"
)

// MarkMessagesRead 批量按 messageId 标记已读 + 重算 unread_count。
// 用于"用户上滑阅读未读消息时按 messageId 同步进度"。
//
// Request body: {"message_ids": ["id1", "id2", ...]}
// Response: {"ok": true, "unread_count": N}
//
// 越权 / 非 participant:MarkMessagesReadTx 返 sql.ErrNoRows,handler 转 403。
func (h *ConversationHandler) MarkMessagesRead(c *gin.Context) {
	convID := c.Param("id")
	userID := c.GetString("userID")

	var req struct {
		MessageIDs []string `json:"message_ids" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", "message_ids 字段必填")
		return
	}

	// 防御性上限:单次最多 100 条(与 batch-delete 一致)
	if len(req.MessageIDs) > 100 {
		Err(c, http.StatusBadRequest, "bad_request", "单次最多 100 条 message_ids")
		return
	}

	tx, err := h.db.BeginTx(c.Request.Context(), nil)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "mark-msgs-read Begin 失败", "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	defer tx.Rollback()

	newUnread, err := h.participantRepo.MarkMessagesReadTx(c.Request.Context(), tx, convID, userID, "user", req.MessageIDs)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			Err(c, http.StatusForbidden, "forbidden", "not a participant")
			return
		}
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "mark-msgs-read MarkMessagesReadTx 失败", "conv_id", convID, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	if err := tx.Commit(); err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "mark-msgs-read Commit 失败", "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	// 多端同步:广播 MESSAGE_READ 给该 user 全部 WS 连接(B 设备立即刷徽章 + ChatPage)。
	// 含 sender 自己(client 按 message_ids 去重已读消息避免重复处理)。
	h.broadcastMessageRead(userID, convID, req.MessageIDs, newUnread)

	Ok(c, gin.H{"unread_count": newUnread})
}

// MarkRead 整会话标已读:取该 user 在该 conv 所有未读 message_ids,
// 转走 MarkMessagesReadTx 批量标已读 + 重算 unread_count。
//
// 用于"用户进入 ChatPage 时调一次"和"老 APP 兼容"。
// 越权 / 非 participant:返 403(与 MarkMessagesRead 一致)。
func (h *ConversationHandler) MarkRead(c *gin.Context) {
	convID := c.Param("id")
	userID := c.GetString("userID")

	tx, err := h.db.BeginTx(c.Request.Context(), nil)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "mark-read Begin 失败", "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	defer tx.Rollback()

	// 取该 user 在该 conv 所有未读 message_ids(read_at IS NULL AND deleted_at IS NULL)
	msgIDs, err := h.deliveryRepo.ListUnreadMessageIDsByConv(c.Request.Context(), tx, convID, userID, "user")
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "mark-read ListUnreadMessageIDsByConv 失败", "conv_id", convID, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	newUnread, err := h.participantRepo.MarkMessagesReadTx(c.Request.Context(), tx, convID, userID, "user", msgIDs)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			Err(c, http.StatusForbidden, "forbidden", "not a participant")
			return
		}
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "mark-read MarkMessagesReadTx 失败", "conv_id", convID, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	if err := tx.Commit(); err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "mark-read Commit 失败", "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	// 多端同步:广播 MESSAGE_READ 给该 user 全部 WS 连接(B 设备立即刷徽章 + ChatPage)。
	// 含 sender 自己(client 按 message_ids 去重已读消息避免重复处理)。
	h.broadcastMessageRead(userID, convID, msgIDs, newUnread)

	Ok(c, gin.H{"unread_count": newUnread})
}

// broadcastMessageRead 广播 MESSAGE_READ 给该 user 全部 WS 连接。
// 用于多端同步:A 设备 markRead 后,B 设备立即收到 → 刷徽章 + 当前 ChatPage 的 firstUnread。
// 含 sender 自己的连接(client 按 message_ids 去重避免重复处理)。
// 不广播给其他 user / agent(已读是个人维度)。
// hub=nil 时跳过(单元测试无 hub 注入场景),不阻塞主流程。
func (h *ConversationHandler) broadcastMessageRead(userID, convID string, messageIDs []string, newUnread int) {
	if h.hub == nil {
		return
	}
	payload, _ := json.Marshal(map[string]interface{}{
		"conversation_id": convID,
		"message_ids":     messageIDs,
		"unread_count":    newUnread,
		"read_at":         time.Now().UTC().Format(time.RFC3339),
	})
	msg := &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageRead,
		S:  h.hub.NextSeq(),
		D:  payload,
	}
	if err := h.hub.SendToUser(userID, msg); err != nil {
		logpkg.FromCtx(context.Background()).WarnContext(context.Background(),
			"MESSAGE_READ 广播失败", "conv_id", convID, "user_id", userID, "err", err)
	}
}

// UnreadInfo 返回会话的未读信息:未读数 + 第一条未读消息的 ID 与 created_at。
// GET /api/conversations/:id/unread
// 用于 APP 进入会话时定位第一条未读消息。
//
// 越权 / 非 participant:返 403(与新版权限语义对齐)。
func (h *ConversationHandler) UnreadInfo(c *gin.Context) {
	convID := c.Param("id")
	userID := c.GetString("userID")

	ok, err := h.participantRepo.Exists(c.Request.Context(), convID, userID, "user")
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "unread Exists 失败", "conv_id", convID, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if !ok {
		Err(c, http.StatusForbidden, "forbidden", "not a participant")
		return
	}

	// 未读数从 participant 行取(participants 模型重构后,unread_count 在 participant 表)
	p, err := h.participantRepo.Get(c.Request.Context(), convID, userID, "user")
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "unread Get participant 失败", "conv_id", convID, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "查询未读数失败")
		return
	}
	if p == nil {
		// Exists 通过 → Get 也能拿到,理论上不会到这分支
		Err(c, http.StatusForbidden, "forbidden", "not a participant")
		return
	}
	unreadCount := p.UnreadCount

	// 首条未读走 DeliveryRepo.FirstUnread(已下沉,过滤软删 + 该 user 隐藏过的消息)
	firstUnreadID := ""
	var firstUnreadCreatedAt *time.Time
	hasMoreBeforeFirstUnread := false
	if unreadCount > 0 {
		m, err := h.deliveryRepo.FirstUnread(c.Request.Context(), convID, userID, "user")
		if err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "unread FirstUnread 失败", "conv_id", convID, "user_id", userID, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "查询未读消息失败")
			return
		}
		if m != nil {
			firstUnreadID = m.ID
			firstUnreadCreatedAt = &m.CreatedAt

			// 仅在有未读时查 firstUnread 之前的消息数(无未读时此字段无意义)
			countBefore, err := h.messageRepo.CountBefore(c.Request.Context(), convID, userID, "user", m.CreatedAt)
			if err != nil {
				logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "unread CountBefore 失败", "conv_id", convID, "user_id", userID, "err", err)
				ErrMsg(c, http.StatusInternalServerError, "查询历史消息数失败")
				return
			}
			hasMoreBeforeFirstUnread = countBefore > 0
		}
	}

	Ok(c, gin.H{
		"unread_count":                 unreadCount,
		"first_unread_message_id":      firstUnreadID,
		"first_unread_created_at":      firstUnreadCreatedAt,
		"has_more_before_first_unread": hasMoreBeforeFirstUnread,
	})
}
