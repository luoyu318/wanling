package agent

import (
	"testing"
	"time"

	"github.com/wanling/server/internal/model"
)

func TestModeRegistry_GetEmpty(t *testing.T) {
	r := NewModeRegistry()
	modes, updated := r.Get("agent-1")
	if len(modes) != 0 {
		t.Fatalf("期望空切片,实际 %v", modes)
	}
	if !updated.IsZero() {
		t.Fatalf("未上报时期望 zero time,实际 %v", updated)
	}
}

func TestModeRegistry_UpdateAndGet(t *testing.T) {
	r := NewModeRegistry()
	r.Update("agent-1", []model.AgentModeInfo{
		{ID: "build", Label: "构建", Style: "default"},
		{ID: "plan", Label: "计划", Style: "plan"},
	})
	modes, updated := r.Get("agent-1")
	if len(modes) != 2 || modes[1].ID != "plan" || modes[1].Style != "plan" {
		t.Fatalf("期望 2 条(第 2 条 plan),实际 %v", modes)
	}
	if updated.IsZero() {
		t.Fatalf("已上报期望非 zero time")
	}
	if updated.After(time.Now().Add(time.Second)) {
		t.Fatalf("updated 不应在未来,实际 %v", updated)
	}
}

func TestModeRegistry_UpdateOverwrites(t *testing.T) {
	r := NewModeRegistry()
	r.Update("agent-1", []model.AgentModeInfo{{ID: "build"}})
	r.Update("agent-1", []model.AgentModeInfo{{ID: "plan"}, {ID: "code"}})
	modes, _ := r.Get("agent-1")
	if len(modes) != 2 || modes[0].ID != "plan" {
		t.Fatalf("覆盖后期望 2 条且首条 plan,实际 %v", modes)
	}
}

func TestModeRegistry_NilCoercedToEmpty(t *testing.T) {
	r := NewModeRegistry()
	r.Update("agent-1", nil)
	modes, _ := r.Get("agent-1")
	if modes == nil || len(modes) != 0 {
		t.Fatalf("nil 入参应被强制为空切片,实际 %v", modes)
	}
}

func TestModeRegistry_DefensiveCopy(t *testing.T) {
	r := NewModeRegistry()
	r.Update("agent-1", []model.AgentModeInfo{{ID: "build"}})
	got, _ := r.Get("agent-1")
	got[0].ID = "tampered"
	again, _ := r.Get("agent-1")
	if again[0].ID != "build" {
		t.Fatalf("防御性拷贝失效:外部修改污染内部状态,实际 %v", again)
	}
}
