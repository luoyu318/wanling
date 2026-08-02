package handler

import (
	"crypto/rand"
	"encoding/hex"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/agent"
	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/presence"
	"github.com/wanling/server/internal/repository"
)

type AgentHandler struct {
	agentRepo *repository.AgentRepo
	convRepo  *repository.ConversationRepo
	presence  *presence.Presence
	// agentRegistry 缓存 plugin 上报的可选模型清单,Models 端点读取,
	// AGENT_MODELS WS 事件经 message.Processor 写入(Task 2 接线)。
	agentRegistry *agent.AgentRegistry
	// slashCatalogRegistry 缓存 plugin 上报的命令清单,SlashCatalog 端点读取,
	// AGENT_SLASH_CATALOG WS 事件经 message.Processor 写入。
	slashCatalogRegistry *agent.SlashCatalogRegistry
}

func NewAgentHandler(agentRepo *repository.AgentRepo, convRepo *repository.ConversationRepo, p *presence.Presence, reg *agent.AgentRegistry, slashReg *agent.SlashCatalogRegistry) *AgentHandler {
	return &AgentHandler{agentRepo: agentRepo, convRepo: convRepo, presence: p, agentRegistry: reg, slashCatalogRegistry: slashReg}
}

func generateSecretKey() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

type CreateAgentRequest struct {
	Name string `json:"name" binding:"required"`
	Type string `json:"type" binding:"omitempty,max=32"`
}

func (h *AgentHandler) Create(c *gin.Context) {
	var req CreateAgentRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	userID := c.GetString("userID")
	secretKey, err := generateSecretKey()
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "生成密钥失败")
		return
	}

	agent, err := h.agentRepo.Create(c.Request.Context(), userID, req.Name, secretKey, req.Type)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "创建失败")
		return
	}

	// 建 owner↔agent 默认 conv(pairing 兜底 + 用户体验:owner 进 app 就能看到会话)
	// fail-soft:agent 已创建成功,conv 建失败只 log 不阻断,
	// client 端可后续 find_or_create 兜底。
	defaultConvID := ""
	conv, err := h.convRepo.FindOrCreateDM(c.Request.Context(), model.ConvTypeDMUserAgent, repository.DMMembers{
		Initiator: repository.ParticipantInput{
			MemberID:   userID,
			MemberType: "user",
			Role:       "owner",
		},
		Other: repository.ParticipantInput{
			MemberID:   agent.ID,
			MemberType: "agent",
			Role:       "member",
		},
	})
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "建默认 conv 失败",
			"agent_id", agent.ID, "owner_id", userID, "err", err)
	} else {
		defaultConvID = conv.ID
	}

	// secret_key 仅创建时一次性返回（GitHub PAT 模式），后续 List/Get/Update 不返。
	// model.Agent.SecretKey 已改 json:"-"，这里手动拼字段塞回响应。
	OkCreated(c, gin.H{
		"id":              agent.ID,
		"owner_id":        agent.OwnerID,
		"name":            agent.Name,
		"avatar_url":      agent.AvatarURL,
		"bio":             agent.Bio,
		"status":          agent.Status,
		"type":            agent.Type,
		"created_at":      agent.CreatedAt,
		"secret_key":      agent.SecretKey,
		"default_conv_id": defaultConvID,
	})
}

func (h *AgentHandler) List(c *gin.Context) {
	userID := c.GetString("userID")
	agents, err := h.agentRepo.ListByOwner(c.Request.Context(), userID)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "查询失败")
		return
	}
	if agents == nil {
		agents = []model.Agent{}
	}
	for i := range agents {
		if h.presence.IsOnline(c.Request.Context(), "agent", agents[i].ID) {
			agents[i].Status = model.AgentStatusOnline
		} else {
			agents[i].Status = model.AgentStatusOffline
		}
	}
	Ok(c, agents)
}

type UpdateAgentRequest struct {
	Name      string  `json:"name"       binding:"omitempty,max=128"`
	AvatarURL string  `json:"avatar_url" binding:"omitempty,max=256"`
	Bio       *string `json:"bio"        binding:"omitempty,max=200"`
	Type      string  `json:"type"       binding:"omitempty,max=32"`
}

func (h *AgentHandler) Update(c *gin.Context) {
	id := c.Param("id")
	userID := c.GetString("userID")

	// IDOR 防护：操作前校验归属，仅 owner 可改自己的 agent。
	existing, err := h.agentRepo.GetByID(c.Request.Context(), id)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if existing == nil {
		Err(c, http.StatusNotFound, "not_found", "Agent 不存在")
		return
	}
	if existing.OwnerID != userID {
		Err(c, http.StatusForbidden, "forbidden", "无权操作该 Agent")
		return
	}

	var req UpdateAgentRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}
	if err := validateAvatarURL(req.AvatarURL); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	agent, err := h.agentRepo.Update(c.Request.Context(), id, req.Name, req.AvatarURL, req.Bio)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "更新失败")
		return
	}
	if agent == nil {
		Err(c, http.StatusNotFound, "not_found", "Agent 不存在")
		return
	}
	// type 标签变更（opencode 多 session 功能）：非空且与当前不同时更新
	if req.Type != "" && req.Type != string(existing.Type) {
		if err := h.agentRepo.UpdateType(c.Request.Context(), id, req.Type); err != nil {
			ErrMsg(c, http.StatusInternalServerError, "更新 type 失败")
			return
		}
		agent.Type = model.AgentType(req.Type)
	}

	// 同步在线状态（与 List 一致）
	if h.presence.IsOnline(c.Request.Context(), "agent", agent.ID) {
		agent.Status = model.AgentStatusOnline
	} else {
		agent.Status = model.AgentStatusOffline
	}
	Ok(c, agent)
}

