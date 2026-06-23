// Package approval 提供审批状态机决策逻辑 + dispatch 编排。
package approval

import (
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
	MarkDecided(id, actionID, userID, reason string, allowPattern *string) error
	MarkExpired(id string) error
	MatchAllowPattern(convID, agentID, command string) (bool, error)
}

// Hubber service 依赖的 hub 接口（避免直接依赖 hub 包造成循环 import）。
type Hubber interface {
	BroadcastMessageUpdate(userID, agentID, messageID, conversationID string, content json.RawMessage)
	SendApprovalDecided(agentID string, payload map[string]any)
	SendApprovalExpired(agentID string, payload map[string]any)
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
// 返回更新后的 content，供 handler 直接 echo 给调用方（HTTP 响应用）。
func (s *Service) Decide(approvalID, actionID, userID, reason string) (json.RawMessage, error) {
	ctx, err := s.approvalRepo.GetForDecision(approvalID)
	if err != nil {
		return nil, err
	}
	if ctx == nil {
		return nil, ErrApprovalNotFound
	}

	// actionID 必须在 actions 列表里（防客户端瞎传）
	valid := false
	for _, a := range ctx.CardContent.Actions {
		if a.ID == actionID {
			valid = true
			break
		}
	}
	if !valid {
		return nil, ErrInvalidAction
	}

	// 仅 allow_always 写 allow_pattern（其他动作不写，避免污染白名单）
	pattern := ctx.AllowPattern
	if actionID != "allow_always" {
		pattern = nil
	}
	if err := s.repo.MarkDecided(approvalID, actionID, userID, reason, pattern); err != nil {
		return nil, err
	}

	now := time.Now().UTC()
	state := model.ApprovalStateApproved
	if actionID == "deny" {
		state = model.ApprovalStateDenied
	}
	ctx.CardContent.State = state
	ctx.CardContent.DecidedAction = &actionID
	ctx.CardContent.DecidedAt = &now
	ctx.CardContent.DecidedBy = &userID
	if reason != "" {
		ctx.CardContent.DecidedReason = &reason
	}

	wrapper := struct {
		MsgType string            `json:"msg_type"`
		Data    model.CardContent `json:"data"`
	}{MsgType: string(model.MsgTypeCard), Data: ctx.CardContent}
	newContent, err := json.Marshal(wrapper)
	if err != nil {
		return nil, err
	}
	if err := s.approvalRepo.UpdateMessageContent(ctx.MessageID, newContent); err != nil {
		return nil, err
	}

	s.hub.BroadcastMessageUpdate(ctx.UserID, ctx.AgentID, ctx.MessageID, ctx.ConversationID, newContent)
	s.hub.SendApprovalDecided(ctx.AgentID, map[string]any{
		"approval_id":     approvalID,
		"message_id":      ctx.MessageID,
		"conversation_id": ctx.ConversationID,
		"session_key":     ctx.SessionKey,
		"decision":        actionID,
		"reason":          reason,
		"decided_by":      userID,
		"decided_at":      now.Format(time.RFC3339),
	})

	return newContent, nil
}
