package approval

import (
	"context"
	"runtime/debug"
	"time"

	logpkg "github.com/wanling/server/internal/log"
)

// ExpiredApproval cleanup goroutine 扫描结果（精简字段，避免把整张审批表行透传）。
type ExpiredApproval struct {
	ID          string
	MessageID   string
	ConvID      string
	InitiatorID string
	SessionKey  string
}

// ExpiredFinder cleanup 需要的查询接口（独立于 Repositorier，便于测试 mock）。
type ExpiredFinder interface {
	FindExpired(ctx context.Context, now time.Time) ([]*ExpiredApproval, error)
}

// Marker cleanup 需要的状态推进接口。
type Marker interface {
	MarkExpired(ctx context.Context, id string) error
}

// RunCleanup 后台定时扫超时审批，标记 expired 并广播 APPROVAL_EXPIRED。
// 设计为 goroutine 调用：go RunCleanup(ctx, finder, marker, hub, time.Minute)。
// 启动时先跑一次，避免重启后第一轮要等整个 interval。
//
// 每 tick 派生 10s 超时 ctx,防 DB 慢查询 hang 后台 goroutine(影响后续 tick 节奏 +
// dispatch APPROVAL_EXPIRED 链路)。tick 间互不影响,tick 超时直接 cancel 进入下一轮。
func RunCleanup(ctx context.Context, finder ExpiredFinder, marker Marker, hub Hubber, interval time.Duration) {
	defer func() {
		if r := recover(); r != nil {
			logpkg.FromCtx(ctx).ErrorContext(ctx, "approval cleanup panic",
				"recover", r, "stack", string(debug.Stack()))
		}
	}()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	cleanupOnce(ctx, finder, marker, hub, time.Now())

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			cleanupOnce(ctx, finder, marker, hub, time.Now())
		}
	}
}

func cleanupOnce(ctx context.Context, finder ExpiredFinder, marker Marker, hub Hubber, now time.Time) {
	// 单 tick 内所有 repo 调用共享同一 10s 超时 ctx,tick 结束统一 cancel。
	tickCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	expired, err := finder.FindExpired(tickCtx, now)
	if err != nil {
		logpkg.FromCtx(tickCtx).ErrorContext(tickCtx, "approval-cleanup 扫超时审批失败", "err", err)
		return
	}
	for _, a := range expired {
		if err := marker.MarkExpired(tickCtx, a.ID); err != nil {
			logpkg.FromCtx(tickCtx).ErrorContext(tickCtx, "approval-cleanup MarkExpired 失败",
				"approval_id", a.ID, "err", err)
			continue
		}
		hub.SendApprovalExpired(a.InitiatorID, map[string]any{
			"approval_id":     a.ID,
			"message_id":      a.MessageID,
			"conversation_id": a.ConvID,
			"session_key":     a.SessionKey,
			"expired_at":      now.Format(time.RFC3339),
		})
	}
	if len(expired) > 0 {
		logpkg.FromCtx(tickCtx).InfoContext(tickCtx, "approval-cleanup 标记审批为 expired",
			"count", len(expired))
	}
}

// FindExpired 让 *Service 满足 ExpiredFinder 接口。
// 把 model.Approval → ExpiredApproval 适配，仅暴露 cleanup 所需字段。
func (s *Service) FindExpired(ctx context.Context, now time.Time) ([]*ExpiredApproval, error) {
	raw, err := s.approvalRepo.FindExpired(ctx, now)
	if err != nil {
		return nil, err
	}
	out := make([]*ExpiredApproval, 0, len(raw))
	for _, a := range raw {
		out = append(out, &ExpiredApproval{
			ID:          a.ID,
			MessageID:   a.MessageID,
			ConvID:      a.ConversationID,
			InitiatorID: a.InitiatorID,
			SessionKey:  a.SessionKey,
		})
	}
	return out, nil
}

// MarkExpired 让 *Service 满足 Marker 接口。
func (s *Service) MarkExpired(ctx context.Context, id string) error {
	return s.repo.MarkExpired(ctx, id)
}

// 编译期检查 *Service 满足 cleanup 需要的接口
var (
	_ ExpiredFinder = (*Service)(nil)
	_ Marker        = (*Service)(nil)
)
