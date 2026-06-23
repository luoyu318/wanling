package handler

import (
	"encoding/json"
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
	default:
		c.JSON(http.StatusBadRequest, gin.H{"error": "card_type 必须是 command/tool/file"})
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
	})
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建审批失败"})
		return
	}

	// 广播 MESSAGE_CREATE 给会话双端（user + agent）
	// payload 与现有 message processor 保持一致：双端共用，含 agent_id / user_id / content
	msgPayload, _ := json.Marshal(map[string]any{
		"id":       msg.ID,
		"agent_id": agentID,
		"user_id":  conv.UserID,
		"content":  contentMap,
	})
	wsMsg := &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageCreate,
		S:  h.hub.NextSeq(),
		D:  msgPayload,
	}
	h.hub.SendToConv(conv.UserID, agentID, wsMsg)

	c.JSON(http.StatusOK, gin.H{
		"approval_id": approvalRecord.ID,
		"message_id":  msg.ID,
		"state":       "pending",
		"expires_at":  expiresAt.Format(time.RFC3339),
	})
}

// buildActions 根据 card_type 构造按钮列表。
// command 多一个「始终」白名单按钮；tool / file 只有允许 / 拒绝。
func buildActions(t model.CardType) []model.ApprovalAction {
	allow := model.ApprovalAction{ID: "allow_once", Label: "允许", Icon: "check", Style: "primary"}
	always := model.ApprovalAction{ID: "allow_always", Label: "始终", Icon: "shield", Style: "info"}
	deny := model.ApprovalAction{ID: "deny", Label: "拒绝", Icon: "x", Style: "danger"}
	switch t {
	case model.CardTypeCommand:
		return []model.ApprovalAction{allow, always, deny}
	default:
		return []model.ApprovalAction{allow, deny}
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
