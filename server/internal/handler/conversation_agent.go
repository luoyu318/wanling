package handler

import (
	"encoding/json"
	"net/http"

	"github.com/gin-gonic/gin"
	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// CreateAsAgent agent 视角的建会话(POST /api/agents/me/conversations)。
//
// 按 type 分流:
//   - type=agent_session:走 convRepo.CreateAgentSession(每次新建,不去重),
//     支持 opencode 多 session 实例。同 (owner, agent) 可有 N 个 agent_session。
//   - 默认(不传 type / 其他):走 convRepo.FindOrCreateDM 建 dm_user_agent(去重,向后兼容)。
//
// ⚠️ agent_session 严禁走 FindOrCreateDM——其 (type+member set) 去重会把 N 个
// session 合并成 1 个,破坏多实例语义。
//
// 跟 user 视角 Create 对称:user=owner(发起方),agent=member。
// agent JWT 解析后写入 c.GetString("userID") 的实际是 agent_id。
//
// owner 强制约束:req.UserID 必须等于 agent.OwnerID,否则 403。
// 防 client 把 user_id 配错成别人的 id 导致消息发到错的 user(生产事故根因)。
//
// 校验顺序:user 存在(404) → owner 关系(403) → 建群。
// RESTful 标准做法:资源不存在 404 优先于无权限 403,避免泄露"该 user 是否存在"。
//
// 路由挂在 agentAuth 组(AuthMiddleware 已挡 user role),故 handler 内不再重复校验 role。
func (h *ConversationHandler) CreateAsAgent(c *gin.Context) {
	agentID := c.GetString("userID") // agent JWT 的 sub 是 agent_id

	var req struct {
		UserID    string `json:"user_id" binding:"required"`
		Type      string `json:"type" binding:"omitempty,max=32"`
		Title     string `json:"title" binding:"omitempty,max=128"`
		Directory string `json:"directory"` // agent_session: OC session 工作目录(TUI 场景 plugin 透传)
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	// 顺序很关键:必须先验证 user 存在再建群。
	// 否则若 user 已删除,FK 约束失败返 500 而非 404。
	user, err := h.userRepo.GetByID(c.Request.Context(), req.UserID)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-as-agent GetByID user 失败", "user_id", req.UserID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "查询 user 失败")
		return
	}
	if user == nil {
		Err(c, http.StatusNotFound, "not_found", "user 不存在")
		return
	}

	// owner 强制约束:agent 只能跟自己的 owner 建会话。
	// 防 client 把 user_id 配错成别人的 id 导致消息发到错的 user。
	agent, err := h.agentRepo.GetByID(c.Request.Context(), agentID)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-as-agent GetByID agent 失败", "agent_id", agentID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "查询 agent 失败")
		return
	}
	if agent == nil {
		// 理论上 agentAuth 中间件已挡,触达概率极低;fail-fast 暴露问题。
		Err(c, http.StatusNotFound, "not_found", "agent 不存在")
		return
	}
	if req.UserID != agent.OwnerID {
		Err(c, http.StatusForbidden, "forbidden", "user_id 必须是 agent 的 owner")
		return
	}

	// 按 type 分流:agent_session 走新建(不去重),默认走 dm 去重(向后兼容)
	var conv *model.Conversation
	if req.Type == model.ConvTypeAgentSession {
		conv, err = h.convRepo.CreateAgentSession(c.Request.Context(), req.UserID, agentID, req.Title, req.Directory)
		if err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-as-agent CreateAgentSession 失败",
				"agent_id", agentID, "user_id", req.UserID, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "创建会话失败")
			return
		}
	} else {
		// dm 发起方永远是 user owner(spec §3.7 注释),agent 是 member。
		conv, err = h.convRepo.FindOrCreateDM(c.Request.Context(), model.ConvTypeDMUserAgent, repository.DMMembers{
			Initiator: repository.ParticipantInput{MemberID: req.UserID, MemberType: "user", Role: "owner"},
			Other:     repository.ParticipantInput{MemberID: agentID, MemberType: "agent", Role: "member"},
		})
		if err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-as-agent FindOrCreateDM 失败",
				"agent_id", agentID, "user_id", req.UserID, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "创建会话失败")
			return
		}
	}

	Ok(c, gin.H{
		"id":         conv.ID,
		"type":       conv.Type,
		"title":      conv.Title,
		"user":       user, // model.User 的 PasswordHash 带 json:"-",不泄露
		"created_at": conv.CreatedAt,
	})
}

// ListAsAgent GET /api/agents/me/conversations?type=
// agent 视角列出参与的会话(供 SDK list_conversations / MCP list_conversations 工具用)。
// 不做隐藏过滤(agent 视角看全部),按 created_at 倒序。
// ?type= 可选过滤(空串=全部,如 ?type=agent_session 只返多 session 实例)。
//
// 鉴权:agentAuth 组(agent JWT)。返回 envelope data 直接是数组。
func (h *ConversationHandler) ListAsAgent(c *gin.Context) {
	agentID := c.GetString("userID") // agent JWT 的 sub 是 agent_id
	typeFilter := c.Query("type")

	convs, err := h.convRepo.ListForAgent(c.Request.Context(), agentID, typeFilter)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "ListAsAgent 查询失败",
			"agent_id", agentID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "查询失败")
		return
	}
	if convs == nil {
		convs = []model.Conversation{}
	}
	Ok(c, convs)
}

