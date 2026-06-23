package approval

import (
	"context"
	"log"
	"time"
)

// ExpiredApproval cleanup goroutine 扫描结果（精简字段，避免把整张审批表行透传）。
type ExpiredApproval struct {
	ID         string
	MessageID  string
	ConvID     string
	AgentID    string
	UserID     string
	SessionKey string
}

// ExpiredFinder cleanup 需要的查询接口（独立于 Repositorier，便于测试 mock）。
type ExpiredFinder interface {
	FindExpired(now time.Time) ([]*ExpiredApproval, error)
}

// Marker cleanup 需要的状态推进接口。
type Marker interface {
	MarkExpired(id string) error
}

// RunCleanup 后台定时扫超时审批，标记 expired 并广播 APPROVAL_EXPIRED。
// 设计为 goroutine 调用：go RunCleanup(ctx, finder, marker, hub, time.Minute)。
// 启动时先跑一次，避免重启后第一轮要等整个 interval。
func RunCleanup(ctx context.Context, finder ExpiredFinder, marker Marker, hub Hubber, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	cleanupOnce(finder, marker, hub, time.Now())

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			cleanupOnce(finder, marker, hub, time.Now())
		}
	}
}

func cleanupOnce(finder ExpiredFinder, marker Marker, hub Hubber, now time.Time) {
	expired, err := finder.FindExpired(now)
	if err != nil {
		log.Printf("[approval-cleanup] 扫超时审批失败: %v", err)
		return
	}
	for _, a := range expired {
		if err := marker.MarkExpired(a.ID); err != nil {
			log.Printf("[approval-cleanup] MarkExpired %s 失败: %v", a.ID, err)
			continue
		}
		hub.SendApprovalExpired(a.AgentID, map[string]any{
			"approval_id":     a.ID,
			"message_id":      a.MessageID,
			"conversation_id": a.ConvID,
			"session_key":     a.SessionKey,
			"expired_at":      now.Format(time.RFC3339),
		})
	}
	if len(expired) > 0 {
		log.Printf("[approval-cleanup] 标记 %d 条审批为 expired", len(expired))
	}
}

// FindExpired 让 *Service 满足 ExpiredFinder 接口。
// 把 model.Approval → ExpiredApproval 适配，仅暴露 cleanup 所需字段。
func (s *Service) FindExpired(now time.Time) ([]*ExpiredApproval, error) {
	raw, err := s.approvalRepo.FindExpired(now)
	if err != nil {
		return nil, err
	}
	out := make([]*ExpiredApproval, 0, len(raw))
	for _, a := range raw {
		out = append(out, &ExpiredApproval{
			ID:         a.ID,
			MessageID:  a.MessageID,
			ConvID:     a.ConversationID,
			AgentID:    a.AgentID,
			UserID:     a.UserID,
			SessionKey: a.SessionKey,
		})
	}
	return out, nil
}

// MarkExpired 让 *Service 满足 Marker 接口。
func (s *Service) MarkExpired(id string) error {
	return s.repo.MarkExpired(id)
}

// 编译期检查 *Service 满足 cleanup 需要的接口
var (
	_ ExpiredFinder = (*Service)(nil)
	_ Marker        = (*Service)(nil)
)
