package handler

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/agent"
	"github.com/wanling/server/internal/hub"
	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// JSON-RPC 万灵扩展错误码(详见 docs/superpowers/specs/2026-07-19-rpc-protocol-design.md §5):
//   - -32001 plugin_offline: plugin WS 不在线,server 无法转 OpPluginCall
//   - -32002 plugin_timeout: ctx 超时,plugin 没在窗口内回包
//   - -32003 plugin_disconnected: 等待中 plugin WS 断线(由 RPCRegistry.CancelAllForAgent 触发)
//
// 与 JSON-RPC 2.0 保留段(-32000 ~ -32099)一致。
const (
	rpcErrPluginOffline = -32001
	rpcErrPluginTimeout = -32002
	// rpcErrPluginDisconnected 等待中 plugin 断线,对称 hub.rpcErrDisconnected。
	// hub 包内常量为私有(-32003),这里本地镜像同值,handler 据此区分 503 vs 504。
	rpcErrPluginDisconnected = -32003

	// rpcGlobalTimeout 是 RPC 默认兜底超时(请求未传 timeout_ms 或传 0/负值时用)。
	// 请求 timeout_ms > 0 时取 min(rpcGlobalTimeout, timeout_ms),防止 APP 端传超大值
	// 卡住 server goroutine。具体生效由 RPCRegistry 内部 ctx 派生 + 本 handler 派生双重保证。
	rpcGlobalTimeout = 60 * time.Second
)

// RPCHandler 处理 POST /api/agents/:id/rpc:APP 通过 HTTP 调 plugin RPC,
// server 转 OpPluginCall WS,等回包后返 HTTP 响应(JSON-RPC 2.0 envelope)。
//
// 与 REST envelope {ok, data, error} 不同:RPC 端点遵循 JSON-RPC 2.0 形态,
// 成功返 {"result": <T>},失败返 {"error": {"code": <int>, "message": "..."}}。
// 详见 docs/superpowers/specs/2026-07-19-rpc-protocol-design.md §6.1。
//
// pre-RPC 验证失败(IDOR/not_found/bad_request)仍走 wanling REST envelope(Err helper),
// 与其他 agent REST 端点保持一致 — 这些错误发生在 RPC 协议入口之前。
type RPCHandler struct {
	agentRepo          *repository.AgentRepo
	hub                *hub.Hub
	registry           *hub.RPCRegistry
	capabilityRegistry *agent.CapabilityRegistry
	convRepo           *repository.ConversationRepo
}

// NewRPCHandler 创建 RPC handler 实例。
// agentRepo / hub / registry / capabilityRegistry / convRepo 均为 main.go 单例,handler 不持有可变状态,可并发调用。
func NewRPCHandler(agentRepo *repository.AgentRepo, h *hub.Hub, reg *hub.RPCRegistry, capReg *agent.CapabilityRegistry, convRepo *repository.ConversationRepo) *RPCHandler {
	return &RPCHandler{agentRepo: agentRepo, hub: h, registry: reg, capabilityRegistry: capReg, convRepo: convRepo}
}

// rpcCallRequest 是 POST /rpc 的请求体。
// Params 用 json.RawMessage 透传给 plugin,server 不关心 schema。
// TimeoutMS 为 0/负值时使用 rpcGlobalTimeout 兜底;正值时取 min(rpcGlobalTimeout, TimeoutMS)。
type rpcCallRequest struct {
	Method    string          `json:"method" binding:"required"`
	Params    json.RawMessage `json:"params"`
	TimeoutMS int             `json:"timeout_ms"`
}

