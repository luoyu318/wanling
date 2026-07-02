package handler

import (
	"database/sql"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/hub"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// ConversationHandler 处理会话相关的 HTTP 请求。
//
// participants 模型重构后,会话不再绑定单一 user/agent,而是 N 方参与者。
//   - convRepo:只读写 conversations 表本身(含 last_message_content 缓存)
//   - participantRepo:管 conversation_participants 行(权限 / 未读 / 置顶 / 隐藏)
//   - friendshipRepo:dm_user_user 创建前校验好友关系(spec §4.2)
//   - messageRepo:历史消息查询 / 首条未读定位
//   - agentRepo / userRepo:Get 详情用(ListForUser 已 subquery JOIN,但 agent 端 findOrCreate 仍需 user 摘要)
//   - hub:WS 广播(群聊创建广播 CONVERSATION_PARTICIPANT_JOIN)
//   - db:整会话标已读 / 销群等需要 BeginTx 的场景
type ConversationHandler struct {
	db              *sql.DB
	convRepo        *repository.ConversationRepo
	participantRepo *repository.ParticipantRepo
	friendshipRepo  *repository.FriendshipRepo
	messageRepo     *repository.MessageRepo
	agentRepo       *repository.AgentRepo
	userRepo        *repository.UserRepo
	hub             *hub.Hub
}

// NewConversationHandler 构造 ConversationHandler。
func NewConversationHandler(
	db *sql.DB,
	convRepo *repository.ConversationRepo,
	participantRepo *repository.ParticipantRepo,
	friendshipRepo *repository.FriendshipRepo,
	messageRepo *repository.MessageRepo,
	agentRepo *repository.AgentRepo,
	userRepo *repository.UserRepo,
	hub *hub.Hub,
) *ConversationHandler {
	return &ConversationHandler{
		db:              db,
		convRepo:        convRepo,
		participantRepo: participantRepo,
		friendshipRepo:  friendshipRepo,
		messageRepo:     messageRepo,
		agentRepo:       agentRepo,
		userRepo:        userRepo,
		hub:             hub,
	}
}

// List 返回当前用户参与的 IM 风格会话列表(含个人维度 unread/pin + 对端摘要)。
// ListForUser 已 JOIN participants 取个人维度字段;dm_user_agent 的对端 agent 摘要
// 走 subquery,group_* 的 participants 摘要留待应用层组装(本期 UI 走 title)。
//
// 空列表返回 [] 而非 null,避免 APP 端反序列化报错。
func (h *ConversationHandler) List(c *gin.Context) {
	userID := c.GetString("userID")
	items, err := h.convRepo.ListForUser(userID)
	if err != nil {
		log.Printf("[conv-list] ListForUser error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}
	if items == nil {
		items = []model.ConversationListItem{}
	}
	c.JSON(http.StatusOK, items)
}

// CreateConversationReq 是 POST /api/conversations 的请求体。
//
// 同时支持:
//   - 新 body(N 方 participants 模型):type + member_ids + member_types + 群可选 title/avatar_url
//   - 老 body(向后兼容):agent_id → server 翻译为 type=dm_user_agent + member=[(agent_id, agent)]
//
// type 取值见 spec:dm_user_user / dm_user_agent / group_user / group_mixed。
type CreateConversationReq struct {
	Type            string   `json:"type"`
	MemberIDs       []string `json:"member_ids"`
	MemberTypes     []string `json:"member_types"`
	MemberUsernames []string `json:"member_usernames"` // dm_user_user 专用：client 不持 user_id（spec §4.2 防枚举），按 username 反查
	Title           string   `json:"title"`
	AvatarURL       string   `json:"avatar_url"`
	AgentID         string   `json:"agent_id"` // 老兼容字段
}

// Create 创建会话(user 视角)。
//
// 1-1 dm 走 convRepo.FindOrCreateDM(内部事务管「会话 + 2 行 participants」);
// group_* 走 convRepo.CreateTx + participantRepo.AddParticipantsTx(显式事务绑两步)。
// 群聊创建成功后广播 CONVERSATION_PARTICIPANT_JOIN 让所有成员刷新列表。
//
// 老兼容:agent_id 老 body 自动翻译为 type=dm_user_agent + member=[(agent_id, agent)]。
//
// 权限前置:dm_user_user 校验好友关系(spec §4.2),非好友返 403。
func (h *ConversationHandler) Create(c *gin.Context) {
	userID := c.GetString("userID")

	var req CreateConversationReq
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 老兼容:agent_id 自动翻译为 dm_user_agent
	if req.AgentID != "" && req.Type == "" {
		req.Type = "dm_user_agent"
		req.MemberIDs = []string{req.AgentID}
		req.MemberTypes = []string{"agent"}
	}

	if req.Type == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "type required"})
		return
	}

	// 校验 member_ids / member_types 长度一致(新 body 防漏配)
	if len(req.MemberIDs) != len(req.MemberTypes) {
		c.JSON(http.StatusBadRequest, gin.H{"error": "member_ids and member_types length mismatch"})
		return
	}
	// 老 body 翻译后 MemberTypes 长度必为 1,正常通过

	// dm_user_user 好友前置校验(spec §4.2)
	if req.Type == "dm_user_user" {
		// client 不持有 user_id（spec §4.2），优先按 member_usernames 反查。
		// 反查后填回 MemberIDs / MemberTypes，统一后续路径。
		if len(req.MemberUsernames) > 0 {
			if len(req.MemberUsernames) != 1 {
				c.JSON(http.StatusBadRequest, gin.H{"error": "dm_user_user requires exactly 1 member"})
				return
			}
			otherID, err := h.userRepo.GetIDByUsername(req.MemberUsernames[0])
			if err != nil {
				if errors.Is(err, sql.ErrNoRows) {
					c.JSON(http.StatusNotFound, gin.H{"error": "user not found"})
					return
				}
				log.Printf("[conv-create] GetIDByUsername error: %v", err)
				c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
				return
			}
			req.MemberIDs = []string{otherID}
			req.MemberTypes = []string{"user"}
		}

		if len(req.MemberIDs) != 1 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "dm_user_user requires exactly 1 member"})
			return
		}
		otherID := req.MemberIDs[0]
		ok, err := h.friendshipRepo.AreFriends(userID, otherID)
		if err != nil {
			log.Printf("[conv-create] AreFriends error: %v", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "校验好友失败"})
			return
		}
		if !ok {
			c.JSON(http.StatusForbidden, gin.H{"error": "非好友不能发起私聊"})
			return
		}
	}

	var conv *model.Conversation
	var err error
	switch {
	case strings.HasPrefix(req.Type, "dm_"):
		// 1-1 dm:FindOrCreateDM(内部事务管「会话 + 2 行 participants」)
		if len(req.MemberIDs) != 1 {
			c.JSON(http.StatusBadRequest, gin.H{"error": "dm requires exactly 1 member"})
			return
		}
		// initiator=user(永远 owner),other=member(dm_user_agent 时 member 是 agent;
		// dm_user_user 时 member 是 user)
		conv, err = h.convRepo.FindOrCreateDM(req.Type, repository.DMMembers{
			Initiator: repository.ParticipantInput{MemberID: userID, MemberType: "user", Role: "owner"},
			Other:     repository.ParticipantInput{MemberID: req.MemberIDs[0], MemberType: req.MemberTypes[0], Role: "member"},
		})
		if err != nil {
			log.Printf("[conv-create] FindOrCreateDM error: %v", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "创建会话失败"})
			return
		}

	case strings.HasPrefix(req.Type, "group_"):
		// 群聊:CreateTx + AddParticipantsTx(显式事务绑两步)
		tx, err := h.db.Begin()
		if err != nil {
			log.Printf("[conv-create] Begin error: %v", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "创建会话失败"})
			return
		}
		defer tx.Rollback() // commit 后 noop

		conv, err = h.convRepo.CreateTx(tx, req.Type, req.Title, req.AvatarURL)
		if err != nil {
			log.Printf("[conv-create] CreateTx error: %v", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "创建会话失败"})
			return
		}

		// creator 自动加 owner + 所有 member 加 member role
		allParticipants := []repository.ParticipantInput{
			{MemberID: userID, MemberType: "user", Role: "owner"},
		}
		for i, id := range req.MemberIDs {
			allParticipants = append(allParticipants, repository.ParticipantInput{
				MemberID: id, MemberType: req.MemberTypes[i], Role: "member",
			})
		}
		if err := h.participantRepo.AddParticipantsTx(tx, conv.ID, allParticipants); err != nil {
			log.Printf("[conv-create] AddParticipantsTx error: %v", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "创建会话失败"})
			return
		}

		if err := tx.Commit(); err != nil {
			log.Printf("[conv-create] Commit error: %v", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "创建会话失败"})
			return
		}

		// 广播 JOIN(让所有 participants 收到列表刷新信号)
		if h.hub != nil {
			h.hub.BroadcastParticipantJoin(conv.ID, userID, "user", "owner", "")
		}

	default:
		c.JSON(http.StatusBadRequest, gin.H{"error": "unknown type"})
		return
	}

	// 复用 Get 详情拼装响应(含 participants 摘要)
	item, err := h.buildDetail(conv.ID)
	if err != nil {
		log.Printf("[conv-create] buildDetail error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询会话详情失败"})
		return
	}
	c.JSON(http.StatusOK, item)
}

