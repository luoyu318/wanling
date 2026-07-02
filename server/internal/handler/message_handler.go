package handler

import (
	"encoding/json"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/hub"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

const (
	maxBatchDelete = 100

	// recallWindow 撤回时间窗口(自己发的消息超过此时限不可撤回,只能 hide)。
	// 对齐主流 IM 约定(微信 2min,本项目按用户决策设 5min)。
	recallWindow = 5 * time.Minute
)

// MessageHandler 处理消息删除请求(单删 + 批量删)。
//
// 双轨制语义(见 migration 016):
//   - scope=hide (默认):对自己隐藏(per-participant 维度,单向不可见)
//     → 调 msgRepo.HideForUser,单播 MESSAGE_DELETE 给当前请求者
//   - scope=recall:撤回(全局软删,双向不可见),仅自己发的 + recallWindow 内
//     → 调 msgRepo.SoftDelete,广播 MESSAGE_DELETE 给会话全员
//
// 撤回广播 payload 含 scope='recall' + sender_id + sender_name,client 据此显示
// "你撤回了一条消息" / "对方撤回了一条消息" / 群聊场景 "${name} 撤回了一条消息"。
type MessageHandler struct {
	msgRepo         *repository.MessageRepo
	convRepo        *repository.ConversationRepo
	participantRepo *repository.ParticipantRepo
	userRepo        *repository.UserRepo
	agentRepo       *repository.AgentRepo
	hub             *hub.Hub
}

func NewMessageHandler(
	msgRepo *repository.MessageRepo, convRepo *repository.ConversationRepo,
	participantRepo *repository.ParticipantRepo,
	userRepo *repository.UserRepo, agentRepo *repository.AgentRepo,
	h *hub.Hub,
) *MessageHandler {
	return &MessageHandler{
		msgRepo:         msgRepo,
		convRepo:        convRepo,
		participantRepo: participantRepo,
		userRepo:        userRepo,
		agentRepo:       agentRepo,
		hub:             h,
	}
}

// Delete 软删/隐藏单条消息。DELETE /api/messages/:id?scope=hide|recall
//
// scope=hide (默认):对自己隐藏。
//   - 权限:必须是 participant
//   - 副作用:不重算 last_message_content(个人视图,IM 列表预览不变)
//   - 广播:单播 MESSAGE_DELETE 给当前请求者(只对我消失)
//
// scope=recall:撤回(对自己 + 对方都不可见)。
//   - 权限:必须是 sender 本身
//   - 时限:created_at + recallWindow > now
//   - 副作用:重算 last_message_content(影响全员 IM 列表预览)
//   - 广播:广播 MESSAGE_DELETE 给会话全员,payload 含 scope=recall + sender 信息
func (h *MessageHandler) Delete(c *gin.Context) {
	id := c.Param("id")
	actorID := c.GetString("userID")
	role := c.GetString("role") // user|agent
	scope := c.DefaultQuery("scope", "hide")

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

	switch scope {
	case "recall":
		// 撤回权限:必须是 sender 本身
		if msg.SenderID != actorID || msg.SenderType != role {
			c.JSON(http.StatusForbidden, gin.H{"error": "只能撤回自己发的消息"})
			return
		}
		// 撤回时限
		if time.Since(msg.CreatedAt) > recallWindow {
			c.JSON(http.StatusConflict, gin.H{"error": "超过 5 分钟不可撤回"})
			return
		}
		if err := h.msgRepo.SoftDelete(id); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "撤回失败"})
			return
		}
		h.recalcAndBroadcastRecall(msg)

	case "hide", "":
		if err := h.msgRepo.HideForUser(id, actorID, role); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "删除失败"})
			return
		}
		// hide 不重算 last_message_content(IM 列表预览不变,只是个人视图)
		h.unicastHide(actorID, role, msg.ConversationID, []string{id})

	default:
		c.JSON(http.StatusBadRequest, gin.H{"error": "scope 参数非法,应为 hide|recall"})
	}

	c.Status(http.StatusNoContent)
}