// UpdateTitleAsAgent PATCH /api/agents/me/conversations/:id/title(agentAuth)
// agent 视角改会话标题。用于 opencode-plugin ensureConversation 异步改名:
// 先用 sessionId 前缀建群,拿到可读 session 名后调本路由改名。
//
// 鉴权:agentAuth 组(agent JWT),handler 内校验 agent 是该会话 participant(member_type=agent)。
// 非 participant 返 403(复用与 Get/Messages 一致的越权防护)。
// 复用 convRepo.UpdateProfile(只改 title,avatarURL 传空串=不动)。
func (h *ConversationHandler) UpdateTitleAsAgent(c *gin.Context) {
	agentID := c.GetString("userID") // agent JWT 的 sub 是 agent_id
	convID := c.Param("id")

	var req struct {
		Title string `json:"title" binding:"omitempty,max=128"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	// 校验 agent 是该会话 participant(越权防护)
	ok, err := h.participantRepo.Exists(c.Request.Context(), convID, agentID, "agent")
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "update-title-as-agent Exists 失败",
			"conv_id", convID, "agent_id", agentID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if !ok {
		Err(c, http.StatusForbidden, "forbidden", "not a participant")
		return
	}

	if err := h.convRepo.UpdateProfile(c.Request.Context(), convID, req.Title, ""); err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "update-title-as-agent UpdateProfile 失败",
			"conv_id", convID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "更新失败")
		return
	}

	// 广播给 user 端(仅 user,跳过 agent)。OC→万灵 单向同步:
	// 插件改完 server DB 后,APP 实时收到刷新;但不再回传给 agent,
	// 避免插件收到自己触发的标题又去改 OC,形成回声循环。
	if h.hub != nil {
		h.hub.BroadcastConversationUpdateToUsers(convID, req.Title, "")
	}
	Ok(c, nil)
}

// UpdateSessionMetaAsAgent PATCH /api/agents/me/conversations/:id/session-meta (agentAuth)
// plugin session.updated 事件触发：同步 mode/model/variant/git_branch/tokens 到 server。
// 注意:cwd 字段已升级到 conversations.directory 一级列(创建时固化),不再走 JSONB。
// 即便 plugin 还在 body 里传 cwd,本 handler 也彻底剔除,不再写入 session_meta。
// agent JWT 鉴权 + participant 越权校验（与 UpdateTitleAsAgent 一致）。
func (h *ConversationHandler) UpdateSessionMetaAsAgent(c *gin.Context) {
	agentID := c.GetString("userID")
	convID := c.Param("id")

	var req struct {
		Mode         string `json:"mode"`
		ModelID      string `json:"modelId"`
		ProviderID   string `json:"providerId"`
		Variant      string `json:"variant,omitempty"`
		ModelName    string `json:"modelName,omitempty"`
		ProviderName string `json:"providerName,omitempty"`
		GitBranch    string `json:"gitBranch,omitempty"`
		TokensTotal  int64  `json:"tokensTotal,omitempty"`
		ContextUsed  int64  `json:"contextUsed,omitempty"`
		ContextLimit int64  `json:"contextLimit,omitempty"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	ok, err := h.participantRepo.Exists(c.Request.Context(), convID, agentID, "agent")
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "update-session-meta Exists 失败",
			"conv_id", convID, "agent_id", agentID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if !ok {
		Err(c, http.StatusForbidden, "forbidden", "not a participant")
		return
	}

	// 故意不写 cwd 字段(已升级到 conversations.directory 一级列)。
	// plugin 即便传 cwd 也被 JSON marshal 忽略(本 struct 不含该字段)。
	meta, _ := json.Marshal(map[string]any{
		"mode":          req.Mode,
		"model_id":      req.ModelID,
		"provider_id":   req.ProviderID,
		"variant":       req.Variant,
		"model_name":    req.ModelName,
		"provider_name": req.ProviderName,
		"git_branch":    req.GitBranch,
		"tokens_total":  req.TokensTotal,
		"context_used":  req.ContextUsed,
		"context_limit": req.ContextLimit,
	})
	if err := h.convRepo.UpdateSessionMeta(c.Request.Context(), convID, meta); err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "update-session-meta 失败",
			"conv_id", convID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "更新失败")
		return
	}
	// 广播给本会话 user 端:APP chatProvider 监听 SESSION_META_UPDATE 后
	// 实时刷新 SessionMetaStrip(mode/model) + EnvMetaStrip(directory/git_branch),
	// 不再依赖 agent 消息触发 2s 防抖拉取。
	// 仅推 user(断回环 plugin→OC,与 UpdateTitleAsAgent 同口径)。
	if h.hub != nil {
		h.hub.BroadcastSessionMetaUpdateToUsers(convID, meta)
	}
	Ok(c, nil)
}

// ListAgentSessions GET /api/agents/:id/sessions(userAuth)
// 列出当前 user 与指定 agent 的所有 agent_session 群(二级列表页用)。
// 空列表返 [] 而非 null,避免 APP 反序列化报错。
func (h *ConversationHandler) ListAgentSessions(c *gin.Context) {
	userID := c.GetString("userID")
	agentID := c.Param("id")

	items, err := h.convRepo.ListAgentSessionsForUser(c.Request.Context(), userID, agentID)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "ListAgentSessions 查询失败",
			"user_id", userID, "agent_id", agentID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "查询失败")
		return
	}
	if items == nil {
		items = []model.ConversationListItem{}
	}
	Ok(c, items)
}
