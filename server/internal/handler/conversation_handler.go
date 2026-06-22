package handler

import (
	"database/sql"
	"errors"
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// ConversationHandler 处理会话相关的 HTTP 请求。
// agentRepo 用于 FindOrCreate 时返回对端 Agent 详情（避免 APP 端再发一次查询）。
type ConversationHandler struct {
	convRepo    *repository.ConversationRepo
	messageRepo *repository.MessageRepo
	agentRepo   *repository.AgentRepo
}

// NewConversationHandler 构造 ConversationHandler。
// agentRepo 用于 FindOrCreate 时返回对端 Agent 详情，供 APP 端 ChatPage 直接使用。
func NewConversationHandler(convRepo *repository.ConversationRepo, messageRepo *repository.MessageRepo, agentRepo *repository.AgentRepo) *ConversationHandler {
	return &ConversationHandler{convRepo: convRepo, messageRepo: messageRepo, agentRepo: agentRepo}
}

// List 返回当前用户的 IM 风格会话列表（含对端 agent 详情 + 最后一条消息预览）。
// 只返回有消息的会话（IM 列表语义：空会话不展示）。
// 空列表返回 [] 而非 null，避免 APP 端反序列化报错。
func (h *ConversationHandler) List(c *gin.Context) {
	userID := c.GetString("userID")
	items, err := h.convRepo.ListWithAgent(userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}
	if items == nil {
		items = []model.ConversationListItem{}
	}
	c.JSON(http.StatusOK, items)
}

// FindOrCreateRequest 是 POST /api/conversations 的请求体。
type FindOrCreateRequest struct {
	AgentID string `json:"agent_id" binding:"required"`
}

// FindOrCreate 按 (user_id, agent_id) 获取会话；不存在则创建。
// 返回的 JSON 包含完整 agent 详情，便于 ChatPage 改造后直接从返回里拿 agent 信息。
func (h *ConversationHandler) FindOrCreate(c *gin.Context) {
	var req FindOrCreateRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	userID := c.GetString("userID")

	// 顺序很关键：必须先验证 agent 存在再 FindOrCreate。
	// conversations.agent_id 对 agents.id 有 FK + ON DELETE CASCADE 约束
	// （见 migrations/001_init.sql 第 4 行）。若先调 FindOrCreate 而 agent 不存在，
	// INSERT 会因 FK 约束失败返回 error，handler 会走 500 分支，404 分支永远不可达。
	// 先 GetByID 才能让 agent 不存在时真正返回 404（fail fast）。
	// GetByID 在 agent 不存在时返回 (nil, nil)，需单独处理 404。
	agent, err := h.agentRepo.GetByID(req.AgentID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询 agent 失败"})
		return
	}
	if agent == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "agent 不存在"})
		return
	}

	conv, err := h.convRepo.FindOrCreate(userID, req.AgentID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建会话失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"id":                   conv.ID,
		"agent":                agent,
		"last_message_content": conv.LastMessageContent,
		"last_message_at":      conv.LastMessageAt,
		"created_at":           conv.CreatedAt,
	})
}

// Messages 分页返回指定会话的历史消息。
func (h *ConversationHandler) Messages(c *gin.Context) {
	id := c.Param("id")
	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "50"))
	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))

	msgs, err := h.messageRepo.ListByConversation(id, limit, offset)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}
	if msgs == nil {
		msgs = []model.Message{}
	}
	c.JSON(http.StatusOK, msgs)
}

// MarkRead 用户标记会话已读：unread_count 清零。
// 用于"用户进入 ChatPage 时调一次"。
// 越权防护：user_id 必须匹配，否则 404（不区分"会话不存在"和"无权访问"，避免泄露存在性）。
func (h *ConversationHandler) MarkRead(c *gin.Context) {
	convID := c.Param("id")
	userID := c.GetString("userID")

	if err := h.convRepo.MarkRead(convID, userID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			c.JSON(http.StatusNotFound, gin.H{"error": "会话不存在或无权访问"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// Pin 置顶会话。越权防护:user_id 必须匹配,否则 404。
func (h *ConversationHandler) Pin(c *gin.Context) {
	convID := c.Param("id")
	userID := c.GetString("userID")

	if err := h.convRepo.Pin(convID, userID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			c.JSON(http.StatusNotFound, gin.H{"error": "会话不存在或无权访问"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// Unpin 取消置顶。
func (h *ConversationHandler) Unpin(c *gin.Context) {
	convID := c.Param("id")
	userID := c.GetString("userID")

	if err := h.convRepo.Unpin(convID, userID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			c.JSON(http.StatusNotFound, gin.H{"error": "会话不存在或无权访问"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// Hide 软删除会话(列表不显示,聊天记录保留,新消息自动恢复)。
func (h *ConversationHandler) Hide(c *gin.Context) {
	convID := c.Param("id")
	userID := c.GetString("userID")

	if err := h.convRepo.Hide(convID, userID); err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			c.JSON(http.StatusNotFound, gin.H{"error": "会话不存在或无权访问"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}