// Call 处理一次 RPC 调用,流程:
//  1. IDOR 校验:user 必须是 agent.OwnerID
//  2. body 解析:method 必填,params 透传
//  3. plugin 在线校验:hub.GetClient("agent", agentID) 不存在 → 503 + -32001
//  4. 派生 ctx 超时:min(rpcGlobalTimeout, req.TimeoutMS)
//  5. registry.Register(ctx, agentID) → 拿到 rpc id + 响应 channel
//  6. SendToAgent 发 OpPluginCall(失败 cancel + 500)
//  7. select ch / ctx.Done → 200+result / 504+-32002 / 503+-32003
func (h *RPCHandler) Call(c *gin.Context) {
	agentID := c.Param("id")
	userID := c.GetString("userID")

	ag, err := h.agentRepo.GetByID(c.Request.Context(), agentID)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if ag == nil {
		Err(c, http.StatusNotFound, "not_found", "Agent 不存在")
		return
	}
	if ag.OwnerID != userID {
		Err(c, http.StatusForbidden, "forbidden", "无权操作该 Agent")
		return
	}

	var req rpcCallRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	if _, ok := h.hub.GetClient("agent", agentID); !ok {
		c.JSON(http.StatusServiceUnavailable, gin.H{
			"error": gin.H{"code": rpcErrPluginOffline, "message": "plugin offline"},
		})
		return
	}

	timeout := rpcGlobalTimeout
	if req.TimeoutMS > 0 {
		if d := time.Duration(req.TimeoutMS) * time.Millisecond; d < timeout {
			timeout = d
		}
	}

	ctx, cancel := context.WithTimeout(c.Request.Context(), timeout)
	defer cancel()

	id, ch := h.registry.Register(ctx, agentID)

	// 注入 conversations.directory 到 params：如果 params 含 wanling_conv_id，
	// 从 DB 查 conversations.directory 作为可信目录锚注入，供 plugin 绕过 mapper 缺失场景。
	// plugin 端不应相信自身不受 server 控制的 directory 来源。
	req.Params = h.injectConvDirectory(ctx, req.Params)

	call := gin.H{
		"jsonrpc": "2.0", "id": id,
		"method": req.Method, "params": req.Params,
	}
	callBytes, _ := json.Marshal(call)
	if err := h.hub.SendToAgent(agentID, &model.WSMessage{Op: model.OpPluginCall, D: callBytes}); err != nil {
		h.registry.Cancel(id)
		ErrMsg(c, http.StatusInternalServerError, "send_to_plugin_failed")
		return
	}

	select {
	case got := <-ch:
		if got.Err != nil {
			status := http.StatusGatewayTimeout
			if got.Err.Code == rpcErrPluginDisconnected {
				status = http.StatusServiceUnavailable
			}
			c.JSON(status, gin.H{"error": got.Err})
			return
		}
		c.JSON(http.StatusOK, gin.H{"result": json.RawMessage(got.Result)})
	case <-ctx.Done():
		logpkg.FromCtx(c.Request.Context()).WarnContext(c.Request.Context(),
			"RPC 超时", "rpc_id", id, "agent_id", agentID, "method", req.Method)
		c.JSON(http.StatusGatewayTimeout, gin.H{
			"error": gin.H{"code": rpcErrPluginTimeout, "message": "plugin timeout"},
		})
	}
}

// Methods 返回某 agent 的 RPC 方法清单(plugin 通过 WS PLUGIN_CAPABILITIES 上报,内存缓存)。
// 对称 agent_handler.Models,IDOR 防护:仅 owner 可查自己 agent 的方法清单。
// 空清单(plugin 未上报 / server 重启)返 200 + methods=[] + updated_at=null。
func (h *RPCHandler) Methods(c *gin.Context) {
	agentID := c.Param("id")
	userID := c.GetString("userID")

	ag, err := h.agentRepo.GetByID(c.Request.Context(), agentID)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return
	}
	if ag == nil {
		Err(c, http.StatusNotFound, "not_found", "Agent 不存在")
		return
	}
	if ag.OwnerID != userID {
		Err(c, http.StatusForbidden, "forbidden", "无权操作该 Agent")
		return
	}

	methods, updatedAt := h.capabilityRegistry.Get(agentID)
	// registry.Get 未上报时返 time.Time{},默认 marshal 为 "0001-01-01T00:00:00Z"。
	// spec 要求返 null,故用 any + IsZero 条件赋值:nil → JSON null,真实时间 → RFC3339 字符串。
	var updatedAtAny any
	if !updatedAt.IsZero() {
		updatedAtAny = updatedAt
	}
	Ok(c, gin.H{
		"agent_id":   agentID,
		"methods":    methods,
		"updated_at": updatedAtAny,
	})
}

// injectConvDirectory 从 wanling_conv_id 查询 DB conversations.directory,
// 注入到 params 中。plugin 拿到注入后的 directory 作为可信锚点,无需信任 APP 传入的目录。
//
// convRepo 为 nil 或查询失败时静默返回原 params,不影响 RPC 流程。
func (h *RPCHandler) injectConvDirectory(ctx context.Context, params json.RawMessage) json.RawMessage {
	if len(params) == 0 || h.convRepo == nil {
		return params
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(params, &raw); err != nil {
		return params
	}
	convIDRaw, ok := raw["wanling_conv_id"]
	if !ok || len(convIDRaw) < 2 {
		return params
	}
	var convID string
	if err := json.Unmarshal(convIDRaw, &convID); err != nil || convID == "" {
		return params
	}
	conv, err := h.convRepo.GetByID(ctx, convID)
	if err != nil || conv == nil || conv.Directory == nil || *conv.Directory == "" {
		return params
	}
	dir, _ := json.Marshal(*conv.Directory)
	raw["directory"] = dir
	merged, err := json.Marshal(raw)
	if err != nil {
		return params
	}
	return merged
}
