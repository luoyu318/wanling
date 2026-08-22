package handler

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/wanling/server/internal/approval"
	"github.com/wanling/server/internal/hub"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// ApprovalHandler 审批消息 HTTP 处理器。
// 后续 task 接入 Decide / Get，3 个 endpoint：
//   - CreateApproval（agent）
//   - Decide（user）
//   - Get（双角色）
//
// participants 模型重构后,会话不再绑定单一 user_id/agent_id:
//   - convRepo.GetByID 仅返 conversations 表本身(无 user_id/agent_id 字段)
//   - 权限校验 + 找对端 user 走 participantRepo
type ApprovalHandler struct {
	repo            *repository.ApprovalRepo
	msgRepo         *repository.MessageRepo
	convRepo        *repository.ConversationRepo
	agentRepo       *repository.AgentRepo
	participantRepo *repository.ParticipantRepo
	hub             *hub.Hub
	service         *approval.Service
}

// NewApprovalHandler 注入依赖。service 用于 Decide，CreateApproval 不调用。
// participantRepo 用于 participants 模型下的权限校验和定位对端 user。
func NewApprovalHandler(
	repo *repository.ApprovalRepo, msgRepo *repository.MessageRepo,
	convRepo *repository.ConversationRepo, agentRepo *repository.AgentRepo,
	participantRepo *repository.ParticipantRepo,
	h *hub.Hub, svc *approval.Service,
) *ApprovalHandler {
	return &ApprovalHandler{
		repo: repo, msgRepo: msgRepo, convRepo: convRepo,
		agentRepo: agentRepo, participantRepo: participantRepo,
		hub: h, service: svc,
	}
}

