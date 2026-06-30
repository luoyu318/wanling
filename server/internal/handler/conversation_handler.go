package handler

import (
	"database/sql"
	"errors"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// ConversationHandler 处理会话相关的 HTTP 请求。
// agentRepo 用于 FindOrCreate 时返回对端 Agent 详情（避免 APP 端再发一次查询）。
// userRepo 用于 FindOrCreateAsAgent 时校验对端 user 存在并返回 user 详情。
type ConversationHandler struct {
	convRepo    *repository.ConversationRepo
	messageRepo *repository.MessageRepo
	agentRepo   *repository.AgentRepo
	userRepo    *repository.UserRepo
}

// NewConversationHandler 构造 ConversationHandler。
// agentRepo 用于 FindOrCreate 时返回对端 Agent 详情，供 APP 端 ChatPage 直接使用。
// userRepo 用于 FindOrCreateAsAgent 时校验 user 存在并返回 user 详情。
func NewConversationHandler(convRepo *repository.ConversationRepo, messageRepo *repository.MessageRepo, agentRepo *repository.AgentRepo, userRepo *repository.UserRepo) *ConversationHandler {
	return &ConversationHandler{
		convRepo:    convRepo,
		messageRepo: messageRepo,
		agentRepo:   agentRepo,
		userRepo:    userRepo,
	}
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

// FindOrCreateAsAgentRequest 是 POST /api/agents/me/conversations 的请求体。
type FindOrCreateAsAgentRequest struct {
	UserID string `json:"user_id" binding:"required"`
}

// FindOrCreateAsAgent agent 视角的 FindOrCreate：按 (agent_id, user_id) 获取会话；
// 不存在则创建。agent_id 从 JWT 拿（c.GetString("userID") 在 agent role 时是 agent_id）。
//
// 用于 agent 主动发起会话相关操作（如审批卡片），无需 user 先发消息建立缓存。
// 跟 FindOrCreate 对称：那个是 user 发起（user_id 从 JWT，agent_id 在 body），
// 这个是 agent 发起（agent_id 从 JWT，user_id 在 body）。
//
// 路由挂在 agentAuth 组（AuthMiddleware 已挡 user role），故 handler 内不再重复校验 role。
func (h *ConversationHandler) FindOrCreateAsAgent(c *gin.Context) {
	var req FindOrCreateAsAgentRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	agentID := c.GetString("userID")

	// 顺序很关键：必须先验证 user 存在再 FindOrCreate。
	// conversations.user_id 对 users.id 有 FK + ON DELETE CASCADE 约束
	// （见 migrations/001_init.sql）。若先调 FindOrCreate 而 user 不存在，
	// INSERT 会因 FK 约束失败返回 error，handler 走 500 分支，404 分支永远不可达。
	// 先 GetByID 才能让 user 不存在时真正返回 404（fail fast）。
	user, err := h.userRepo.GetByID(req.UserID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询 user 失败"})
		return
	}
	if user == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user 不存在"})
		return
	}

	conv, err := h.convRepo.FindOrCreate(req.UserID, agentID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建会话失败"})
		return
	}

	// 返回 conv + user 详情（agent 端可能需要 user 名字显示）。
	// 注意：model.User 的 PasswordHash 字段带 json:"-" tag，不会泄露到响应里。
	c.JSON(http.StatusOK, gin.H{
		"id":         conv.ID,
		"user_id":    conv.UserID,
		"agent_id":   conv.AgentID,
		"user":       user,
		"created_at": conv.CreatedAt,
	})
}

// Messages 分页返回指定会话的历史消息。
// 支持三种分页方式（优先级：after > before > offset）：
//   1. offset 分页（旧）：?limit=20&offset=0  — 向后兼容
//   2. before 游标分页：?limit=20&before=2026-06-29T12:00:00Z  — 上滑加载历史（更老方向）
//   3. after 游标分页：?limit=20&after=2026-06-29T12:00:00Z   — 定位第一条未读（更新方向）
func (h *ConversationHandler) Messages(c *gin.Context) {
	id := c.Param("id")
	userID := c.GetString("userID")

	// 越权防护：与 UnreadInfo 一致，GetByID + user_id 比对。
	// 不区分"会话不存在"和"无权访问"，避免泄露存在性。
	conv, err := h.convRepo.GetByID(id)
	if err != nil {
		log.Printf("[messages] GetByID error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	if conv == nil || conv.UserID != userID {
		c.JSON(http.StatusNotFound, gin.H{"error": "会话不存在或无权访问"})
		return
	}

	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "50"))
	// limit 边界：防恶意 client 传 0/-1/负数/超大值拖垮 DB。
	// 0/-1 会让 PG LIMIT 报错或返空；超大值一次拉全表。
	// 非法值（含 strconv.Atoi 失败的 0）统一回退到默认 50。
	if limit <= 0 || limit > 200 {
		limit = 50
	}

	// after 游标分页（更新方向，定位第一条未读场景）：优先级最高
	afterStr := c.Query("after")
	if afterStr != "" {
		after, err := time.Parse(time.RFC3339Nano, afterStr)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "after 参数格式错误"})
			return
		}
		msgs, err := h.messageRepo.ListAfter(id, after, limit)
		if err != nil {
			log.Printf("[messages] ListAfter error: %v", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
			return
		}
		if msgs == nil {
			msgs = []model.Message{}
		}
		c.JSON(http.StatusOK, msgs)
		return
	}

	beforeStr := c.Query("before")

	if beforeStr != "" {
		before, err := time.Parse(time.RFC3339Nano, beforeStr)
		if err != nil {
			c.JSON(http.StatusBadRequest, gin.H{"error": "before 参数格式错误"})
			return
		}
		msgs, err := h.messageRepo.ListBefore(id, before, limit)
		if err != nil {
			log.Printf("[messages] ListBefore error: %v", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
			return
		}
		if msgs == nil {
			msgs = []model.Message{}
		}
		c.JSON(http.StatusOK, msgs)
		return
	}

	offset, _ := strconv.Atoi(c.DefaultQuery("offset", "0"))
	msgs, err := h.messageRepo.ListByConversation(id, limit, offset)
	if err != nil {
		log.Printf("[messages] ListByConversation error: %v", err)
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

// UnreadInfo 返回会话的未读信息：未读数 + 第一条未读消息的 ID 与 created_at。
// GET /api/conversations/:id/unread
// 用于 APP 进入会话时定位第一条未读消息。
//
// 返回的 first_unread_created_at 让 APP 直接用作游标分页的 after 参数，
// 避免 APP 再发一次不可靠的"拉 N 条找 id"查询（未读 > N 时会失效）。
//
// has_more_before_first_unread 表示 firstUnread 之前是否还有已读历史消息：
// ListAfter 只查未读方向，loaded.length 满 _pageSize 不能反映 firstUnread
// 之前是否还有历史，故服务端独立 count 后告知 APP，让 APP 正确判断是否允许
// 上滑加载历史（修复 hasMore 误判 bug）。
//
// 越权防护：convRepo.GetByID 不校验 user_id，这里手动比对。
// 不区分"会话不存在"和"无权访问"，避免泄露存在性（与 MarkRead 一致）。
func (h *ConversationHandler) UnreadInfo(c *gin.Context) {
	convID := c.Param("id")
	userID := c.GetString("userID")

	conv, err := h.convRepo.GetByID(convID)
	if err != nil {
		log.Printf("[unread] GetByID error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	if conv == nil || conv.UserID != userID {
		c.JSON(http.StatusNotFound, gin.H{"error": "会话不存在或无权访问"})
		return
	}

	firstUnread, err := h.messageRepo.FirstUnread(convID)
	if err != nil {
		log.Printf("[unread] FirstUnread error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询未读消息失败"})
		return
	}

	// model.Conversation 没有 UnreadCount 字段，单独查
	unreadCount, err := h.convRepo.GetUnreadCount(convID, userID)
	if err != nil {
		log.Printf("[unread] GetUnreadCount error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询未读数失败"})
		return
	}

	firstUnreadID := ""
	var firstUnreadCreatedAt *time.Time
	hasMoreBeforeFirstUnread := false
	if firstUnread != nil {
		firstUnreadID = firstUnread.ID
		t := firstUnread.CreatedAt
		firstUnreadCreatedAt = &t

		// 仅在有未读时查 firstUnread 之前的消息数（无未读时此字段无意义）
		countBefore, err := h.messageRepo.CountBefore(convID, t)
		if err != nil {
			log.Printf("[unread] CountBefore error: %v", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "查询历史消息数失败"})
			return
		}
		hasMoreBeforeFirstUnread = countBefore > 0
	}

	c.JSON(http.StatusOK, gin.H{
		"unread_count":                unreadCount,
		"first_unread_message_id":     firstUnreadID,
		"first_unread_created_at":      firstUnreadCreatedAt,
		"has_more_before_first_unread": hasMoreBeforeFirstUnread,
	})
}
