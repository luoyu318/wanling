package hub

import (
	"context"
	"encoding/json"
	"sync"
	"time"

	"github.com/google/uuid"
)

const (
	rpcErrTimeout      = -32002
	rpcErrDisconnected = -32003
)

// rpcDefaultTimeout 用 var 而非 const,以便测试通过 t.Cleanup 临时调小,
// 避免 DefaultTimeout 用例真等 60s 拖慢 CI。
var rpcDefaultTimeout = 60 * time.Second

// RPCError 是 JSON-RPC 2.0 的 error 对象,透传给 APP。
// 万灵扩展码从 -32000 起:-32002 plugin_timeout / -32003 plugin_disconnected。
type RPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// RPCResponse 是 RPCRegistry 投递给等待方的响应。
// Result 和 Err 互斥:成功填 Result,失败填 Err。
// Result 用 json.RawMessage 透传,Registry 不关心 result schema。
type RPCResponse struct {
	Result json.RawMessage `json:"result,omitempty"`
	Err    *RPCError       `json:"error,omitempty"`
}

// rpcPending 是一个在途 RPC 调用。
// cancel 由 Register 创建(派生自调用方 ctx + 默认超时兜底),
// 在 Resolve/Cancel/CancelAllForAgent 时主动调用,确保超时 goroutine 不泄漏。
type rpcPending struct {
	ch      chan *RPCResponse
	agentID string
	cancel  context.CancelFunc
}

// RPCRegistry 内存维护在途 RPC 的 pending map。
// 进程级单例(main.go 创建),无持久化。
// 并发安全:所有方法用 sync.Mutex 保护。
type RPCRegistry struct {
	mu      sync.Mutex
	pending map[string]*rpcPending
}

func NewRPCRegistry() *RPCRegistry {
	return &RPCRegistry{pending: make(map[string]*rpcPending)}
}

// Register 创建一个 pending RPC 记录,返回唯一 id 和接收响应的 channel。
//
// 设计要点:
//  1. agentID 由调用方明确传入(不是 Registry 的全局状态),避免并发请求互相覆盖。
//  2. ctx 派生统一走 WithTimeout(ctx, rpcDefaultTimeout):caller ctx 已有 deadline 时
//     Go 标准库会自动取 min(parent, now+rpcDefaultTimeout),即继承 caller deadline;
//     caller ctx 无 deadline 时由 rpcDefaultTimeout 兜底,防止 plugin 卡死时 pending 永久泄漏。
//  3. cancel 函数存进 pending,Resolve/Cancel 时主动调用,确保超时 goroutine 退出。
//  4. channel buffer = 1,确保 Resolve/cancelOne 即使等待方已超时退出也不会阻塞。
//  5. id 生成 + ctx 派生 + cancel 创建在锁外完成,锁内只做 map 写入,缩小临界区。
func (r *RPCRegistry) Register(ctx context.Context, agentID string) (string, <-chan *RPCResponse) {
	id := uuid.NewString()
	ch := make(chan *RPCResponse, 1)
	// WithTimeout 在 caller ctx 有 deadline 时自动取 min(parent, now+rpcDefaultTimeout),
	// 因此无需再分 WithCancel / WithTimeout 两个分支。
	regCtx, cancel := context.WithTimeout(ctx, rpcDefaultTimeout)
	p := &rpcPending{ch: ch, agentID: agentID, cancel: cancel}

	r.mu.Lock()
	r.pending[id] = p
	r.mu.Unlock()

	// 超时监听 goroutine:ctx Done 后自动 cancelOne + 主动调用 cancel 清理
	go func() {
		<-regCtx.Done()
		err := &RPCError{Code: rpcErrTimeout, Message: "plugin timeout"}
		r.cancelOne(id, err)
	}()

	return id, ch
}

// Resolve 投递响应给等待方,返回 true 表示成功匹配。
// 已超时/cancel/已 Resolve 的 id 返回 false(等待方已被告知过结果)。
// 成功后主动调用 cancel() 让超时 goroutine 退出。
func (r *RPCRegistry) Resolve(id string, resp *RPCResponse) bool {
	r.mu.Lock()
	p, ok := r.pending[id]
	if ok {
		delete(r.pending, id)
	}
	r.mu.Unlock()
	if !ok {
		return false
	}
	// 投递响应(非阻塞,buffer=1 保证投递成功)
	p.ch <- resp
	// 主动 cancel 让超时监听 goroutine 退出
	p.cancel()
	return true
}

// Cancel 手动取消单个 pending(超时语义),一般仅用于 server 主动放弃。
// 实际场景由 ctx 超时或 CancelAllForAgent 驱动。
func (r *RPCRegistry) Cancel(id string) {
	r.cancelOne(id, &RPCError{Code: rpcErrTimeout, Message: "plugin timeout"})
}

// CancelAllForAgent 取消某 agent 名下所有 pending。
// plugin WS 断线时由 hub.Unregister 调用,让 APP 收到 -32003 而非等到超时。
func (r *RPCRegistry) CancelAllForAgent(agentID string) {
	r.mu.Lock()
	ids := make([]string, 0)
	for id, p := range r.pending {
		if p.agentID == agentID {
			ids = append(ids, id)
		}
	}
	r.mu.Unlock()
	for _, id := range ids {
		r.cancelOne(id, &RPCError{Code: rpcErrDisconnected, Message: "plugin disconnected"})
	}
}

// cancelOne 是 Resolve/Cancel/CancelAllForAgent 的共享实现。
// 从 pending 删除 + 投递 error + 主动 cancel 超时 goroutine。
// 已不在 pending 的 id 静默忽略(幂等)。
func (r *RPCRegistry) cancelOne(id string, err *RPCError) {
	r.mu.Lock()
	p, ok := r.pending[id]
	if ok {
		delete(r.pending, id)
	}
	r.mu.Unlock()
	if !ok {
		return
	}
	// 投递 error(非阻塞,buffer=1 保证投递成功)
	p.ch <- &RPCResponse{Err: err}
	// 主动 cancel 让超时监听 goroutine 退出
	p.cancel()
}
