package handler

import (
	"context"
	"database/sql"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/hub"
	logpkg "github.com/wanling/server/internal/log"
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
//   - deliveryRepo:per-recipient 投递状态(整会话标已读取未读 id 集合 / 首条未读定位)
//   - agentRepo / userRepo:Get 详情用(ListForUser 已 subquery JOIN,但 agent 端 findOrCreate 仍需 user 摘要)
//   - hub:WS 广播(群聊创建广播 CONVERSATION_PARTICIPANT_JOIN)
//   - db:整会话标已读 / 销群等需要 BeginTx 的场景
type ConversationHandler struct {
	db              *sql.DB
	convRepo        *repository.ConversationRepo
	participantRepo *repository.ParticipantRepo
	friendshipRepo  *repository.FriendshipRepo
	messageRepo     *repository.MessageRepo
	deliveryRepo    *repository.DeliveryRepo
	agentRepo       *repository.AgentRepo
	userRepo        *repository.UserRepo
	hub             *hub.Hub
	registry        *hub.RPCRegistry
}

// NewConversationHandler 构造 ConversationHandler。
func NewConversationHandler(
	db *sql.DB,
	convRepo *repository.ConversationRepo,
	participantRepo *repository.ParticipantRepo,
	friendshipRepo *repository.FriendshipRepo,
	messageRepo *repository.MessageRepo,
	deliveryRepo *repository.DeliveryRepo,
	agentRepo *repository.AgentRepo,
	userRepo *repository.UserRepo,
	hub *hub.Hub,
	registry *hub.RPCRegistry,
) *ConversationHandler {
	return &ConversationHandler{
		db:              db,
		convRepo:        convRepo,
		participantRepo: participantRepo,
		friendshipRepo:  friendshipRepo,
		messageRepo:     messageRepo,
		deliveryRepo:    deliveryRepo,
		agentRepo:       agentRepo,
		userRepo:        userRepo,
		hub:             hub,
		registry:        registry,
	}
}

// List 返回当前用户参与的 IM 风格会话列表(含个人维度 unread/pin + 对端摘要)。
// ListForUser 已 JOIN participants 取个人维度字段;dm_user_agent 的对端 agent 摘要
// 走 subquery,group_* 的 participants 摘要留待应用层组装(本期 UI 走 title)。
//
// 空列表返回 [] 而非 null,避免 APP 端反序列化报错。
func (h *ConversationHandler) List(c *gin.Context) {
	userID := c.GetString("userID")
	items, err := h.convRepo.ListForUser(c.Request.Context(), userID)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-list ListForUser 失败", "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "查询失败")
		return
	}
	if items == nil {
		items = []model.ConversationListItem{}
	}

	// 补 participants 摘要(让 IM 列表 conv 带 participants,client 拼群人数 /
	// 渲染头像用)。批量查避免 N+1,跟 buildDetail 同一 helper。
	if len(items) > 0 {
		convIDs := make([]string, 0, len(items))
		for _, it := range items {
			convIDs = append(convIDs, it.ID)
		}
		partMap, err := h.convRepo.BatchLoadParticipantSummaries(c.Request.Context(), convIDs)
		if err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-list BatchLoadParticipantSummaries 失败", "user_id", userID, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "查询参与者失败")
			return
		}
		for i := range items {
			parts := partMap[items[i].ID]
			if parts == nil {
				parts = []model.ParticipantSummary{}
			}
			items[i].Participants = parts
		}
	}

	// 批量聚合 opencode agent session 统计（未读数 / 待处理数 / session 数量）。
	// 入口行（dm_user_agent）与 agent_session 消息隔离，需聚合才能在一级列表体现。
	agentIDs := make([]string, 0, len(items))
	for _, it := range items {
		if it.Agent != nil && it.Agent.Type == "opencode" {
			agentIDs = append(agentIDs, it.Agent.ID)
		}
	}
	if len(agentIDs) > 0 {
		stats, err := h.convRepo.BatchLoadAgentSessionStats(c.Request.Context(), userID, agentIDs)
		if err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-list BatchLoadAgentSessionStats 失败", "user_id", userID, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "查询 agent session 统计失败")
			return
		}
		for i := range items {
			if items[i].Agent == nil {
				continue
			}
			s, ok := stats[items[i].Agent.ID]
			if !ok {
				continue
			}
			items[i].UnreadCount += s.UnreadTotal
			if s.LastMessageAt.After(items[i].LastMessageAt) {
				items[i].LastMessageAt = s.LastMessageAt
			}
			items[i].SessionCount = s.SessionCount
			items[i].PendingCount = s.PendingCount
		}
	}

	Ok(c, items)
}

