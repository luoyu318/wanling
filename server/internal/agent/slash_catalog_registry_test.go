package agent

import (
	"testing"
	"time"

	"github.com/wanling/server/internal/model"
)

func TestSlashCatalogRegistry_GetEmpty(t *testing.T) {
	r := NewSlashCatalogRegistry()
	cmds, updated := r.Get("agent-1")
	if len(cmds) != 0 {
		t.Fatalf("期望空切片,实际 %v", cmds)
	}
	if !updated.IsZero() {
		t.Fatalf("未上报时期望 zero time,实际 %v", updated)
	}
}

func TestSlashCatalogRegistry_UpdateAndGet(t *testing.T) {
	r := NewSlashCatalogRegistry()
	r.Update("agent-1", []model.SlashCommandInfo{
		{Name: "compact", Template: "/compact", Description: "压缩", Source: "command"},
	})
	cmds, updated := r.Get("agent-1")
	if len(cmds) != 1 || cmds[0].Name != "compact" {
		t.Fatalf("期望 1 条 compact,实际 %v", cmds)
	}
	if updated.IsZero() {
		t.Fatalf("已上报期望非 zero time")
	}
	if updated.After(time.Now().Add(time.Second)) {
		t.Fatalf("updated 不应在未来,实际 %v", updated)
	}
}

func TestSlashCatalogRegistry_UpdateOverwrites(t *testing.T) {
	r := NewSlashCatalogRegistry()
	r.Update("agent-1", []model.SlashCommandInfo{{Name: "compact"}})
	r.Update("agent-1", []model.SlashCommandInfo{{Name: "new"}, {Name: "init"}})
	cmds, _ := r.Get("agent-1")
	if len(cmds) != 2 {
		t.Fatalf("覆盖后期望 2 条,实际 %d", len(cmds))
	}
	if cmds[0].Name != "new" {
		t.Fatalf("期望首条 new,实际 %s", cmds[0].Name)
	}
}

func TestSlashCatalogRegistry_NilCoercedToEmpty(t *testing.T) {
	r := NewSlashCatalogRegistry()
	r.Update("agent-1", nil)
	cmds, _ := r.Get("agent-1")
	if cmds == nil {
		t.Fatalf("nil 入参应被强制为空切片,不应返 nil")
	}
	if len(cmds) != 0 {
		t.Fatalf("强制后应空,实际 %v", cmds)
	}
}

func TestSlashCatalogRegistry_MultiAgentIsolated(t *testing.T) {
	r := NewSlashCatalogRegistry()
	r.Update("a1", []model.SlashCommandInfo{{Name: "compact"}})
	r.Update("a2", []model.SlashCommandInfo{{Name: "new"}})
	c1, _ := r.Get("a1")
	c2, _ := r.Get("a2")
	if len(c1) != 1 || c1[0].Name != "compact" {
		t.Fatalf("a1 应隔离,实际 %v", c1)
	}
	if len(c2) != 1 || c2[0].Name != "new" {
		t.Fatalf("a2 应隔离,实际 %v", c2)
	}
}

func TestSlashCatalogRegistry_GetReturnsCopy(t *testing.T) {
	r := NewSlashCatalogRegistry()
	r.Update("agent-1", []model.SlashCommandInfo{{Name: "compact"}})
	cmds, _ := r.Get("agent-1")
	cmds[0].Name = "tampered"
	again, _ := r.Get("agent-1")
	if again[0].Name != "compact" {
		t.Fatalf("Get 应返防御性拷贝,外部修改不应污染内部,实际 %s", again[0].Name)
	}
}
