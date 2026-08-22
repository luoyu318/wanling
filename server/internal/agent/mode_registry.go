package agent

import (
	"sync"
	"time"

	"github.com/wanling/server/internal/model"
)

// ModeRegistry 内存缓存 plugin 上报的模式清单（对应 AGENT_MODES 事件）。
// 与 SlashCatalogRegistry 同构：进程级单例（main.go 创建），server 重启
// 清空，plugin 重连后重报。
type ModeRegistry struct {
	mu      sync.RWMutex
	entries map[string]modeEntry
}

type modeEntry struct {
	modes     []model.AgentModeInfo
	updatedAt time.Time
}

func NewModeRegistry() *ModeRegistry {
	return &ModeRegistry{entries: make(map[string]modeEntry)}
}

// Update 全量覆盖某 agent 的模式清单。
func (r *ModeRegistry) Update(agentID string, modes []model.AgentModeInfo) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if modes == nil {
		modes = []model.AgentModeInfo{}
	}
	r.entries[agentID] = modeEntry{modes: modes, updatedAt: time.Now()}
}

// Get 取某 agent 的模式清单 + 最近上报时间。未上报时返空切片 + zero time。
// 返回切片是防御性拷贝，调用方修改不会污染 registry 内部状态。
func (r *ModeRegistry) Get(agentID string) ([]model.AgentModeInfo, time.Time) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.entries[agentID]
	if !ok {
		return []model.AgentModeInfo{}, time.Time{}
	}
	out := make([]model.AgentModeInfo, len(e.modes))
	copy(out, e.modes)
	return out, e.updatedAt
}