// Get 返回单个会话详情(含 participants 摘要)。
// 越权防护:非 participant 返 403(spec §6.1)。
func (h *ConversationHandler) Get(c *gin.Context) {
	userID := c.GetString("userID")
	convID := c.Param("id")

	ok, err := h.participantRepo.Exists(c.Request.Context(), convID, userID, "user")
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-get Exists 失败", "conv_id", convID, "user_id", userID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if !ok {
		Err(c, http.StatusForbidden, "forbidden", "not a participant")
		return
	}

	item, err := h.buildDetail(c.Request.Context(), convID, userID)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-get buildDetail 失败", "conv_id", convID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	Ok(c, item)
}

// buildDetail 拼装单个会话详情:conversations 表本身 + participants 摘要列表 +
// 个人维度最新可见消息(017 删缓存字段后改子查询实时算,跟 ListForUser 同语义)。
// 1-1 dm_user_agent 时附 agent 摘要(老 APP 仍依赖 agent 字段)。
func (h *ConversationHandler) buildDetail(ctx context.Context, convID, userID string) (*model.ConversationListItem, error) {
	conv, err := h.convRepo.GetByID(ctx, convID)
	if err != nil {
		return nil, err
	}
	if conv == nil {
		return nil, sql.ErrNoRows
	}

	// BatchLoadParticipantSummaries 一次 SQL 拿所有 participants
	partMap, err := h.convRepo.BatchLoadParticipantSummaries(ctx, []string{convID})
	if err != nil {
		return nil, err
	}
	parts := partMap[convID]
	if parts == nil {
		parts = []model.ParticipantSummary{}
	}

	// 个人维度最新可见消息(017 后改子查询,跟 ListForUser 同口径):
	// 排除 deleted_at 软删 + 排除该 user 隐藏过的消息(message_hidden)。
	lastContent, lastAt, lastSenderID, lastSenderType, err := h.convRepo.GetLastVisibleMessage(ctx, convID, userID, "user")
	if err != nil {
		return nil, err
	}
	// 无消息会话(刚建群 / dm 刚 FindOrCreate)用 createdAt 兜底,
	// 避免 client 拿到 0001-01-01 零值显示异常。
	if lastAt.IsZero() {
		lastAt = conv.CreatedAt
	}

	item := &model.ConversationListItem{
		ID:                    conv.ID,
		Type:                  conv.Type,
		Title:                 conv.Title,
		AvatarURL:             conv.AvatarURL,
		SessionMeta:           conv.SessionMeta,
		Directory:             conv.Directory,
		LastMessageContent:    lastContent,
		LastMessageAt:         lastAt,
		LastMessageSenderID:   lastSenderID,
		LastMessageSenderType: lastSenderType,
		CreatedAt:             conv.CreatedAt,
		Participants:          parts,
	}

	if conv.Type == model.ConvTypeDMUserAgent || conv.Type == model.ConvTypeAgentSession {
		for _, p := range parts {
			if p.MemberType == "agent" {
				agent, err := h.agentRepo.GetByID(ctx, p.MemberID)
				if err == nil && agent != nil {
					online := false
					if h.hub != nil {
						_, online = h.hub.GetClient("agent", agent.ID)
					}
					st := model.AgentStatusOffline
					if online {
						st = model.AgentStatusOnline
					}
					item.Agent = &model.AgentSummary{
						ID:        agent.ID,
						Name:      agent.Name,
						AvatarURL: agent.AvatarURL,
						Type:      agent.Type,
						Status:    st,
					}
				}
				break
			}
		}
	}

	return item, nil
}
