// Package approval 提供审批状态机决策逻辑 + dispatch 编排。
package approval

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// Repositorier service 依赖的 repo 接口（便于测试 mock）。
// 实际实现是 *repository.ApprovalRepo，但生产代码我们也直接传 *ApprovalRepo
// 以复用 GetForDecision / UpdateMessageContent（这两个不在最小接口里）。
type Repositorier interface {
	MarkDecided(ctx context.Context, id, actionID, deciderType, deciderID, reason string, allowPattern *string) error
	MarkExpired(ctx context.Context, id string) error
	MatchAllowPattern(ctx context.Context, convID, initiatorID, command string) (bool, error)
}

// Hubber service 依赖的 hub 接口（避免直接依赖 hub 包造成循环 import）。
type Hubber interface {
	BroadcastMessageUpdate(convID, messageID string, content json.RawMessage)
	SendApprovalDecided(initiatorID string, payload map[string]any)
	SendApprovalExpired(initiatorID string, payload map[string]any)
}

// Service 审批决策服务。
type Service struct {
	repo         Repositorier
	hub          Hubber
	approvalRepo *repository.ApprovalRepo
}

// NewService approvalRepo 必须同时实现 Repositorier 接口。
func NewService(repo Repositorier, hub Hubber, approvalRepo *repository.ApprovalRepo) *Service {
	return &Service{repo: repo, hub: hub, approvalRepo: approvalRepo}
}

var (
	// ErrInvalidAction action_id 不在审批卡 actions 列表中。
	ErrInvalidAction = errors.New("invalid action_id for approval")
	// ErrApprovalNotFound approval_id 在表里查不到（可能已被 cleanup 删了，或客户端瞎传）。
	ErrApprovalNotFound = errors.New("approval not found")
)

// Decide 推进审批到 approved/denied 终态：
//  1. JOIN 查审批 + 关联消息内容；
//  2. 校验 actionID 合法；
//  3. MarkDecided（带 allow_pattern 仅当 allow_always）；
//  4. 双写 messages.content（state + decided_*）；
//  5. 广播 MESSAGE_UPDATE（双端）+ APPROVAL_DECIDED（仅 agent）。
//
// ctx 由 handler 透传(c.Request.Context),让 client 中断请求时进行中的 DB 查询中止。
// 注意:本方法内部变量 decCtx(DecisionContext 缩写)与首参 ctx 命名分开,避免混淆。
//
// 返回更新后的 content，供 handler 直接 echo 给调用方（HTTP 响应用）。
//
// deciderType/deciderID 由 handler 透传(c.GetString("role") / c.GetString("userID")),
// 落库到 approvals.decider_type/decider_id。
func (s *Service) Decide(ctx context.Context, approvalID, actionID, deciderType, deciderID, reason string) (json.RawMessage, error) {
	decCtx, err := s.approvalRepo.GetForDecision(ctx, approvalID)
	if err != nil {
		return nil, err
	}
	if decCtx == nil {
		return nil, ErrApprovalNotFound
	}

	// actionID 必须在 actions 列表里（防客户端瞎传）
	valid := false
	for _, a := range decCtx.CardContent.Actions {
		if a.ID == actionID {
			valid = true
			break
		}
	}
	if !valid {
		return nil, ErrInvalidAction
	}

	// 仅 allow_always 写 allow_pattern（其他动作不写，避免污染白名单）
	pattern := decCtx.AllowPattern
	if actionID != "allow_always" {
		pattern = nil
	}
	if err := s.repo.MarkDecided(ctx, approvalID, actionID, deciderType, deciderID, reason, pattern); err != nil {
		return nil, err
	}

	now := time.Now().UTC()
	state := model.ApprovalStateApproved
	// deny（exec_approval）和 cancel（slash_confirm）都是「未通过」，统一映射 denied。
	if actionID == "deny" || actionID == "cancel" {
		state = model.ApprovalStateDenied
	}
	decCtx.CardContent.State = state
	decCtx.CardContent.DecidedAction = &actionID
	decCtx.CardContent.DecidedAt = &now
	decCtx.CardContent.DecidedBy = &deciderID
	if reason != "" {
		decCtx.CardContent.DecidedReason = &reason
	}

	wrapper := struct {
		MsgType string            `json:"msg_type"`
		Data    model.CardContent `json:"data"`
	}{MsgType: string(model.MsgTypeCard), Data: decCtx.CardContent}
	newContent, err := json.Marshal(wrapper)
	if err != nil {
		return nil, err
	}
	if err := s.approvalRepo.UpdateMessageContent(ctx, decCtx.MessageID, newContent); err != nil {
		return nil, err
	}

	s.hub.BroadcastMessageUpdate(decCtx.ConversationID, decCtx.MessageID, newContent)
	// SendApprovalDecided 第一参是审批发起方 ID(approvals.initiator_id,当前固定 agent)。
	s.hub.SendApprovalDecided(decCtx.InitiatorID, map[string]any{
		"approval_id":     approvalID,
		"message_id":      decCtx.MessageID,
		"conversation_id": decCtx.ConversationID,
		"session_key":     decCtx.SessionKey,
		"confirm_id":      decCtx.ConfirmID, // slash_confirm 用；exec_approval 为空
		"decision":        actionID,
		"reason":          reason,
		"decided_by":      deciderID,
		"decided_at":      now.Format(time.RFC3339),
	})

	return newContent, nil
}
