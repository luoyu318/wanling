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
type ApprovalHandler struct {
	repo      *repository.ApprovalRepo
	msgRepo   *repository.MessageRepo
	convRepo  *repository.ConversationRepo
	agentRepo *repository.AgentRepo
	hub       *hub.Hub
	service   *approval.Service
}

// NewApprovalHandler 注入依赖。service 用于 Decide，CreateApproval 不调用。
func NewApprovalHandler(
	repo *repository.ApprovalRepo, msgRepo *repository.MessageRepo,
	convRepo *repository.ConversationRepo, agentRepo *repository.AgentRepo,
	h *hub.Hub, svc *approval.Service,
) *ApprovalHandler {
	return &ApprovalHandler{
		repo: repo, msgRepo: msgRepo, convRepo: convRepo,
		agentRepo: agentRepo, hub: h, service: svc,
	}
}

// CreateApproval POST /api/conversations/:id/approvals
// agent 创建审批卡片，事务内原子写 message + last_message_content，
// 事务外创建 approval 记录，最后广播 MESSAGE_CREATE 给会话双端。
//
// 「始终」白名单：command 类型 + 提供了 allow_pattern + preview 非空时，
// 先查会话级白名单匹配，命中则直接返回 approved 不创建审批。
func (h *ApprovalHandler) CreateApproval(c *gin.Context) {
	agentID := c.GetString("userID")
	if c.GetString("role") != "agent" {
		c.JSON(http.StatusForbidden, gin.H{"error": "仅 agent 可发起审批"})
		return
	}
	convID := c.Param("id")

	conv, err := h.convRepo.GetByID(convID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询会话失败"})
		return
	}
	if conv == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "会话不存在"})
		return
	}
	if conv.AgentID != agentID {
		c.JSON(http.StatusForbidden, gin.H{"error": "不是该会话的 agent"})
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
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求体格式错误: " + err.Error()})
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
			c.JSON(http.StatusBadRequest, gin.H{"error": "slash_confirm 必须提供 confirm_id"})
			return
		}
	default:
		c.JSON(http.StatusBadRequest, gin.H{"error": "card_type 必须是 command/tool/file/slash_confirm"})
		return
	}

	// 「始终」白名单匹配：仅 command + agent 提供了 allow_pattern + preview 非空
	if cardType == model.CardTypeCommand && req.AllowPattern != nil && req.Preview != "" {
		matched, mErr := h.repo.MatchAllowPattern(convID, agentID, req.Preview)
		if mErr == nil && matched {
			c.JSON(http.StatusOK, gin.H{
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
	contentMap := struct {
		MsgType string          `json:"msg_type"`
		Data    model.CardContent `json:"data"`
	}{MsgType: "card", Data: cardData}
	contentBytes, err := json.Marshal(contentMap)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "序列化消息内容失败"})
		return
	}

	// 事务：创建 message + last_message_content 原子化
	tx, err := h.convRepo.BeginTx()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "开启事务失败"})
		return
	}
	defer tx.Rollback()

	msg, err := h.msgRepo.CreateTx(tx, convID, "agent", agentID, contentBytes)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建消息失败"})
		return
	}
	if err := h.convRepo.UpdateLastMessageTx(tx, convID, contentBytes); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新会话缓存失败"})
		return
	}
	if err := tx.Commit(); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "提交事务失败"})
		return
	}

	// approval 在事务外创建（独立失败可接受降级 —— 消息已落库，user 端不会看到卡片但消息可见）
	approvalRecord, err := h.repo.Create(model.Approval{
		ID:             approvalID,
		MessageID:      msg.ID,
		ConversationID: convID,
		AgentID:        agentID,
		UserID:         conv.UserID,
		CardType:       cardType,
		Actions:        actions,
		ExpiresAt:      expiresAt,
		SessionKey:     req.SessionKey,
		AllowPattern:   req.AllowPattern,
		ConfirmID:      req.ConfirmID, // slash_confirm 才有值
	})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建审批失败"})
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

	c.JSON(http.StatusOK, gin.H{
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
		c.JSON(http.StatusForbidden, gin.H{"error": "仅 user 可决策"})
		return
	}
	approvalID := c.Param("id")

	var req struct {
		ActionID string `json:"action_id" binding:"required"`
		Reason   string `json:"reason"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": "请求体格式错误"})
		return
	}

	// 查 approval，校验 user 是 owner
	a, err := h.repo.GetByID(approvalID)
	if err != nil || a == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "审批不存在"})
		return
	}
	if a.UserID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "不是该审批的 owner"})
		return
	}
	if a.State != model.ApprovalStatePending {
		c.JSON(http.StatusConflict, gin.H{"error": "审批已决策或已超时", "state": a.State})
		return
	}

	// 调用 service 推进状态机 + 双写 content + 广播
	_, err = h.service.Decide(approvalID, req.ActionID, userID, req.Reason)
	if err != nil {
		if errors.Is(err, approval.ErrInvalidAction) {
			c.JSON(http.StatusBadRequest, gin.H{"error": "无效的 action_id"})
			return
		}
		if errors.Is(err, repository.ErrApprovalNotPending) {
			c.JSON(http.StatusConflict, gin.H{"error": "审批已被处理（并发）"})
			return
		}
		c.JSON(http.StatusInternalServerError, gin.H{"error": "决策失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"state": "ok"})
}

// Get GET /api/approvals/:id
// 查审批详情（兜底，agent 重连错过 WS 推送时主动查）。user/agent 双角色可查。
func (h *ApprovalHandler) Get(c *gin.Context) {
	id := c.Param("id")
	a, err := h.repo.GetByID(id)
	if err != nil || a == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "审批不存在"})
		return
	}
	c.JSON(http.StatusOK, a)
}
