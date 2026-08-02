package handler

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/agent"
	"github.com/wanling/server/internal/hub"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/presence"
	"github.com/wanling/server/internal/ratelimit"
	"github.com/wanling/server/internal/repository"
)

// TestRPCHandler_HappyPath 验证完整 RPC 调用链:
//   - user (owner) POST /api/agents/:id/rpc 触发 server 转 OpPluginCall
//   - plugin 模拟回 OpPluginResult(经 RPCRegistry.Resolve 投递)
//   - HTTP 响应 200 + {"result": {...}}(JSON-RPC 2.0 envelope)
//
// 不走真 WS dial,用 hub.RegisterClient 注入 mock client 模拟 plugin 在线:
//   - 通过 client.Send channel 接收 OpPluginCall 字节流
//   - 解析出 rpc id 后直接调 registry.Resolve(对称 ws_handler.routeAgentIncoming 路径)
func TestRPCHandler_HappyPath(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)

	owner, err := urepo.Create(t.Context(), shortName(t, "owner_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	ag, err := arepo.Create(t.Context(), owner.ID, "test-agent", "sk", "")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}

	hubInstance := hub.NewHub(presence.New(nil), arepo, repository.NewParticipantRepo(db), nil)
	registry := hub.NewRPCRegistry()
	h := NewRPCHandler(arepo, hubInstance, registry, agent.NewCapabilityRegistry(), nil)
	r := gin.New()
	r.POST("/api/agents/:id/rpc", func(c *gin.Context) {
		c.Set("userID", c.Query("as_user"))
		h.Call(c)
	})

	// 模拟 plugin 在线:注册 mock client 到 hub
	fakeClient := newFakeAgentClient(t, hubInstance, ag.ID)
	defer fakeClient.Close()

	body, _ := json.Marshal(map[string]any{
		"method": "echo",
		"params": map[string]any{"text": "hello"},
	})
	req := httptest.NewRequest("POST", "/api/agents/"+ag.ID+"/rpc?as_user="+owner.ID, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	// 异步模拟 plugin 处理 OpPluginCall → 回 OpPluginResult(经 registry.Resolve)
	go func() {
		resultJSON, _ := json.Marshal(map[string]any{"echo": "hello"})
		resolveFirstCall(t, fakeClient, registry, resultJSON, 2*time.Second)
	}()

	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("期望 200, 实际 %d body=%s", w.Code, w.Body.String())
	}
	var resp struct {
		Result map[string]string `json:"result"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("unmarshal: %v body=%s", err, w.Body.String())
	}
	if resp.Result["echo"] != "hello" {
		t.Fatalf("期望 result.echo=hello, 实际 %v (body=%s)", resp.Result, w.Body.String())
	}
}

// TestRPCHandler_IDOR_Forbidden 验证 IDOR 防护:非 owner 调 RPC → 403。
func TestRPCHandler_IDOR_Forbidden(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)

	owner, err := urepo.Create(t.Context(), shortName(t, "owner_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	attacker, err := urepo.Create(t.Context(), shortName(t, "atk_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create attacker: %v", err)
	}
	ag, err := arepo.Create(t.Context(), owner.ID, "test-agent", "sk", "")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}

	hubInstance := hub.NewHub(presence.New(nil), arepo, repository.NewParticipantRepo(db), nil)
	h := NewRPCHandler(arepo, hubInstance, hub.NewRPCRegistry(), agent.NewCapabilityRegistry(), nil)
	r := gin.New()
	r.POST("/api/agents/:id/rpc", func(c *gin.Context) {
		c.Set("userID", c.Query("as_user"))
		h.Call(c)
	})

	body, _ := json.Marshal(map[string]any{"method": "echo", "params": map[string]any{}})
	req := httptest.NewRequest("POST", "/api/agents/"+ag.ID+"/rpc?as_user="+attacker.ID, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	r.ServeHTTP(w, req)
	if w.Code != http.StatusForbidden {
		t.Fatalf("期望 403 (IDOR), 实际 %d body=%s", w.Code, w.Body.String())
	}
}

// TestRPCHandler_PluginOffline_503 验证 plugin 离线:hub 无 client → 503 + error.code=-32001。
func TestRPCHandler_PluginOffline_503(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)

	owner, err := urepo.Create(t.Context(), shortName(t, "owner_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	ag, err := arepo.Create(t.Context(), owner.ID, "test-agent", "sk", "")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}

	// 不注册 fake client,模拟 plugin 离线
	hubInstance := hub.NewHub(presence.New(nil), arepo, repository.NewParticipantRepo(db), nil)
	h := NewRPCHandler(arepo, hubInstance, hub.NewRPCRegistry(), agent.NewCapabilityRegistry(), nil)
	r := gin.New()
	r.POST("/api/agents/:id/rpc", func(c *gin.Context) {
		c.Set("userID", c.Query("as_user"))
		h.Call(c)
	})

	body, _ := json.Marshal(map[string]any{"method": "echo", "params": map[string]any{}})
	req := httptest.NewRequest("POST", "/api/agents/"+ag.ID+"/rpc?as_user="+owner.ID, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	r.ServeHTTP(w, req)
	if w.Code != http.StatusServiceUnavailable {
		t.Fatalf("期望 503 (plugin_offline), 实际 %d body=%s", w.Code, w.Body.String())
	}
	var errResp struct {
		Error struct {
			Code int `json:"code"`
		} `json:"error"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &errResp); err != nil {
		t.Fatalf("unmarshal: %v body=%s", err, w.Body.String())
	}
	if errResp.Error.Code != -32001 {
		t.Fatalf("期望 error.code=-32001, 实际 %d (body=%s)", errResp.Error.Code, w.Body.String())
	}
}

// TestRPCHandler_PluginTimeout_504 验证 plugin 超时:plugin 在线但不回包 → 504 + error.code=-32002。
// 用 timeout_ms=100 让测试快速跑完,不真等 60s 默认超时。
func TestRPCHandler_PluginTimeout_504(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)

	owner, err := urepo.Create(t.Context(), shortName(t, "owner_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	ag, err := arepo.Create(t.Context(), owner.ID, "test-agent", "sk", "")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}

	hubInstance := hub.NewHub(presence.New(nil), arepo, repository.NewParticipantRepo(db), nil)
	h := NewRPCHandler(arepo, hubInstance, hub.NewRPCRegistry(), agent.NewCapabilityRegistry(), nil)
	r := gin.New()
	r.POST("/api/agents/:id/rpc", func(c *gin.Context) {
		c.Set("userID", c.Query("as_user"))
		h.Call(c)
	})

	// plugin 在线但不响应
	fakeClient := newFakeAgentClient(t, hubInstance, ag.ID)
	defer fakeClient.Close()

	body, _ := json.Marshal(map[string]any{
		"method":     "echo",
		"params":     map[string]any{},
		"timeout_ms": 100,
	})
	req := httptest.NewRequest("POST", "/api/agents/"+ag.ID+"/rpc?as_user="+owner.ID, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()

	start := time.Now()
	r.ServeHTTP(w, req)
	elapsed := time.Since(start)

	if w.Code != http.StatusGatewayTimeout {
		t.Fatalf("期望 504 (plugin_timeout), 实际 %d body=%s", w.Code, w.Body.String())
	}
	// 兜底:不应真等 60s 默认超时(timeout_ms=100 应生效)
	if elapsed > 5*time.Second {
		t.Fatalf("timeout_ms 未生效,实际耗时 %v(应 ~100ms)", elapsed)
	}
}

// newFakeAgentClient 用 hub.RegisterClient 注入 mock plugin client(Conn=nil)。
// 不走真 WS dial:hub.SendToAgent 写到 client.Send channel,测试 goroutine 读取后
// 直接调 registry.Resolve 模拟 plugin 回包路径(对称 ws_handler.routeAgentIncoming)。
func newFakeAgentClient(t *testing.T, h *hub.Hub, agentID string) *hub.Client {
	t.Helper()
	c := hub.NewClient(context.Background(), agentID, "agent", nil)
	h.RegisterClient(c)
	return c
}

// resolveFirstCall 阻塞等待 client.Send 收到第一条 OpPluginCall,
// 解析出 rpc id 后用 registry.Resolve 投递响应(模拟 plugin 经 routeAgentIncoming 回包)。
// 超时返回(测试失败由调用方断言),避免 goroutine 永久泄漏。
func resolveFirstCall(t *testing.T, c *hub.Client, reg *hub.RPCRegistry, result json.RawMessage, timeout time.Duration) {
	t.Helper()
	select {
	case data := <-c.Send:
		var msg model.WSMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			t.Errorf("unmarshal WSMessage: %v", err)
			return
		}
		var call struct{ ID string }
		if err := json.Unmarshal(msg.D, &call); err != nil {
			t.Errorf("unmarshal plugin call: %v", err)
			return
		}
		reg.Resolve(call.ID, &hub.RPCResponse{Result: result})
	case <-time.After(timeout):
		t.Errorf("等 OpPluginCall 超时 %v", timeout)
	}
}

// TestRPCHandler_Methods_HappyPath 验证 GET /api/agents/:id/rpc-methods:
//   - owner 查询,capReg 已上报 → 200 + {ok, data:{agent_id, methods, updated_at}}
//   - methods 非空 + updated_at 非空
func TestRPCHandler_Methods_HappyPath(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)

	owner, err := urepo.Create(t.Context(), shortName(t, "owner_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	ag, err := arepo.Create(t.Context(), owner.ID, "test-agent", "sk", "")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}

	capReg := agent.NewCapabilityRegistry()
	capReg.Update(ag.ID, []model.RpcMethod{{Name: "echo", TimeoutHintMs: 3000}})

	hubInstance := hub.NewHub(presence.New(nil), arepo, repository.NewParticipantRepo(db), nil)
	h := NewRPCHandler(arepo, hubInstance, hub.NewRPCRegistry(), capReg, nil)
	r := gin.New()
	r.GET("/api/agents/:id/rpc-methods", func(c *gin.Context) {
		c.Set("userID", owner.ID)
		h.Methods(c)
	})

	req := httptest.NewRequest("GET", "/api/agents/"+ag.ID+"/rpc-methods", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d: %s", w.Code, w.Body.String())
	}
	var resp struct {
		OK   bool `json:"ok"`
		Data struct {
			AgentID   string            `json:"agent_id"`
			Methods   []model.RpcMethod `json:"methods"`
			UpdatedAt *time.Time        `json:"updated_at"`
		} `json:"data"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if !resp.OK || resp.Data.AgentID != ag.ID {
		t.Errorf("response 不正确: %+v", resp)
	}
	if len(resp.Data.Methods) != 1 || resp.Data.Methods[0].Name != "echo" {
		t.Errorf("methods 不正确: %+v", resp.Data.Methods)
	}
	if resp.Data.UpdatedAt == nil {
		t.Errorf("updated_at 不应是 null")
	}
}

// TestRPCHandler_Methods_NotFound 验证 agent 不存在 → 404。
func TestRPCHandler_Methods_NotFound(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)

	capReg := agent.NewCapabilityRegistry()
	hubInstance := hub.NewHub(presence.New(nil), arepo, repository.NewParticipantRepo(db), nil)
	h := NewRPCHandler(arepo, hubInstance, hub.NewRPCRegistry(), capReg, nil)
	r := gin.New()
	r.GET("/api/agents/:id/rpc-methods", func(c *gin.Context) {
		c.Set("userID", "user-1")
		h.Methods(c)
	})

	req := httptest.NewRequest("GET", "/api/agents/00000000-0000-0000-0000-000000000000/rpc-methods", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusNotFound {
		t.Errorf("want 404, got %d", w.Code)
	}
}

// TestRPCHandler_Methods_IDOR_Forbidden 验证非 owner 查询 → 403。
func TestRPCHandler_Methods_IDOR_Forbidden(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)

	owner, err := urepo.Create(t.Context(), shortName(t, "owner_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	ag, err := arepo.Create(t.Context(), owner.ID, "test-agent", "sk", "")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}

	capReg := agent.NewCapabilityRegistry()
	hubInstance := hub.NewHub(presence.New(nil), arepo, repository.NewParticipantRepo(db), nil)
	h := NewRPCHandler(arepo, hubInstance, hub.NewRPCRegistry(), capReg, nil)
	r := gin.New()
	r.GET("/api/agents/:id/rpc-methods", func(c *gin.Context) {
		c.Set("userID", "other-user")
		h.Methods(c)
	})

	req := httptest.NewRequest("GET", "/api/agents/"+ag.ID+"/rpc-methods", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusForbidden {
		t.Errorf("非 owner 应 403, got %d", w.Code)
	}
}

// TestRPCHandler_Methods_NotYetReported_ReturnsNullUpdatedAt 验证
// plugin 从未上报 PLUGIN_CAPABILITIES → 200 + methods=[] + updated_at=null。
func TestRPCHandler_Methods_NotYetReported_ReturnsNullUpdatedAt(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)

	owner, err := urepo.Create(t.Context(), shortName(t, "owner_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	ag, err := arepo.Create(t.Context(), owner.ID, "test-agent", "sk", "")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}

	capReg := agent.NewCapabilityRegistry() // 从未 Update
	hubInstance := hub.NewHub(presence.New(nil), arepo, repository.NewParticipantRepo(db), nil)
	h := NewRPCHandler(arepo, hubInstance, hub.NewRPCRegistry(), capReg, nil)
	r := gin.New()
	r.GET("/api/agents/:id/rpc-methods", func(c *gin.Context) {
		c.Set("userID", owner.ID)
		h.Methods(c)
	})

	req := httptest.NewRequest("GET", "/api/agents/"+ag.ID+"/rpc-methods", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("want 200, got %d: %s", w.Code, w.Body.String())
	}
	var resp struct {
		Data struct {
			Methods   []model.RpcMethod `json:"methods"`
			UpdatedAt *time.Time        `json:"updated_at"`
		} `json:"data"`
	}
	_ = json.Unmarshal(w.Body.Bytes(), &resp)
	if len(resp.Data.Methods) != 0 {
		t.Errorf("未上报应空清单, got %d", len(resp.Data.Methods))
	}
	if resp.Data.UpdatedAt != nil {
		t.Errorf("未上报 updated_at 应是 null, got %v", resp.Data.UpdatedAt)
	}
}

// TestRPCHandler_RPC_RateLimited 验证 POST /api/agents/:id/rpc 挂 60/min/user 限流:
//   - 前 60 次通过 limiter(plugin 离线返 503,不限流)
//   - 第 61 次返 429
//
// 用内存限流(Redis=nil),Prefix 用唯一前缀避免跟其他测试冲突。
func TestRPCHandler_RPC_RateLimited(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)

	owner, err := urepo.Create(t.Context(), shortName(t, "owner_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	ag, err := arepo.Create(t.Context(), owner.ID, "test-agent", "sk", "")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}

	capReg := agent.NewCapabilityRegistry()
	hubInstance := hub.NewHub(presence.New(nil), arepo, repository.NewParticipantRepo(db), nil)
	h := NewRPCHandler(arepo, hubInstance, hub.NewRPCRegistry(), capReg, nil)

	limiter := ratelimit.New(ratelimit.Options{
		Window:  time.Minute,
		Max:     60,
		KeyFunc: func(c *gin.Context) string { return c.GetString("userID") },
		Prefix:  "rl:rpc:test:",
	})

	r := gin.New()
	r.POST("/api/agents/:id/rpc",
		func(c *gin.Context) { c.Set("userID", owner.ID) },
		limiter,
		h.Call,
	)

	body, _ := json.Marshal(map[string]any{"method": "echo", "params": map[string]any{}})

	codes := make([]int, 0, 61)
	for i := 0; i < 61; i++ {
		req := httptest.NewRequest("POST", "/api/agents/"+ag.ID+"/rpc", bytes.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		codes = append(codes, w.Code)
	}

	okCount := 0
	rateLimitedCount := 0
	for _, code := range codes {
		switch code {
		case http.StatusOK, http.StatusServiceUnavailable, http.StatusGatewayTimeout:
			okCount++
		case http.StatusTooManyRequests:
			rateLimitedCount++
		}
	}

	if okCount != 60 {
		t.Errorf("前 60 次应不限流, got %d (codes=%v)", okCount, codes)
	}
	if rateLimitedCount != 1 {
		t.Errorf("第 61 次应限流, got %d (codes=%v)", rateLimitedCount, codes)
	}
}
