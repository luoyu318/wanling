package agent

import (
	"sync"
	"time"

	"github.com/wanling/server/internal/model"
)

type CapabilityRegistry struct {
	mu      sync.RWMutex
	entries map[string]capabilityEntry
}

type capabilityEntry struct {
	methods   []model.RpcMethod
	updatedAt time.Time
}

func NewCapabilityRegistry() *CapabilityRegistry {
	return &CapabilityRegistry{entries: make(map[string]capabilityEntry)}
}

func (r *CapabilityRegistry) Update(agentID string, methods []model.RpcMethod) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if methods == nil {
		methods = []model.RpcMethod{}
	}
	r.entries[agentID] = capabilityEntry{methods: methods, updatedAt: time.Now()}
}

func (r *CapabilityRegistry) Get(agentID string) ([]model.RpcMethod, time.Time) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.entries[agentID]
	if !ok {
		return []model.RpcMethod{}, time.Time{}
	}
	out := make([]model.RpcMethod, len(e.methods))
	copy(out, e.methods)
	return out, e.updatedAt
}

func (r *CapabilityRegistry) Has(agentID, methodName string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.entries[agentID]
	if !ok {
		return false
	}
	for _, m := range e.methods {
		if m.Name == methodName {
			return true
		}
	}
	return false
}
