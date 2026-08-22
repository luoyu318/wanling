package agent

import (
	"testing"
	"time"

	"github.com/wanling/server/internal/model"
)

func TestPresetRegistry_GetEmpty(t *testing.T) {
	r := NewPresetRegistry()
	presets, updated := r.Get("agent-1")
	if len(presets) != 0 {
		t.Fatalf("期望空切片,实际 %v", presets)
	}
	if !updated.IsZero() {
		t.Fatalf("未上报时期望 zero time,实际 %v", updated)
	}
}

func TestPresetRegistry_UpdateAndGet(t *testing.T) {
	r := NewPresetRegistry()
	r.Update("agent-1", []model.AgentPresetInfo{
		{ID: "standard", Label: "标准", Trust: "system", Order: 1},
		{ID: "my-agent", Label: "我的定制", Trust: "user"},
	})
	presets, updated := r.Get("agent-1")
	if len(presets) != 2 || presets[1].Trust != "user" {
		t.Fatalf("期望 2 条(第 2 条 user trust),实际 %v", presets)
	}
	if updated.IsZero() {
		t.Fatalf("已上报期望非 zero time")
	}
	if updated.After(time.Now().Add(time.Second)) {
		t.Fatalf("updated 不应在未来,实际 %v", updated)
	}
}

func TestPresetRegistry_UpdateOverwrites(t *testing.T) {
	r := NewPresetRegistry()
	r.Update("agent-1", []model.AgentPresetInfo{{ID: "standard"}})
	r.Update("agent-1", []model.AgentPresetInfo{{ID: "minimal"}, {ID: "code"}})
	presets, _ := r.Get("agent-1")
	if len(presets) != 2 || presets[0].ID != "minimal" {
		t.Fatalf("覆盖后期望 2 条且首条 minimal,实际 %v", presets)
	}
}

func TestPresetRegistry_NilCoercedToEmpty(t *testing.T) {
	r := NewPresetRegistry()
	r.Update("agent-1", nil)
	presets, _ := r.Get("agent-1")
	if presets == nil || len(presets) != 0 {
		t.Fatalf("nil 入参应被强制为空切片,实际 %v", presets)
	}
}

func TestPresetRegistry_DefensiveCopy(t *testing.T) {
	r := NewPresetRegistry()
	r.Update("agent-1", []model.AgentPresetInfo{{ID: "standard"}})
	got, _ := r.Get("agent-1")
	got[0].ID = "tampered"
	again, _ := r.Get("agent-1")
	if again[0].ID != "standard" {
		t.Fatalf("防御性拷贝失效:外部修改污染内部状态,实际 %v", again)
	}
}
