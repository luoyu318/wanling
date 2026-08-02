package agent

import (
	"sync"
	"testing"

	"github.com/wanling/server/internal/model"
)

func TestCapabilityRegistry_UpdateAndGet(t *testing.T) {
	r := NewCapabilityRegistry()
	methods := []model.RpcMethod{
		{Name: "echo", TimeoutHintMs: 3000},
		{Name: "file.read", TimeoutHintMs: 5000},
	}
	r.Update("agent-1", methods)

	got, updated := r.Get("agent-1")
	if len(got) != 2 {
		t.Fatalf("want 2 methods, got %d", len(got))
	}
	if got[0].Name != "echo" || got[0].TimeoutHintMs != 3000 {
		t.Errorf("got[0] = %+v", got[0])
	}
	if got[1].Name != "file.read" || got[1].TimeoutHintMs != 5000 {
		t.Errorf("got[1] = %+v", got[1])
	}
	if updated.IsZero() {
		t.Errorf("updated_at 不应是 zero time")
	}
}

func TestCapabilityRegistry_GetMissing(t *testing.T) {
	r := NewCapabilityRegistry()
	got, updated := r.Get("never-reported")
	if len(got) != 0 {
		t.Errorf("未上报应返空切片, got %d", len(got))
	}
	if !updated.IsZero() {
		t.Errorf("未上报 updated_at 应是 zero time")
	}
}

func TestCapabilityRegistry_UpdateNilTransfersToEmpty(t *testing.T) {
	r := NewCapabilityRegistry()
	r.Update("agent-1", nil)

	got, updated := r.Get("agent-1")
	if len(got) != 0 {
		t.Errorf("nil 应转空切片, got %d", len(got))
	}
	if updated.IsZero() {
		t.Errorf("已上报过 nil,updated_at 不应是 zero")
	}
}

func TestCapabilityRegistry_UpdateOverwrites(t *testing.T) {
	r := NewCapabilityRegistry()
	r.Update("agent-1", []model.RpcMethod{{Name: "echo", TimeoutHintMs: 3000}})
	r.Update("agent-1", []model.RpcMethod{{Name: "file.read", TimeoutHintMs: 5000}})

	got, _ := r.Get("agent-1")
	if len(got) != 1 || got[0].Name != "file.read" {
		t.Errorf("应全量覆盖, got %+v", got)
	}
}

func TestCapabilityRegistry_Has(t *testing.T) {
	r := NewCapabilityRegistry()
	r.Update("agent-1", []model.RpcMethod{{Name: "echo"}})

	if !r.Has("agent-1", "echo") {
		t.Errorf("Has(agent-1, echo) 应为 true")
	}
	if r.Has("agent-1", "missing") {
		t.Errorf("Has(agent-1, missing) 应为 false")
	}
	if r.Has("agent-2", "echo") {
		t.Errorf("Has(agent-2 未上报) 应为 false")
	}
}

func TestCapabilityRegistry_DefensiveCopy(t *testing.T) {
	r := NewCapabilityRegistry()
	original := []model.RpcMethod{{Name: "echo", TimeoutHintMs: 3000}}
	r.Update("agent-1", original)

	got, _ := r.Get("agent-1")
	got[0].Name = "mutated"

	got2, _ := r.Get("agent-1")
	if got2[0].Name != "echo" {
		t.Errorf("外部修改不应影响 registry 内部, got %s", got2[0].Name)
	}
}

func TestCapabilityRegistry_ConcurrentSafe(t *testing.T) {
	r := NewCapabilityRegistry()
	var wg sync.WaitGroup

	for i := 0; i < 100; i++ {
		wg.Add(2)
		agentID := "agent-" + string(rune('A'+i%26))
		go func() {
			defer wg.Done()
			r.Update(agentID, []model.RpcMethod{{Name: "echo"}})
		}()
		go func() {
			defer wg.Done()
			r.Get(agentID)
			r.Has(agentID, "echo")
		}()
	}
	wg.Wait()
}
