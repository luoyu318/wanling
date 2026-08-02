// Package agent 提供 agent 级别的运行时状态服务。
// 当前职责：缓存 plugin 上报的可选模型清单（AgentRegistry）+ 命令清单（SlashCatalogRegistry）。
// 不持久化 — 模型/命令清单是 opencode 运行时配置镜像，plugin 每次连上重报天然刷新，
// DB 持久化反而存过期快照。
package agent

import (
	"sync"
	"time"

	"github.com/wanling/server/internal/model"
)

// AgentRegistry 内存缓存 plugin 上报的可选模型清单。
// 进程级单例（main.go 创建），server 重启清空，plugin 重连后 1-2 秒内重新上报。
type AgentRegistry struct {
	mu      sync.RWMutex
	entries map[string]registryEntry
}

type registryEntry struct {
	models    []model.ModelInfo
	updatedAt time.Time
}

func NewAgentRegistry() *AgentRegistry {
	return &AgentRegistry{entries: make(map[string]registryEntry)}
}

// Update 全量覆盖某 agent 的模型清单。
func (r *AgentRegistry) Update(agentID string, models []model.ModelInfo) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if models == nil {
		models = []model.ModelInfo{}
	}
	r.entries[agentID] = registryEntry{models: models, updatedAt: time.Now()}
}

// Get 取某 agent 的模型清单 + 最近上报时间。
// 未上报时返空切片 + zero time。
// 返回切片是防御性拷贝，调用方修改不会污染 registry 内部状态。
func (r *AgentRegistry) Get(agentID string) ([]model.ModelInfo, time.Time) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.entries[agentID]
	if !ok {
		return []model.ModelInfo{}, time.Time{}
	}
	out := make([]model.ModelInfo, len(e.models))
	copy(out, e.models)
	return out, e.updatedAt
}
