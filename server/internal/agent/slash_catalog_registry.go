package agent

import (
	"sync"
	"time"

	"github.com/wanling/server/internal/model"
)

// SlashCatalogRegistry 内存缓存 plugin 上报的命令清单（对应 AGENT_SLASH_CATALOG 事件）。
// 进程级单例（main.go 创建），与 AgentRegistry 同构。server 重启清空，plugin 重连后重报。
type SlashCatalogRegistry struct {
	mu      sync.RWMutex
	entries map[string]slashCatalogEntry
}

type slashCatalogEntry struct {
	commands  []model.SlashCommandInfo
	updatedAt time.Time
}

func NewSlashCatalogRegistry() *SlashCatalogRegistry {
	return &SlashCatalogRegistry{entries: make(map[string]slashCatalogEntry)}
}

// Update 全量覆盖某 agent 的命令清单。
func (r *SlashCatalogRegistry) Update(agentID string, commands []model.SlashCommandInfo) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if commands == nil {
		commands = []model.SlashCommandInfo{}
	}
	r.entries[agentID] = slashCatalogEntry{commands: commands, updatedAt: time.Now()}
}

// Get 取某 agent 的命令清单 + 最近上报时间。
// 未上报时返空切片 + zero time。
// 返回切片是防御性拷贝，调用方修改不会污染 registry 内部状态。
func (r *SlashCatalogRegistry) Get(agentID string) ([]model.SlashCommandInfo, time.Time) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.entries[agentID]
	if !ok {
		return []model.SlashCommandInfo{}, time.Time{}
	}
	out := make([]model.SlashCommandInfo, len(e.commands))
	copy(out, e.commands)
	return out, e.updatedAt
}
