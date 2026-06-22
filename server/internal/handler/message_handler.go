package handler

import (
	"encoding/json"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/hub"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

const maxBatchDelete = 100

// MessageHandler 处理消息删除请求（单删 + 批量删）。
// 删除采用软删除（messages.deleted_at）,删除后重算会话 last_message_content 缓存,
// 并通过 Hub.SendToConv 广播 MESSAGE_DELETE 给会话双端(多端同步)。
type MessageHandler struct {
	msgRepo  *repository.MessageRepo
	convRepo *repository.ConversationRepo
	hub      *hub.Hub
}

func NewMessageHandler(msgRepo *repository.MessageRepo, convRepo *repository.ConversationRepo, h *hub.Hub) *MessageHandler {
	return &MessageHandler{msgRepo: msgRepo, convRepo: convRepo, hub: h}
}

// Delete 软删单条消息。DELETE /api/messages/:id
// 权限:user 必须是会话 owner,agent 必须是该会话 agent(防越权删别人会话)。
// 删除后重算 last_message_content 缓存(删的是最后一条时),并广播 MESSAGE_DELETE。
func (h *MessageHandler) Delete(c *gin.Context) {
	id := c.Param("id")
	actorID := c.GetString("userID") // user role 是 user_id,agent role 是 agent_id
	role := c.GetString("role")

	msg, err := h.msgRepo.Get(id)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询消息失败"})
		return
	}
	if msg == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "消息不存在"})
		return
	}

	if !h.canAccess(msg.ConversationID, actorID, role) {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权操作该消息"})
		return
	}

	if err := h.msgRepo.SoftDelete(id); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除失败"})
		return
	}

	h.recalcAndBroadcast(msg.ConversationID, []string{id})
	c.Status(http.StatusNoContent)
}

// BatchDeleteRequest 批量删除请求体。
type BatchDeleteRequest struct {
	IDs []string `json:"ids" binding:"required"`
}

// BatchDelete 批量软删消息。POST /api/messages/batch-delete  body: {"ids":[...]}
// 限制:单次最多 maxBatchDelete 条;所有消息必须属于同一会话(防跨会话越权)。
func (h *MessageHandler) BatchDelete(c *gin.Context) {
	var req BatchDeleteRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}
	if len(req.IDs) == 0 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "ids 不能为空"})
		return
	}
	if len(req.IDs) > maxBatchDelete {
		c.JSON(http.StatusBadRequest, gin.H{"error": "单次最多删除 100 条"})
		return
	}

	actorID := c.GetString("userID")
	role := c.GetString("role")

	msgs, err := h.msgRepo.GetByIDs(req.IDs)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询消息失败"})
		return
	}
	if len(msgs) == 0 {
		c.JSON(http.StatusNotFound, gin.H{"error": "消息不存在"})
		return
	}

	// 所有消息必须同一会话(取第一条的 conversation_id 校验)
	convID := msgs[0].ConversationID
	for _, m := range msgs {
		if m.ConversationID != convID {
			c.JSON(http.StatusBadRequest, gin.H{"error": "批量删除的消息必须属于同一会话"})
			return
		}
	}

	if !h.canAccess(convID, actorID, role) {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权操作该会话消息"})
		return
	}

	n, err := h.msgRepo.SoftDeleteByIDs(req.IDs)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除失败"})
		return
	}

	h.recalcAndBroadcast(convID, req.IDs)
	c.JSON(http.StatusOK, gin.H{"deleted": n})
}

// canAccess 校验 actor 是否能操作该会话的消息。
// user:必须 conversations.user_id == actorID;
// agent:必须 conversations.agent_id == actorID。
// 会话不存在也返回 false(防越权)。
func (h *MessageHandler) canAccess(convID, actorID, role string) bool {
	conv, err := h.convRepo.GetByID(convID)
	if err != nil || conv == nil {
		return false
	}
	if role == "agent" {
		return conv.AgentID == actorID
	}
	return conv.UserID == actorID
}

// recalcAndBroadcast 删除后重算会话 last_message_content 缓存,并广播 MESSAGE_DELETE。
// 拆出来让单删/批删复用。广播 payload 含全部 ids,APP 端一次性移除。
func (h *MessageHandler) recalcAndBroadcast(convID string, ids []string) {
	// 重算缓存:查最新未删消息
	last, err := h.msgRepo.LastNonDeleted(convID)
	if err != nil {
		// best effort,失败不影响删除本身(下次新消息来会覆盖)
		return
	}
	if last != nil {
		_ = h.convRepo.UpdateLastMessage(convID, last.Content)
	} else {
		// 全删完:用 ClearLastMessage 显式写 NULL。
		// 不用 UpdateLastMessage(convID, nil) —— database/sql 对 []byte(nil) 的行为不确定,
		// 专用方法 UPDATE SET last_message_content = NULL 语义最明确。
		_ = h.convRepo.ClearLastMessage(convID)
	}

	// 广播 MESSAGE_DELETE 给会话双端
	conv, err := h.convRepo.GetByID(convID)
	if err != nil || conv == nil {
		return
	}
	payload, _ := json.Marshal(map[string]interface{}{
		"ids":             ids,
		"conversation_id": convID,
	})
	msg := &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageDelete,
		D:  payload,
	}
	h.hub.SendToConv(conv.UserID, conv.AgentID, msg)
}
