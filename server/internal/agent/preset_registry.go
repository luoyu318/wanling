package agent

import (
	"sync"
	"time"

	"github.com/wanling/server/internal/model"
)

// PresetRegistry 内存缓存 plugin 上报的预设清单（对应 AGENT_PRESETS 事件）。
// 与 ModeRegistry / SlashCatalogRegistry 同构：进程级单例（main.go 创建），
// server 重启清空，plugin 重连后重报。
type PresetRegistry struct {
	mu      sync.RWMutex
	entries map[string]presetEntry
}

type presetEntry struct {
	presets   []model.AgentPresetInfo
	updatedAt time.Time
}

func NewPresetRegistry() *PresetRegistry {
	return &PresetRegistry{entries: make(map[string]presetEntry)}
}

// Update 全量覆盖某 agent 的预设清单。
func (r *PresetRegistry) Update(agentID string, presets []model.AgentPresetInfo) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if presets == nil {
		presets = []model.AgentPresetInfo{}
	}
	r.entries[agentID] = presetEntry{presets: presets, updatedAt: time.Now()}
}

// Get 取某 agent 的预设清单 + 最近上报时间。未上报时返空切片 + zero time。
// 返回切片是防御性拷贝，调用方修改不会污染 registry 内部状态。
func (r *PresetRegistry) Get(agentID string) ([]model.AgentPresetInfo, time.Time) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.entries[agentID]
	if !ok {
		return []model.AgentPresetInfo{}, time.Time{}
	}
	out := make([]model.AgentPresetInfo, len(e.presets))
	copy(out, e.presets)
	return out, e.updatedAt
}
