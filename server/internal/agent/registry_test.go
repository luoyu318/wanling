package agent

import (
	"sync"
	"testing"

	"github.com/wanling/server/internal/model"
)

func TestAgentRegistry_GetEmpty(t *testing.T) {
	r := NewAgentRegistry()
	models, updated := r.Get("agt-nonexistent")
	if len(models) != 0 {
		t.Fatalf("期望空切片,实际 %d 条", len(models))
	}
	if !updated.IsZero() {
		t.Fatalf("未上报时期望 zero time,实际 %v", updated)
	}
}

func TestAgentRegistry_UpdateAndGet(t *testing.T) {
	r := NewAgentRegistry()
	models := []model.ModelInfo{
		{ProviderID: "zhipuai", ProviderName: "Zhipuai", ModelID: "glm-5.2", ModelName: "GLM-5.2"},
	}
	r.Update("agt-1", models)
	got, updated := r.Get("agt-1")
	if len(got) != 1 || got[0].ModelID != "glm-5.2" {
		t.Fatalf("期望 1 条 glm-5.2,实际 %v", got)
	}
	if updated.IsZero() {
		t.Fatalf("已上报期望非 zero time")
	}
}

func TestAgentRegistry_UpdateOverwrites(t *testing.T) {
	r := NewAgentRegistry()
	r.Update("agt-1", []model.ModelInfo{{ProviderID: "a", ModelID: "m1"}})
	r.Update("agt-1", []model.ModelInfo{{ProviderID: "b", ModelID: "m2"}})
	got, _ := r.Get("agt-1")
	if len(got) != 1 || got[0].ModelID != "m2" {
		t.Fatalf("期望全量覆盖为 m2,实际 %v", got)
	}
}

func TestAgentRegistry_MultiAgentIsolated(t *testing.T) {
	r := NewAgentRegistry()
	r.Update("agt-1", []model.ModelInfo{{ModelID: "m1"}})
	r.Update("agt-2", []model.ModelInfo{{ModelID: "m2"}})
	got1, _ := r.Get("agt-1")
	got2, _ := r.Get("agt-2")
	if len(got1) != 1 || got1[0].ModelID != "m1" {
		t.Fatalf("agt-1 期望 m1,实际 %v", got1)
	}
	if len(got2) != 1 || got2[0].ModelID != "m2" {
		t.Fatalf("agt-2 期望 m2,实际 %v", got2)
	}
}

func TestAgentRegistry_ConcurrentSafe(t *testing.T) {
	r := NewAgentRegistry()
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(2)
		agentID := "agt-concurrent"
		go func() {
			defer wg.Done()
			r.Update(agentID, []model.ModelInfo{{ModelID: "m"}})
		}()
		go func() {
			defer wg.Done()
			r.Get(agentID)
		}()
	}
	wg.Wait()
}