// Get 返回单个会话详情(含 participants 摘要)。
// 越权防护:非 participant 返 403(spec §6.1)。
func (h *ConversationHandler) Get(c *gin.Context) {
	userID := c.GetString("userID")
	convID := c.Param("id")

	ok, err := h.participantRepo.Exists(convID, userID, "user")
	if err != nil {
		log.Printf("[conv-get] Exists error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	if !ok {
		c.JSON(http.StatusForbidden, gin.H{"error": "not a participant"})
		return
	}

	item, err := h.buildDetail(convID)
	if err != nil {
		log.Printf("[conv-get] buildDetail error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	c.JSON(http.StatusOK, item)
}

// buildDetail 拼装单个会话详情:conversations 表本身 + participants 摘要列表。
// 1-1 dm_user_agent 时附 agent 摘要(老 APP 仍依赖 agent 字段)。
func (h *ConversationHandler) buildDetail(convID string) (*model.ConversationListItem, error) {
	conv, err := h.convRepo.GetByID(convID)
	if err != nil {
		return nil, err
	}
	if conv == nil {
		return nil, sql.ErrNoRows
	}

	// BatchLoadParticipantSummaries 一次 SQL 拿所有 participants
	partMap, err := h.convRepo.BatchLoadParticipantSummaries([]string{convID})
	if err != nil {
		return nil, err
	}
	parts := partMap[convID]
	if parts == nil {
		parts = []model.ParticipantSummary{}
	}

	item := &model.ConversationListItem{
		ID:                 conv.ID,
		Type:               conv.Type,
		Title:              conv.Title,
		AvatarURL:          conv.AvatarURL,
		LastMessageContent: conv.LastMessageContent,
		LastMessageAt:      conv.LastMessageAt,
		CreatedAt:          conv.CreatedAt,
		Participants:       parts,
	}

	// dm_user_agent 兼容老 APP:附 agent 摘要
	if conv.Type == "dm_user_agent" {
		for _, p := range parts {
			if p.MemberType == "agent" {
				agent, err := h.agentRepo.GetByID(p.MemberID)
				if err == nil && agent != nil {
					item.Agent = &model.AgentSummary{
						ID:        agent.ID,
						Name:      agent.Name,
						AvatarURL: agent.AvatarURL,
					}
				}
				break
			}
		}
	}

	return item, nil
}

// CreateAsAgent agent 视角的 FindOrCreate(POST /api/agents/me/conversations)。
// 仅支持 dm_user_agent(spec §4.1)。
//
// 跟 user 视角 Create 对称:user=owner(发起方),agent=member。
// agent JWT 解析后写入 c.GetString("userID") 的实际是 agent_id。
//
// 路由挂在 agentAuth 组(AuthMiddleware 已挡 user role),故 handler 内不再重复校验 role。
func (h *ConversationHandler) CreateAsAgent(c *gin.Context) {
	agentID := c.GetString("userID") // agent JWT 的 sub 是 agent_id

	var req struct {
		UserID string `json:"user_id" binding:"required"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	// 顺序很关键:必须先验证 user 存在再 FindOrCreateDM。
	// 否则若 user 已删除,FK 约束失败返 500 而非 404。
	user, err := h.userRepo.GetByID(req.UserID)
	if err != nil {
		log.Printf("[conv-as-agent] GetByID user error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询 user 失败"})
		return
	}
	if user == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "user 不存在"})
		return
	}

	// dm 发起方永远是 user owner(spec §3.7 注释),agent 是 member。
	conv, err := h.convRepo.FindOrCreateDM("dm_user_agent", repository.DMMembers{
		Initiator: repository.ParticipantInput{MemberID: req.UserID, MemberType: "user", Role: "owner"},
		Other:     repository.ParticipantInput{MemberID: agentID, MemberType: "agent", Role: "member"},
	})
	if err != nil {
		log.Printf("[conv-as-agent] FindOrCreateDM error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建会话失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"id":         conv.ID,
		"type":       conv.Type,
		"user":       user, // model.User 的 PasswordHash 带 json:"-",不泄露
		"created_at": conv.CreatedAt,
	})
}

// Messages 分页返回指定会话的历史消息。
// 支持三种分页方式(优先级:after > before > offset):
//   - offset 分页(旧):?limit=20&offset=0 — 向后兼容
//   - before 游标分页:?limit=20&before=<RFC3339> — 上滑加载历史(更老方向)
//   - after 游标分页:?limit=20&after=<RFC3339> — 定位第一条未读(更新方向)
//
// 越权防护:participantRepo.Exists 校验,非 participant 返 403(spec §6.1)。
func (h *ConversationHandler) Messages(c *gin.Context) {
	id := c.Param("id")
	userID := c.GetString("userID")

	ok, err := h.participantRepo.Exists(id, userID, "user")
	if err != nil {
		log.Printf("[messages] Exists error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	if !ok {
		c.JSON(http.StatusForbidden, gin.H{"error": "not a participant"})
		return
	}

	limit, _ := strconv.Atoi(c.DefaultQuery("limit", "50"))
	// limit 边界:防恶意 client 传 0/-1/负数/超大值拖垮 DB。
	if limit <= 0 || limit > 200 {
		limit = 50
	}

	// after 游标分页(更新方向,定位第一条未读场景):优先级最高
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
		c.JSON(http.StatusBadRequest, gin.H{"error": "message_ids 字段必填"})
		return
	}

	// 防御性上限:单次最多 100 条(与 batch-delete 一致)
	if len(req.MessageIDs) > 100 {
		c.JSON(http.StatusBadRequest, gin.H{"error": "单次最多 100 条 message_ids"})
		return
	}

	tx, err := h.db.Begin()
	if err != nil {
		log.Printf("[mark-msgs-read] Begin error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	defer tx.Rollback()

	newUnread, err := h.participantRepo.MarkMessagesReadTx(tx, convID, userID, "user", req.MessageIDs)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			c.JSON(http.StatusForbidden, gin.H{"error": "not a participant"})
			return
		}
		log.Printf("[mark-msgs-read] MarkMessagesReadTx error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}

	if err := tx.Commit(); err != nil {
		log.Printf("[mark-msgs-read] Commit error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"ok": true, "unread_count": newUnread})
}

// MarkRead 整会话标已读:取该 user 在该 conv 所有未读 message_ids,
// 转走 MarkMessagesReadTx 批量标已读 + 重算 unread_count。
//
// 用于"用户进入 ChatPage 时调一次"和"老 APP 兼容"。
// 越权 / 非 participant:返 403(与 MarkMessagesRead 一致)。
func (h *ConversationHandler) MarkRead(c *gin.Context) {
	convID := c.Param("id")
	userID := c.GetString("userID")

	tx, err := h.db.Begin()
	if err != nil {
		log.Printf("[mark-read] Begin error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	defer tx.Rollback()

	// 取该 user 在该 conv 所有未读 message_ids(read_at IS NULL AND deleted_at IS NULL)
	rows, err := tx.Query(`
		SELECT d.message_id FROM message_deliveries d
		JOIN messages m ON m.id = d.message_id
		WHERE d.recipient_id = $1 AND d.recipient_type = 'user' AND d.read_at IS NULL
		  AND m.conversation_id = $2 AND m.deleted_at IS NULL
	`, userID, convID)
	if err != nil {
		log.Printf("[mark-read] Query unread error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	var msgIDs []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			log.Printf("[mark-read] Scan error: %v", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
			return
		}
		msgIDs = append(msgIDs, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		log.Printf("[mark-read] rows.Err: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}

	newUnread, err := h.participantRepo.MarkMessagesReadTx(tx, convID, userID, "user", msgIDs)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			c.JSON(http.StatusForbidden, gin.H{"error": "not a participant"})
			return
		}
		log.Printf("[mark-read] MarkMessagesReadTx error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}

	if err := tx.Commit(); err != nil {
		log.Printf("[mark-read] Commit error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"ok": true, "unread_count": newUnread})
}

// Pin 置顶会话(个人维度)。越权 / 非 participant → 403。
func (h *ConversationHandler) Pin(c *gin.Context) {
	if err := h.setPinnedFor(c, true); err != nil {
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// Unpin 取消置顶。越权 / 非 participant → 403。
func (h *ConversationHandler) Unpin(c *gin.Context) {
	if err := h.setPinnedFor(c, false); err != nil {
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// setPinnedFor 是 Pin/Unpin 共享实现。
// SetPinned/SetHidden 是 UPDATE 操作,空命中(非 participant)不返 sql.ErrNoRows,
// 故必须显式 Exists 校验(spec §6.1)。
func (h *ConversationHandler) setPinnedFor(c *gin.Context, pinned bool) error {
	convID := c.Param("id")
	userID := c.GetString("userID")

	ok, err := h.participantRepo.Exists(convID, userID, "user")
	if err != nil {
		log.Printf("[set-pinned] Exists error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return err
	}
	if !ok {
		c.JSON(http.StatusForbidden, gin.H{"error": "not a participant"})
		return errors.New("forbidden")
	}

	if err := h.participantRepo.SetPinned(convID, userID, "user", pinned); err != nil {
		log.Printf("[set-pinned] SetPinned error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return err
	}
	return nil
}

// Hide 个人维度软删除会话(列表不显示,聊天记录保留,新消息自动恢复)。
// 越权 / 非 participant → 403。
func (h *ConversationHandler) Hide(c *gin.Context) {
	convID := c.Param("id")
	userID := c.GetString("userID")

	ok, err := h.participantRepo.Exists(convID, userID, "user")
	if err != nil {
		log.Printf("[hide] Exists error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	if !ok {
		c.JSON(http.StatusForbidden, gin.H{"error": "not a participant"})
		return
	}

	if err := h.participantRepo.SetHidden(convID, userID, "user", true); err != nil {
		log.Printf("[hide] SetHidden error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"ok": true})
}

// UnreadInfo 返回会话的未读信息:未读数 + 第一条未读消息的 ID 与 created_at。
// GET /api/conversations/:id/unread
// 用于 APP 进入会话时定位第一条未读消息。
//
// 越权 / 非 participant:返 403(与新版权限语义对齐)。
func (h *ConversationHandler) UnreadInfo(c *gin.Context) {
	convID := c.Param("id")
	userID := c.GetString("userID")

	ok, err := h.participantRepo.Exists(convID, userID, "user")
	if err != nil {
		log.Printf("[unread] Exists error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "服务器错误"})
		return
	}
	if !ok {
		c.JSON(http.StatusForbidden, gin.H{"error": "not a participant"})
		return
	}

	// 未读数从 participant 行取(participants 模型重构后,unread_count 在 participant 表)
	p, err := h.participantRepo.Get(convID, userID, "user")
	if err != nil {
		log.Printf("[unread] Get participant error: %v", err)
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询未读数失败"})
		return
	}
	if p == nil {
		// Exists 通过 → Get 也能拿到,理论上不会到这分支
		c.JSON(http.StatusForbidden, gin.H{"error": "not a participant"})
		return
	}
	unreadCount := p.UnreadCount

	// 首条未读走 DeliveryRepo(已下沉)
	firstUnreadID := ""
	var firstUnreadCreatedAt *time.Time
	hasMoreBeforeFirstUnread := false
	if unreadCount > 0 {
		// 取该 user 在该 conv 的首条未读 message(LIST 1 条)
		rows, err := h.db.Query(`
			SELECT m.id, m.created_at FROM message_deliveries d
			JOIN messages m ON m.id = d.message_id
			WHERE d.recipient_id = $1 AND d.recipient_type = 'user' AND d.read_at IS NULL
			  AND m.conversation_id = $2 AND m.deleted_at IS NULL
			ORDER BY m.created_at ASC LIMIT 1
		`, userID, convID)
		if err != nil {
			log.Printf("[unread] query first unread error: %v", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "查询未读消息失败"})
			return
		}
		for rows.Next() {
			var id string
			var t time.Time
			if err := rows.Scan(&id, &t); err != nil {
				rows.Close()
				log.Printf("[unread] scan error: %v", err)
				c.JSON(http.StatusInternalServerError, gin.H{"error": "查询未读消息失败"})
				return
			}
			firstUnreadID = id
			firstUnreadCreatedAt = &t

			// 仅在有未读时查 firstUnread 之前的消息数(无未读时此字段无意义)
			countBefore, err := h.messageRepo.CountBefore(convID, t)
			if err != nil {
				rows.Close()
				log.Printf("[unread] CountBefore error: %v", err)
				c.JSON(http.StatusInternalServerError, gin.H{"error": "查询历史消息数失败"})
				return
			}
			hasMoreBeforeFirstUnread = countBefore > 0
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			log.Printf("[unread] rows.Err: %v", err)
			c.JSON(http.StatusInternalServerError, gin.H{"error": "查询未读消息失败"})
			return
		}
	}

	c.JSON(http.StatusOK, gin.H{
		"unread_count":                unreadCount,
		"first_unread_message_id":     firstUnreadID,
		"first_unread_created_at":     firstUnreadCreatedAt,
		"has_more_before_first_unread": hasMoreBeforeFirstUnread,
	})
}
