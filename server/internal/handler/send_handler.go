package handler

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/message"
)

// SendRequest POST /api/messages 请求体。
//
// conversation_id 必须是已存在的会话(由 APP 端先通过 FindOrCreate / 群聊创建 API 建立),
// handler 不负责建会话,只做 participant 校验。content 是消息内容 JSON,需含 msg_type。
type SendRequest struct {
	ConversationID string          `json:"conversation_id" binding:"required"`
	Content        json.RawMessage `json:"content" binding:"required"`
}

// SendHandler 处理 user 发送消息的 HTTP 同步接口。
//
// 与老 WS 路径不同:HTTP 同步返 server message_id,client 端可立即用 server id
// 替换 local 临时 id,撤回/编辑无 ID 不同步问题。
//
// 内部复用 MessageProcessor.PersistAndDispatch(事务内 CreateTx + IncrUnreadTx + dispatch)。
type SendHandler struct {
	processor *message.Processor
}

// NewSendHandler 构造 SendHandler,processor 由 main.go 注入(与 ws_handler 共用同一实例)。
func NewSendHandler(processor *message.Processor) *SendHandler {
	return &SendHandler{processor: processor}
}

// Send POST /api/messages
//
// 鉴权:userAuth 组(仅 user role)。agent 沿用 WS 路径,本期不动。
//
// 响应:
//   - 200 OK → {message_id, created_at}
//   - 400     → content 格式错(非 JSON object / 缺 msg_type)
//   - 403     → 非 participant(越权 / 会话不存在 / 已退群)
//   - 500     → 内部错误(DB / 事务失败)
//
// 成功后 server 同时 dispatch MESSAGE_CREATE 给所有 participants(含 sender 自身多端 echo),
// APP 端 chatProvider 按 message_id 去重,本地乐观消息会被 server id 替换。
func (h *SendHandler) Send(c *gin.Context) {
	userID := c.GetString("userID")

	var req SendRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// content 必须是合法 JSON object(含 msg_type 字段)
	// 防御层:WS 路径的 enhanceImageContent / CreateTx 也会读 content,前置校验
	// 让非法请求在 400 早退,避免落到事务里失败时返 500 误导 client。
	var contentCheck map[string]interface{}
	if err := json.Unmarshal(req.Content, &contentCheck); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "content 必须是 JSON object"})
		return
	}
	if _, ok := contentCheck["msg_type"]; !ok {
		c.JSON(http.StatusBadRequest, gin.H{"error": "content.msg_type 必填"})
		return
	}

	msg, err := h.processor.PersistAndDispatch(req.ConversationID, "user", userID, req.Content)
	if err != nil {
		if errors.Is(err, message.ErrNotParticipant) {
			c.JSON(http.StatusForbidden, gin.H{"error": "not a participant"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": err.Error()})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"message_id": msg.ID,
		"created_at": msg.CreatedAt,
	})
}
