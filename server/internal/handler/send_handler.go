package handler

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/message"
)

// SendRequest POST /api/messages 请求体。
//
// conversation_id 必须是已存在的会话(由 APP 端先通过 FindOrCreate / 群聊创建 API 建立),
// handler 不负责建会话,只做 participant 校验。content 是消息内容 JSON,需含 msg_type。
//
// 不暴露 ParentMsgID / RootMsgID 顶层字段:user 路径不应能创建子 agent 事件
// (parent/root 是 agent/plugin 专属能力,且 user 路径不调用 ExtractParentRoot,
// 顶层透传会让 user 消息被主列表 parent_msg_id IS NULL 过滤掉,消失于主聊天)。
// agent 路径走 SendAsAgent,需在 content 内带 parent_msg_id/root_msg_id。
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
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	// content 必须是合法 JSON object(含 msg_type 字段)
	// 防御层:WS 路径的 enhanceImageContent / CreateTx 也会读 content,前置校验
	// 让非法请求在 400 早退,避免落到事务里失败时返 500 误导 client。
	var contentCheck map[string]interface{}
	if err := json.Unmarshal(req.Content, &contentCheck); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", "content 必须是 JSON object")
		return
	}
	if _, ok := contentCheck["msg_type"]; !ok {
		Err(c, http.StatusBadRequest, "bad_request", "content.msg_type 必填")
		return
	}

	msg, err := h.processor.PersistAndDispatch(c.Request.Context(), req.ConversationID, "user", userID, req.Content, nil, nil)
	if err != nil {
		if errors.Is(err, message.ErrNotParticipant) {
			Err(c, http.StatusForbidden, "forbidden", "not a participant")
			return
		}
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "send PersistAndDispatch 失败",
			"conv_id", req.ConversationID, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	Ok(c, gin.H{
		"message_id": msg.ID,
		"created_at": msg.CreatedAt,
	})
}

// agentSendRequest POST /api/conversations/:id/messages 请求体(agentAuth 组)。
//
// 与 SendRequest 区别:conversation_id 走 URL path 不在 body,故独立 struct。
// 复用 SendRequest 会因 binding:"required" 强求 body 带 conversation_id,与路由设计冲突。
type agentSendRequest struct {
	Content     json.RawMessage `json:"content" binding:"required"`
	ParentMsgID *string         `json:"parent_msg_id,omitempty"`
	RootMsgID   *string         `json:"root_msg_id,omitempty"`
}

// SendAsAgent POST /api/conversations/:id/messages (agentAuth 组)
//
// agent 通过 REST 发消息,复用 PersistAndDispatch,与 WS MESSAGE_CREATE 路径等价。
// 区别:REST 同步返 message_id,plugin 用此端点发交互卡片(permission_card / question_card),
// 拿到 message_id 存本地 card_store 追踪卡片↔OpenCode-request 映射,后续 PATCH 状态用。
//
// agentAuth 中间件写入的 userID context key 实际是 agent_id(JWT sub),变量名沿用既有约定。
//
// 响应:
//   - 200 OK → {message_id, created_at}
//   - 400     → content 格式错(非 JSON object / 缺 msg_type)
//   - 403     → 非 participant(越权 / 会话不存在 / 已退群)
//   - 500     → 内部错误(DB / 事务失败)
//
// 成功后 server 同时 dispatch MESSAGE_CREATE 给所有 participants(含 sender 自身多端 echo)。
func (h *SendHandler) SendAsAgent(c *gin.Context) {
	agentID := c.GetString("userID") // agentAuth 写入的 userID 实际是 agent_id
	convID := c.Param("id")

	var req agentSendRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	// content 必须是合法 JSON object(含 msg_type 字段)。
	// 与 Send 一致的前置校验,非法请求早退避免落事务返 500 误导 client。
	var contentCheck map[string]interface{}
	if err := json.Unmarshal(req.Content, &contentCheck); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", "content 必须是 JSON object")
		return
	}
	if _, ok := contentCheck["msg_type"]; !ok {
		Err(c, http.StatusBadRequest, "bad_request", "content.msg_type 必填")
		return
	}

	// 从 content 提取 parent_msg_id/root_msg_id(plugin HTTP 路径透传,子 agent 事件用)。
	// 与 HandleIncoming(WS) 对称使用 ExtractParentRoot,两条路径行为一致。
	// content 内无值时回退顶层 agentSendRequest 字段(向后兼容旧 caller)。
	parentMsgID, rootMsgID, cleanedContent := message.ExtractParentRoot(req.Content)
	req.Content = cleanedContent
	if parentMsgID == nil {
		parentMsgID = req.ParentMsgID
	}
	if rootMsgID == nil {
		rootMsgID = req.RootMsgID
	}

	msg, err := h.processor.PersistAndDispatch(c.Request.Context(), convID, "agent", agentID, req.Content, parentMsgID, rootMsgID)
	if err != nil {
		if errors.Is(err, message.ErrNotParticipant) {
			Err(c, http.StatusForbidden, "forbidden", "not a participant")
			return
		}
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "sendAsAgent PersistAndDispatch 失败",
			"conv_id", convID, "agent_id", agentID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}

	Ok(c, gin.H{
		"message_id": msg.ID,
		"created_at": msg.CreatedAt,
	})
}
