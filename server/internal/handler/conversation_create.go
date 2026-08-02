package handler

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

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
	AgentID         string   `json:"agent_id"`  // 老兼容字段
	Directory       string   `json:"directory"` // agent_session: OC session 工作目录,创建时固化。空串 = 用户选默认
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
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	// 老兼容:agent_id 自动翻译为 dm_user_agent
	if req.AgentID != "" && req.Type == "" {
		req.Type = model.ConvTypeDMUserAgent
		req.MemberIDs = []string{req.AgentID}
		req.MemberTypes = []string{"agent"}
	}

	if req.Type == "" {
		Err(c, http.StatusBadRequest, "bad_request", "type required")
		return
	}

	// 校验 member_ids / member_types 长度一致(新 body 防漏配)
	if len(req.MemberIDs) != len(req.MemberTypes) {
		Err(c, http.StatusBadRequest, "bad_request", "member_ids and member_types length mismatch")
		return
	}
	// 老 body 翻译后 MemberTypes 长度必为 1,正常通过

	// member_usernames 反查(spec §4.2:client 不持 user_id)。
	// dm_user_user 和 group_user 场景都支持反查多个 username,统一在这处理。
	// 反查成功后填回 MemberIDs / MemberTypes,与「直接传 member_ids/types」路径合并。
	if !h.resolveMemberUsernames(c, &req) {
		return
	}

	// dm_user_user 好友前置校验(spec §4.2)
	if req.Type == model.ConvTypeDMUserUser {
		if len(req.MemberIDs) != 1 {
			Err(c, http.StatusBadRequest, "bad_request", "dm_user_user requires exactly 1 member")
			return
		}
		otherID := req.MemberIDs[0]
		ok, err := h.friendshipRepo.AreFriends(c.Request.Context(), userID, otherID)
		if err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-create AreFriends 校验失败", "user_id", userID, "other_id", otherID, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "校验好友失败")
			return
		}
		if !ok {
			Err(c, http.StatusForbidden, "forbidden", "非好友不能发起私聊")
			return
		}
	}

	var conv *model.Conversation
	var err error
	switch {
	case strings.HasPrefix(req.Type, "dm_"):
		// 1-1 dm:FindOrCreateDM(内部事务管「会话 + 2 行 participants」)
		if len(req.MemberIDs) != 1 {
			Err(c, http.StatusBadRequest, "bad_request", "dm requires exactly 1 member")
			return
		}
		// initiator=user(永远 owner),other=member(dm_user_agent 时 member 是 agent;
		// dm_user_user 时 member 是 user)
		conv, err = h.convRepo.FindOrCreateDM(c.Request.Context(), req.Type, repository.DMMembers{
			Initiator: repository.ParticipantInput{MemberID: userID, MemberType: "user", Role: "owner"},
			Other:     repository.ParticipantInput{MemberID: req.MemberIDs[0], MemberType: req.MemberTypes[0], Role: "member"},
		})
		if err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-create FindOrCreateDM 失败", "type", req.Type, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "创建会话失败")
			return
		}

	case strings.HasPrefix(req.Type, "group_"):
		// 群聊至少 2 个 member(3 人会话含 creator)
		if len(req.MemberIDs) < 2 {
			Err(c, http.StatusBadRequest, "bad_request", "group requires at least 2 members")
			return
		}
		// 群聊:CreateTx + AddParticipantsTx(显式事务绑两步)
		tx, err := h.db.BeginTx(c.Request.Context(), nil)
		if err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-create Begin 失败", "err", err)
			ErrMsg(c, http.StatusInternalServerError, "创建会话失败")
			return
		}
		defer tx.Rollback() // commit 后 noop

		conv, err = h.convRepo.CreateTx(c.Request.Context(), tx, req.Type, req.Title, req.AvatarURL)
		if err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-create CreateTx 失败", "type", req.Type, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "创建会话失败")
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
		if err := h.participantRepo.AddParticipantsTx(c.Request.Context(), tx, conv.ID, allParticipants); err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-create AddParticipantsTx 失败", "conv_id", conv.ID, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "创建会话失败")
			return
		}

		if err := tx.Commit(); err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-create Commit 失败", "err", err)
			ErrMsg(c, http.StatusInternalServerError, "创建会话失败")
			return
		}

		// 广播 JOIN(让所有 participants 收到列表刷新信号)
		if h.hub != nil {
			h.hub.BroadcastParticipantJoin(conv.ID, userID, "user", "owner", "")
		}

	case req.Type == model.ConvTypeAgentSession:
		// agent_session: user 主动建 OC session 群。
		// member 校验:有且仅有 1 个 agent member(spec:多实例语义)。
		if len(req.MemberIDs) != 1 || req.MemberTypes[0] != "agent" {
			Err(c, http.StatusBadRequest, "bad_request", "agent_session requires exactly 1 agent member")
			return
		}
		agentID := req.MemberIDs[0]
		// 拉 agent → 校验 owner 关系(对齐 CreateAsAgent 防越权约束)。
		agent, err := h.agentRepo.GetByID(c.Request.Context(), agentID)
		if err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-create agent_session GetByID agent 失败", "agent_id", agentID, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "查询 agent 失败")
			return
		}
		if agent == nil {
			Err(c, http.StatusNotFound, "not_found", "agent 不存在")
			return
		}
		if agent.OwnerID != userID {
			Err(c, http.StatusForbidden, "forbidden", "无权操作:不是该 Agent 的所有者")
			return
		}

		// 强同步:先写 DB(tx 未提交),通知 plugin 创建 OC session,
		// plugin 成功才 commit,失败则 rollback 整个会话。
		tx, err := h.db.BeginTx(c.Request.Context(), nil)
		if err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-create agent_session BeginTx 失败", "err", err)
			ErrMsg(c, http.StatusInternalServerError, "创建会话失败")
			return
		}
		defer tx.Rollback()

		conv, err = h.convRepo.CreateAgentSessionTx(c.Request.Context(), tx, userID, agentID, req.Title, req.Directory)
		if err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-create agent_session CreateAgentSessionTx 失败",
				"agent_id", agentID, "user_id", userID, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "创建会话失败")
			return
		}

		// plugin 在线检查
		if _, ok := h.hub.GetClient("agent", agentID); !ok {
			c.JSON(http.StatusServiceUnavailable, gin.H{
				"error": gin.H{"code": rpcErrPluginOffline, "message": "plugin offline"},
			})
			return
		}

		// 发 RPC session.create 给 plugin,等回包
		rpcCtx, rpcCancel := context.WithTimeout(c.Request.Context(), 10*time.Second)
		defer rpcCancel()
		rpcID, ch := h.registry.Register(rpcCtx, agentID)

		params := gin.H{
			"wanling_conv_id": conv.ID,
			"title":           req.Title,
			"directory":       req.Directory,
		}
		call := gin.H{"jsonrpc": "2.0", "id": rpcID, "method": "session.create", "params": params}
		callBytes, _ := json.Marshal(call)
		if err := h.hub.SendToAgent(agentID, &model.WSMessage{Op: model.OpPluginCall, D: callBytes}); err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(),
				"conv-create agent_session SendToAgent 失败", "agent_id", agentID, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "通知插件失败")
			return
		}

		select {
		case got := <-ch:
			if got.Err != nil {
				logpkg.FromCtx(c.Request.Context()).WarnContext(c.Request.Context(),
					"conv-create agent_session plugin 拒绝", "agent_id", agentID, "code", got.Err.Code, "msg", got.Err.Message)
				c.JSON(http.StatusBadGateway, gin.H{"error": got.Err})
				return
			}
		case <-rpcCtx.Done():
			logpkg.FromCtx(c.Request.Context()).WarnContext(c.Request.Context(),
				"conv-create agent_session RPC 超时", "agent_id", agentID, "rpc_id", rpcID)
			c.JSON(http.StatusGatewayTimeout, gin.H{
				"error": gin.H{"code": rpcErrPluginTimeout, "message": "plugin timeout"},
			})
			return
		}

		if err := tx.Commit(); err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(),
				"conv-create agent_session Commit 失败", "conv_id", conv.ID, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "提交会话失败")
			return
		}

		// 广播 JOIN 让 APP provider load() 刷新(对齐 group_* 路径)
		if h.hub != nil {
			h.hub.BroadcastParticipantJoin(conv.ID, userID, "user", "owner", "")
		}

	default:
		Err(c, http.StatusBadRequest, "bad_request", "unknown type")
		return
	}

	// 复用 Get 详情拼装响应(含 participants 摘要)
	item, err := h.buildDetail(c.Request.Context(), conv.ID, userID)
	if err != nil {
		logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-create buildDetail 失败", "conv_id", conv.ID, "err", err)
		ErrMsg(c, http.StatusInternalServerError, "查询会话详情失败")
		return
	}
	Ok(c, item)
}