// CreateApproval POST /api/conversations/:id/approvals
// agent 创建审批卡片,事务内原子写 message(017 已删 last_message_content 缓存字段,
// 会话列表改子查询实时算,本 handler 不再维护缓存),
// 事务外创建 approval 记录,最后广播 MESSAGE_CREATE 给会话双端。
//
// 「始终」白名单：command 类型 + 提供了 allow_pattern + preview 非空时，
// 先查会话级白名单匹配，命中则直接返回 approved 不创建审批。
func (h *ApprovalHandler) CreateApproval(c *gin.Context) {
	agentID := c.GetString("userID")
	if c.GetString("role") != "agent" {
		Err(c, http.StatusForbidden, "forbidden", "仅 agent 可发起审批")
		return
	}
	convID := c.Param("id")

	conv, err := h.convRepo.GetByID(c.Request.Context(), convID)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "查询会话失败")
		return
	}
	if conv == nil {
		Err(c, http.StatusNotFound, "not_found", "会话不存在")
		return
	}
	// participants 模型:agent 必须是该会话的 participant 才能发起审批(spec §6.1)。
	// 老模型用 conv.AgentID 字段直接对比,新模型 conv 不再有 user_id/agent_id 字段,
	// 改查 conversation_participants 表。
	isMember, err := h.participantRepo.Exists(c.Request.Context(), convID, agentID, "agent")
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "校验会话成员失败")
		return
	}
	if !isMember {
		Err(c, http.StatusForbidden, "forbidden", "不是该会话的 agent")
		return
	}

	var req struct {
		CardType     string                   `json:"card_type" binding:"required"`
		Title        string                   `json:"title" binding:"required"`
		Preview      string                   `json:"preview"`
		PreviewLang  string                   `json:"preview_language"`
		ToolName     string                   `json:"tool_name"`
		File         *model.FileRef           `json:"file"`
		Meta         []map[string]interface{} `json:"meta"`
		SessionKey   string                   `json:"session_key" binding:"required"`
		AllowPattern *string                  `json:"allow_pattern"`
		ConfirmID    *string                  `json:"confirm_id"` // slash_confirm 用
		TimeoutSec   int                      `json:"timeout_sec"`
		// question 类型字段：选项列表 + 是否多选
		Options []struct {
			ID    string `json:"id" binding:"required"`
			Label string `json:"label"`
		} `json:"options"`
		MultiSelect bool `json:"multi_select"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", "请求体格式错误: "+err.Error())
		return
	}

	var cardType model.CardType
	switch req.CardType {
	case "command", "tool", "file":
		cardType = model.CardType(req.CardType)
	case "slash_confirm":
		cardType = model.CardTypeSlashConfirm
		// slash_confirm 必须带 confirm_id（hermes tools/slash_confirm.resolve 定位用）
		if req.ConfirmID == nil || *req.ConfirmID == "" {
			Err(c, http.StatusBadRequest, "bad_request", "slash_confirm 必须提供 confirm_id")
			return
		}
	case "question":
		cardType = model.CardTypeQuestion
		// question 必须带 options 且 id 非空、唯一
		if len(req.Options) == 0 {
			Err(c, http.StatusBadRequest, "bad_request", "question 类型必须提供 options")
			return
		}
		seen := map[string]bool{}
		for _, o := range req.Options {
			if o.ID == "" || seen[o.ID] {
				Err(c, http.StatusBadRequest, "bad_request", "options id 必须非空且唯一")
				return
			}
			seen[o.ID] = true
		}
	default:
		Err(c, http.StatusBadRequest, "bad_request", "card_type 必须是 command/tool/file/slash_confirm/question")
		return
	}

	// 「始终」白名单匹配：仅 command + agent 提供了 allow_pattern + preview 非空
	if cardType == model.CardTypeCommand && req.AllowPattern != nil && req.Preview != "" {
		matched, mErr := h.repo.MatchAllowPattern(c.Request.Context(), convID, agentID, req.Preview)
		if mErr == nil && matched {
			Ok(c, gin.H{
				"state":           "approved",
				"auto_approved":   true,
				"matched_pattern": req.AllowPattern,
			})
			return
		}
	}

	actions := buildActions(cardType)
	timeoutSec := req.TimeoutSec
	if timeoutSec <= 0 || timeoutSec > 3600 {
		timeoutSec = 300
	}
	expiresAt := time.Now().Add(time.Duration(timeoutSec) * time.Second).UTC()

	// approval_id 先生成，需嵌入 message content 的 CardContent.ApprovalID
	approvalID := uuid.New().String()
	cardData := model.CardContent{
		ApprovalID:  approvalID,
		CardType:    cardType,
		Title:       req.Title,
		Preview:     req.Preview,
		PreviewLang: req.PreviewLang,
		ToolName:    req.ToolName,
		File:        req.File,
		Actions:     actions,
		State:       model.ApprovalStatePending,
		ExpiresAt:   expiresAt,
		ConfirmID:   req.ConfirmID, // slash_confirm 才有值
	}
	for _, m := range req.Meta {
		cardData.Meta = append(cardData.Meta, model.CardMeta{
			Icon: getStr(m, "icon"), Text: getStr(m, "text"), Warn: getBool(m, "warn"),
		})
	}
	// question 类型：options + multi_select 双写进 content
	if cardType == model.CardTypeQuestion {
		cardData.Options = make([]model.ApprovalOption, 0, len(req.Options))
		for _, o := range req.Options {
			cardData.Options = append(cardData.Options, model.ApprovalOption{ID: o.ID, Label: o.Label})
		}
		cardData.MultiSelect = req.MultiSelect
	}
	contentMap := struct {
		MsgType string            `json:"msg_type"`
		Data    model.CardContent `json:"data"`
	}{MsgType: "card", Data: cardData}
	contentBytes, err := json.Marshal(contentMap)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "序列化消息内容失败")
		return
	}

	// 事务:创建 message 原子化(017 删除 last_message_content 缓存后,本事务仅写 messages 表)
	tx, err := h.convRepo.BeginTx(c.Request.Context())
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "开启事务失败")
		return
	}
	defer tx.Rollback()

	msg, err := h.msgRepo.CreateTx(c.Request.Context(), tx, convID, "agent", agentID, contentBytes)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "创建消息失败")
		return
	}
	if err := tx.Commit(); err != nil {
		ErrMsg(c, http.StatusInternalServerError, "提交事务失败")
		return
	}

	// participants 模型:审批卡片不再预绑定接收方 user_id,决策权走 participant
	// 校验(Decide 入口 Exists)。CreateApproval 前置 Exists 保证 agent 在该 conv,
	// dm_user_agent 会话内必有 1 个 user participant,无需此处再查。
	// 群聊场景理论上不会触发审批卡片(agent 仅在 dm 里发)。

	// approval 在事务外创建（独立失败可接受降级 —— 消息已落库，user 端不会看到卡片但消息可见）
	approvalRecord, err := h.repo.Create(c.Request.Context(), model.Approval{
		ID:             approvalID,
		MessageID:      msg.ID,
		ConversationID: convID,
		InitiatorType:  "agent",
		InitiatorID:    agentID,
		CardType:       cardType,
		Actions:        actions,
		ExpiresAt:      expiresAt,
		SessionKey:     req.SessionKey,
		AllowPattern:   req.AllowPattern,
		ConfirmID:      req.ConfirmID, // slash_confirm 才有值
	})
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "创建审批失败")
		return
	}

	// 广播 MESSAGE_CREATE 给会话双端（user + agent）
	// payload 字段必须与 internal/message/processor.go 的 dispatch 一致：
	// APP chatProvider 按 conversation_id 过滤 + ChatMessage.fromJson 必填
	// conversation_id/sender_type/sender_id/created_at，缺一就会被丢弃或解析崩溃。
	msgPayload, _ := json.Marshal(map[string]any{
		"id":              msg.ID,
		"conversation_id": convID,
		"sender_type":     "agent",
		"sender_id":       agentID,
		"content":         contentMap,
		"created_at":      msg.CreatedAt,
	})
	wsMsg := &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageCreate,
		S:  h.hub.NextSeq(),
		D:  msgPayload,
	}
	h.hub.SendToConv(convID, wsMsg)

	Ok(c, gin.H{
		"approval_id": approvalRecord.ID,
		"message_id":  msg.ID,
		"state":       "pending",
		"expires_at":  expiresAt.Format(time.RFC3339),
	})
}

// buildActions 根据 card_type 构造按钮列表。
//   - command：允许 / 始终 / 拒绝（action_id: allow_once/allow_always/deny）
//   - tool/file：允许 / 拒绝（action_id: allow_once/deny）
//   - slash_confirm：执行一次 / 不再询问 / 取消（action_id: once/always/cancel，对齐 hermes
//     tools/slash_confirm.resolve 的 choice 枚举，adapter 直接透传无需映射）
//   - question：提交答案 / 拒绝（action_id: answer/reject，answers 在 Decide 请求体里）
func buildActions(t model.CardType) []model.ApprovalAction {
	switch t {
	case model.CardTypeCommand:
		return []model.ApprovalAction{
			{ID: "allow_once", Label: "允许", Icon: "check", Style: "primary"},
			{ID: "allow_always", Label: "始终", Icon: "shield", Style: "info"},
			{ID: "deny", Label: "拒绝", Icon: "x", Style: "danger"},
		}
	case model.CardTypeSlashConfirm:
		return []model.ApprovalAction{
			{ID: "once", Label: "执行一次", Icon: "check", Style: "primary"},
			{ID: "always", Label: "不再询问", Icon: "shield", Style: "info"},
			{ID: "cancel", Label: "取消", Icon: "x", Style: "danger"},
		}
	case model.CardTypeQuestion:
		return []model.ApprovalAction{
			{ID: "answer", Label: "提交答案", Style: "primary"},
			{ID: "reject", Label: "拒绝", Style: "danger"},
		}
	default: // tool / file
		return []model.ApprovalAction{
			{ID: "allow_once", Label: "允许", Icon: "check", Style: "primary"},
			{ID: "deny", Label: "拒绝", Icon: "x", Style: "danger"},
		}
	}
}

// getStr 安全从 map 取字符串，缺省返回空串。
func getStr(m map[string]interface{}, k string) string {
	if v, ok := m[k]; ok {
		if s, ok := v.(string); ok {
			return s
		}
	}
	return ""
}

// getBool 安全从 map 取 bool，缺省返回 false。
func getBool(m map[string]interface{}, k string) bool {
	if v, ok := m[k]; ok {
		if b, ok := v.(bool); ok {
			return b
		}
	}
	return false
}

// Decide POST /api/approvals/:id/decide
// user 决策审批。action_id 必须在卡片 actions 列表内。
func (h *ApprovalHandler) Decide(c *gin.Context) {
	userID := c.GetString("userID")
	if c.GetString("role") != "user" {
		Err(c, http.StatusForbidden, "forbidden", "仅 user 可决策")
		return
	}
	approvalID := c.Param("id")

	var req struct {
		ActionID string   `json:"action_id" binding:"required"`
		Reason   string   `json:"reason"`
		Answers  []string `json:"answers"` // question 多选答案
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", "请求体格式错误")
		return
	}

	// 查 approval
	a, err := h.repo.GetByID(c.Request.Context(), approvalID)
	if err != nil || a == nil {
		Err(c, http.StatusNotFound, "not_found", "审批不存在")
		return
	}
	// participants 模型:审批卡片归属会话,user 决策权 = user 是该会话 participant。
	// 替代老 schema 直接对比 a.UserID(decider 在 pending 时为 NULL,无法用)。
	isMember, err := h.participantRepo.Exists(c.Request.Context(), a.ConversationID, userID, "user")
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "校验会话成员失败")
		return
	}
	if !isMember {
		Err(c, http.StatusForbidden, "forbidden", "不是该审批的 owner")
		return
	}
	if a.State != model.ApprovalStatePending {
		Err(c, http.StatusConflict, "invalid_state", "审批已决策或已超时", gin.H{"state": string(a.State)})
		return
	}

	// 调用 service 推进状态机 + 双写 content + 广播(deciderType 固定 user,Decide 入口前置校验)
	_, err = h.service.Decide(c.Request.Context(), approvalID, req.ActionID, req.Reason, req.Answers, "user", userID)
	if err != nil {
		if errors.Is(err, approval.ErrInvalidAction) {
			Err(c, http.StatusBadRequest, "invalid_action", "无效的 action_id 或 answers")
			return
		}
		if errors.Is(err, repository.ErrApprovalNotPending) {
			Err(c, http.StatusConflict, "invalid_state", "审批已被处理（并发）")
			return
		}
		ErrMsg(c, http.StatusInternalServerError, "决策失败")
		return
	}
	Ok(c, nil)
}

// Get GET /api/approvals/:id
// 查审批详情（兜底，agent 重连错过 WS 推送时主动查）。user/agent 双角色可查,
// 但必须命中会话 participant 或发起方 agent,防 UUID 枚举越权。
func (h *ApprovalHandler) Get(c *gin.Context) {
	id := c.Param("id")
	a, err := h.repo.GetByID(c.Request.Context(), id)
	if err != nil || a == nil {
		Err(c, http.StatusNotFound, "not_found", "审批不存在")
		return
	}
	// IDOR 防护(participants 模型):
	//   - user 角色: 必须是该会话的 user participant
	//   - agent 角色: 必须是发起方(initiator)
	userID := c.GetString("userID")
	role := c.GetString("role")
	if role == "user" {
		isMember, err := h.participantRepo.Exists(c.Request.Context(), a.ConversationID, userID, "user")
		if err != nil {
			ErrMsg(c, http.StatusInternalServerError, "校验会话成员失败")
			return
		}
		if !isMember {
			Err(c, http.StatusForbidden, "forbidden", "无权访问")
			return
		}
	} else if role == "agent" {
		if a.InitiatorType != "agent" || a.InitiatorID != userID {
			Err(c, http.StatusForbidden, "forbidden", "无权访问")
			return
		}
	}
	Ok(c, a)
}