// BatchDeleteRequest 批量删除请求体。
type BatchDeleteRequest struct {
	IDs []string `json:"ids" binding:"required"`
}

// BatchDelete 批量隐藏消息。POST /api/messages/batch-delete  body: {"ids":[...]}
//
// 仅支持 scope=hide(批量撤回歧义太大,本期不开)。
// 限制:单次最多 maxBatchDelete 条;所有消息必须属于同一会话(防跨会话越权)。
//
// 副作用:不重算 last_message_content(个人视图)。单播 MESSAGE_DELETE 给当前请求者。
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

	n, err := h.msgRepo.HideForUsers(req.IDs, actorID, role)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除失败"})
		return
	}

	h.unicastHide(actorID, role, convID, req.IDs)
	c.JSON(http.StatusOK, gin.H{"deleted": n})
}

// canAccess 校验 actor 是否为该会话 participant。
// 会话/参与者不存在都返 false(防越权)。
func (h *MessageHandler) canAccess(convID, actorID, role string) bool {
	ok, err := h.participantRepo.Exists(convID, actorID, role)
	if err != nil {
		return false
	}
	return ok
}

// senderDisplay 查 sender 昵称:user 走 userRepo (nickname||username),agent 走 agentRepo (name)。
// 查询失败返空串(client 端会用 sender_id fallback 占位),不阻塞撤回流程。
func (h *MessageHandler) senderDisplay(senderID, senderType string) string {
	if senderType == "agent" {
		a, err := h.agentRepo.GetByID(senderID)
		if err != nil || a == nil {
			return ""
		}
		return a.Name
	}
	u, err := h.userRepo.GetByID(senderID)
	if err != nil || u == nil {
		return ""
	}
	if u.Nickname != nil && *u.Nickname != "" {
		return *u.Nickname
	}
	return u.Username
}

// recalcAndBroadcastRecall 撤回后重算 last_message_content 缓存,广播 MESSAGE_DELETE 给全员。
// payload 含 scope='recall' + sender 信息,client 据此显示撤回占位。
func (h *MessageHandler) recalcAndBroadcastRecall(msg *model.Message) {
	// 重算缓存:查最新未删消息
	last, err := h.msgRepo.LastNonDeleted(msg.ConversationID)
	if err != nil {
		return
	}
	if last != nil {
		_ = h.convRepo.UpdateLastMessage(msg.ConversationID, last.Content)
	} else {
		_ = h.convRepo.ClearLastMessage(msg.ConversationID)
	}

	hubMsg := h.buildDeleteMsg(msg.ConversationID, []string{msg.ID}, "recall", msg.SenderID, msg.SenderType)
	h.hub.SendToConv(msg.ConversationID, hubMsg)
}

// unicastHide 把 hide scope 的 MESSAGE_DELETE 单播给当前请求者(只对我消失)。
// payload 不含 sender 信息(hide 不需要撤回占位文案)。
func (h *MessageHandler) unicastHide(memberID, memberType, convID string, ids []string) {
	hubMsg := h.buildDeleteMsg(convID, ids, "hide", "", "")
	h.hub.SendToMember(memberID, memberType, hubMsg)
}

// buildDeleteMsg 构造 MESSAGE_DELETE 广播 payload。
// scope=recall 时填 sender_id/sender_type/sender_name;scope=hide 时这三字段为空。
func (h *MessageHandler) buildDeleteMsg(convID string, ids []string, scope, senderID, senderType string) *model.WSMessage {
	payload := map[string]interface{}{
		"ids":             ids,
		"conversation_id": convID,
		"scope":           scope,
	}
	if scope == "recall" {
		payload["sender_id"] = senderID
		payload["sender_type"] = senderType
		payload["sender_name"] = h.senderDisplay(senderID, senderType)
	}
	data, _ := json.Marshal(payload)
	return &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageDelete,
		D:  data,
	}
}