// resolveMemberUsernames 把 member_usernames 反查成 user_id,填回 MemberIDs / MemberTypes。
//
// 用于 dm_user_user 和 group_user 场景(client 不持 user_id,spec §4.2 防枚举)。
// 任一 username 查不到 → 404;DB 错误 → 500;成功后 MemberIDs 长度 == MemberUsernames。
//
// helper 强制 MemberUsernames 非空时 MemberIDs 必须为空(否则 client 同时传了
// 两种字段,语义模糊,helper 直接 fail-fast 返 400);同时校验 MemberUsernames
// 内部无重复(防静默吞错)。返回 false 表示已写响应,调用方应直接 return。
func (h *ConversationHandler) resolveMemberUsernames(c *gin.Context, req *CreateConversationReq) bool {
	if len(req.MemberUsernames) == 0 {
		return true
	}
	// client 不应同时传两种字段(语义模糊:到底以哪个为准?)
	if len(req.MemberIDs) > 0 {
		Err(c, http.StatusBadRequest, "bad_request", "不能同时传 member_ids 和 member_usernames")
		return false
	}
	// username 内部去重检查(防 dedup 静默吞错)
	seen := make(map[string]struct{}, len(req.MemberUsernames))
	for _, u := range req.MemberUsernames {
		if _, ok := seen[u]; ok {
			Err(c, http.StatusBadRequest, "bad_request", "member_usernames 包含重复值: "+u)
			return false
		}
		seen[u] = struct{}{}
	}
	resolved := make([]string, 0, len(req.MemberUsernames))
	types := make([]string, 0, len(req.MemberUsernames))
	for _, username := range req.MemberUsernames {
		uid, err := h.userRepo.GetIDByUsername(c.Request.Context(), username)
		if err != nil {
			if errors.Is(err, sql.ErrNoRows) {
				Err(c, http.StatusNotFound, "not_found", "user not found: "+username)
				return false
			}
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "conv-create GetIDByUsername 失败", "username", username, "err", err)
			ErrMsg(c, http.StatusInternalServerError, "服务器错误")
			return false
		}
		resolved = append(resolved, uid)
		types = append(types, "user")
	}
	req.MemberIDs = resolved
	req.MemberTypes = types
	return true
}