func (h *AgentHandler) Delete(c *gin.Context) {
	id := c.Param("id")
	userID := c.GetString("userID")

	// IDOR 防护：操作前校验归属，仅 owner 可删自己的 agent。
	existing, err := h.agentRepo.GetByID(c.Request.Context(), id)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if existing == nil {
		Err(c, http.StatusNotFound, "not_found", "Agent 不存在")
		return
	}
	if existing.OwnerID != userID {
		Err(c, http.StatusForbidden, "forbidden", "无权操作该 Agent")
		return
	}

	if err := h.agentRepo.Delete(c.Request.Context(), id); err != nil {
		ErrMsg(c, http.StatusInternalServerError, "删除失败")
		return
	}
	Ok(c, gin.H{"message": "删除成功"})
}

// RotateSecret 重置 agent 的 secret_key,返回新密钥(仅此一次下发,对齐 GitHub PAT 模式)。
// IDOR 防护同 Update/Delete:GetByID → OwnerID 比对。
// 复用 agentRepo.ResetSecretKey(256-bit hex),不依赖 plugin 重连。
func (h *AgentHandler) RotateSecret(c *gin.Context) {
	id := c.Param("id")
	userID := c.GetString("userID")

	existing, err := h.agentRepo.GetByID(c.Request.Context(), id)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if existing == nil {
		Err(c, http.StatusNotFound, "not_found", "Agent 不存在")
		return
	}
	if existing.OwnerID != userID {
		Err(c, http.StatusForbidden, "forbidden", "无权操作该 Agent")
		return
	}

	newKey, err := h.agentRepo.ResetSecretKey(c.Request.Context(), id)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "重置密钥失败")
		return
	}
	Ok(c, gin.H{"secret_key": newKey})
}

// Models 返回某 agent 的可选模型清单(由 plugin 上报,内存缓存)。
// IDOR 防护:仅 owner 可查自己 agent 的模型清单(GetByID → OwnerID 比对,与 Update/Delete 一致)。
// 空清单也返 200(plugin 未上报 / server 刚重启 / opencode 未就绪 都是合法空态),updated_at=null 表示从未上报。
func (h *AgentHandler) Models(c *gin.Context) {
	id := c.Param("id")
	userID := c.GetString("userID")

	// IDOR 防护:操作前校验归属,仅 owner 可查自己的 agent。
	existing, err := h.agentRepo.GetByID(c.Request.Context(), id)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if existing == nil {
		Err(c, http.StatusNotFound, "not_found", "Agent 不存在")
		return
	}
	if existing.OwnerID != userID {
		Err(c, http.StatusForbidden, "forbidden", "无权操作该 Agent")
		return
	}

	models, updatedAt := h.agentRegistry.Get(id)
	// registry.Get 未上报时返 time.Time{},默认 marshal 为 "0001-01-01T00:00:00Z"。
	// spec 要求返 null,故用 any + IsZero 条件赋值:nil → JSON null,真实时间 → RFC3339 字符串。
	var updatedAtAny any
	if !updatedAt.IsZero() {
		updatedAtAny = updatedAt
	}
	Ok(c, gin.H{
		"agent_id":   id,
		"models":     models,
		"updated_at": updatedAtAny,
	})
}

// SlashCatalog 返回某 agent 的命令清单(由 plugin 上报,内存缓存)。
// IDOR 防护:仅 owner 可查自己 agent 的命令清单。空清单返 200 + updated_at=null。
func (h *AgentHandler) SlashCatalog(c *gin.Context) {
	id := c.Param("id")
	userID := c.GetString("userID")

	existing, err := h.agentRepo.GetByID(c.Request.Context(), id)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if existing == nil {
		Err(c, http.StatusNotFound, "not_found", "Agent 不存在")
		return
	}
	if existing.OwnerID != userID {
		Err(c, http.StatusForbidden, "forbidden", "无权操作该 Agent")
		return
	}

	commands, updatedAt := h.slashCatalogRegistry.Get(id)
	var updatedAtAny any
	if !updatedAt.IsZero() {
		updatedAtAny = updatedAt
	}
	Ok(c, gin.H{
		"agent_id":   id,
		"commands":   commands,
		"updated_at": updatedAtAny,
	})
}
