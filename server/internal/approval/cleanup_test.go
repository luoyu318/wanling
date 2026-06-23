package approval

import (
	"context"
	"testing"
	"time"
)

// mockExpiredFinder 测试用 ExpiredFinder。
type mockExpiredFinder struct {
	items []*ExpiredApproval
	err   error
}

func (m *mockExpiredFinder) FindExpired(now time.Time) ([]*ExpiredApproval, error) {
	return m.items, m.err
}

// mockMarker 测试用 Marker，记录每次 MarkExpired 的入参。
type mockMarker struct {
	calls []string
	err   error
}

func (m *mockMarker) MarkExpired(id string) error {
	m.calls = append(m.calls, id)
	return m.err
}

func TestCleanupOnceMarksExpired(t *testing.T) {
	finder := &mockExpiredFinder{items: []*ExpiredApproval{
		{ID: "a-1", MessageID: "m-1", ConvID: "c-1", AgentID: "agent-1", SessionKey: "k-1"},
		{ID: "a-2", MessageID: "m-2", ConvID: "c-2", AgentID: "agent-2", SessionKey: "k-2"},
	}}
	marker := &mockMarker{}
	hub := &mockHub{}

	cleanupOnce(finder, marker, hub, time.Now())

	if len(marker.calls) != 2 {
		t.Fatalf("expected 2 MarkExpired calls, got %d", len(marker.calls))
	}
	if len(hub.expired) != 2 {
		t.Fatalf("expected 2 APPROVAL_EXPIRED, got %d", len(hub.expired))
	}
	if hub.expired[0]["approval_id"] != "a-1" {
		t.Fatalf("first expired wrong: %v", hub.expired[0])
	}
}

func TestCleanupOnceSkipsOnInquiryError(t *testing.T) {
	finder := &mockExpiredFinder{err: context.DeadlineExceeded}
	marker := &mockMarker{}
	hub := &mockHub{}

	cleanupOnce(finder, marker, hub, time.Now())

	if len(marker.calls) != 0 || len(hub.expired) != 0 {
		t.Fatalf("should be no-op on inquiry error")
	}
}

func TestCleanupOnceSkipsMarkerError(t *testing.T) {
	finder := &mockExpiredFinder{items: []*ExpiredApproval{{ID: "a-1", AgentID: "agent-1"}}}
	marker := &mockMarker{err: context.Canceled}
	hub := &mockHub{}

	cleanupOnce(finder, marker, hub, time.Now())

	// marker 失败时不应发送 APPROVAL_EXPIRED
	if len(hub.expired) != 0 {
		t.Fatalf("should not broadcast on marker failure")
	}
}

func TestRunCleanupStopsOnContextCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	finder := &mockExpiredFinder{}
	marker := &mockMarker{}
	hub := &mockHub{}

	done := make(chan struct{})
	go func() {
		RunCleanup(ctx, finder, marker, hub, 10*time.Millisecond)
		close(done)
	}()
	time.Sleep(50 * time.Millisecond) // 让 ticker 跑几轮
	cancel()
	select {
	case <-done:
		// OK
	case <-time.After(time.Second):
		t.Fatal("RunCleanup did not exit after ctx cancel")
	}
}
