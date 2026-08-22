package handler

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/agent"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/presence"
	"github.com/wanling/server/internal/repository"
)

// TestAgentHandler_UpdateDelete_Ownership 验证 agent 的 Update/Delete 归属校验（防 IDOR）：
//   - owner 自己能改/删（200）
//   - 其他 user 被拒（403）
//   - 不存在的 agent 返 404
//
// 任意登录 user 拿到他人 agent_id 即可改/删是越权漏洞，必须比对 owner_id。
func TestAgentHandler_UpdateDelete_Ownership(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)
	// presence.New(nil) 安全：IsOnline 对 nil rdb 返回 false，不连 Redis。
	h := NewAgentHandler(arepo, repository.NewConversationRepo(db), presence.New(nil), agent.NewAgentRegistry(), agent.NewSlashCatalogRegistry(), agent.NewModeRegistry(), agent.NewPresetRegistry())

	// 两个 user：owner 与 attacker
	owner, err := urepo.Create(t.Context(), shortName(t, "owner_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	attacker, err := urepo.Create(t.Context(), shortName(t, "atk_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create attacker: %v", err)
	}

	// owner 创建一个 agent
	agent, err := arepo.Create(t.Context(), owner.ID, "test-agent", "sk-test", "")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}

	r := gin.New()
	// Update 路由：从 context 取 userID 模拟不同身份
	r.PATCH("/api/agents/:id", func(c *gin.Context) {
		c.Set("userID", c.Query("as_user"))
		c.Set("role", "user")
		h.Update(c)
	})
	// Delete 路由
	r.DELETE("/api/agents/:id", func(c *gin.Context) {
		c.Set("userID", c.Query("as_user"))
		c.Set("role", "user")
		h.Delete(c)
	})

	t.Run("Update_owner_ok", func(t *testing.T) {
		body := map[string]string{"name": "renamed"}
		raw, _ := json.Marshal(body)
		req := httptest.NewRequest("PATCH", "/api/agents/"+agent.ID+"?as_user="+owner.ID, bytes.NewReader(raw))
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertOk(t, w, http.StatusOK)
	})

	t.Run("Update_attacker_forbidden", func(t *testing.T) {
		body := map[string]string{"name": "hacked"}
		raw, _ := json.Marshal(body)
		req := httptest.NewRequest("PATCH", "/api/agents/"+agent.ID+"?as_user="+attacker.ID, bytes.NewReader(raw))
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertErr(t, w, http.StatusForbidden, "forbidden")
	})

	t.Run("Update_notfound", func(t *testing.T) {
		body := map[string]string{"name": "x"}
		raw, _ := json.Marshal(body)
		req := httptest.NewRequest("PATCH", "/api/agents/00000000-0000-0000-0000-000000000000?as_user="+owner.ID, bytes.NewReader(raw))
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertErr(t, w, http.StatusNotFound, "not_found")
	})

	t.Run("Delete_attacker_forbidden", func(t *testing.T) {
		req := httptest.NewRequest("DELETE", "/api/agents/"+agent.ID+"?as_user="+attacker.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertErr(t, w, http.StatusForbidden, "forbidden")
	})

	t.Run("Delete_owner_ok", func(t *testing.T) {
		req := httptest.NewRequest("DELETE", "/api/agents/"+agent.ID+"?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertOk(t, w, http.StatusOK)
	})
}

// TestAgentCreate_ReturnsSecretKey 验证 Create 响应一次性返回明文 secret_key（GitHub PAT 模式）。
//
//	List/Get/Update 都不返，仅 Create 这一次可见，方便用户初次拿到凭证。
func TestAgentCreate_ReturnsSecretKey(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)
	h := NewAgentHandler(arepo, repository.NewConversationRepo(db), presence.New(nil), agent.NewAgentRegistry(), agent.NewSlashCatalogRegistry(), agent.NewModeRegistry(), agent.NewPresetRegistry())

	owner, err := urepo.Create(t.Context(), shortName(t, "owner_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}

	r := gin.New()
	r.POST("/api/agents", func(c *gin.Context) {
		c.Set("userID", owner.ID)
		c.Set("role", "user")
		h.Create(c)
	})

	body := map[string]string{"name": "test-agent"}
	raw, _ := json.Marshal(body)
	req := httptest.NewRequest("POST", "/api/agents", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("Create: want 201, got %d body=%s", w.Code, w.Body.String())
	}

	data := AssertOk(t, w, http.StatusCreated)

	sk, ok := data["secret_key"]
	if !ok {
		t.Fatalf("Create response missing secret_key field: %s", w.Body.String())
	}
	skStr, _ := sk.(string)
	if skStr == "" {
		t.Fatalf("Create response secret_key is empty: %s", w.Body.String())
	}
}

// TestAgentList_HidesSecretKey 验证 List 响应不返 secret_key（防凭证泄漏）。
//
//	model.Agent.SecretKey 改 json:"-"，序列化时字段直接消失。
func TestAgentList_HidesSecretKey(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)
	h := NewAgentHandler(arepo, repository.NewConversationRepo(db), presence.New(nil), agent.NewAgentRegistry(), agent.NewSlashCatalogRegistry(), agent.NewModeRegistry(), agent.NewPresetRegistry())

	owner, err := urepo.Create(t.Context(), shortName(t, "owner_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}

	// 先创建一个 agent（带非空 secret_key）
	if _, err := arepo.Create(t.Context(), owner.ID, "test-agent", "sk-plaintext-should-not-leak", ""); err != nil {
		t.Fatalf("create agent: %v", err)
	}

	r := gin.New()
	r.GET("/api/agents", func(c *gin.Context) {
		c.Set("userID", owner.ID)
		c.Set("role", "user")
		h.List(c)
	})

	req := httptest.NewRequest("GET", "/api/agents", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("List: want 200, got %d body=%s", w.Code, w.Body.String())
	}

	// 断言 envelope + data 是 list
	arr := AssertOkList(t, w, http.StatusOK)
	if len(arr) == 0 {
		t.Fatalf("List returned empty array, expected at least 1 agent")
	}
	// 断言每个 agent 都不含 secret_key 字段（json:"-" 应让字段直接消失）
	for i, raw := range arr {
		a, ok := raw.(map[string]any)
		if !ok {
			t.Fatalf("agent[%d] 不是 map: %T", i, raw)
		}
		if _, exists := a["secret_key"]; exists {
			t.Fatalf("agent[%d] in List response contains secret_key field (must be hidden): %v", i, a)
		}
	}

	// 同时断言明文不出现在原始 JSON 字符串中（双保险，防 omitempty 等标签绕过）
	if bytes.Contains(w.Body.Bytes(), []byte("sk-plaintext-should-not-leak")) {
		t.Fatalf("List response leaks plaintext secret_key in body: %s", w.Body.String())
	}
}

// TestAgentHandler_Create_BuildsDefaultConv 验证 Create 内部建 owner↔agent 默认 conv:
//   - 响应含 default_conv_id 非空
//   - DB conversations 表多一行 type=dm_user_agent
//   - 该 conv 能被 FindDMByOwnerAgent 查到且 ID 一致
func TestAgentHandler_Create_BuildsDefaultConv(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	urepo := repository.NewUserRepo(db)
	h := NewAgentHandler(arepo, crepo, presence.New(nil), agent.NewAgentRegistry(), agent.NewSlashCatalogRegistry(), agent.NewModeRegistry(), agent.NewPresetRegistry())

	owner, err := urepo.Create(t.Context(), shortName(t, "owner_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}

	r := gin.New()
	r.POST("/api/agents", func(c *gin.Context) {
		c.Set("userID", owner.ID)
		c.Set("role", "user")
		h.Create(c)
	})

	body := map[string]string{"name": "alice-bot"}
	raw, _ := json.Marshal(body)
	req := httptest.NewRequest("POST", "/api/agents", bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("Create: want 201, got %d body=%s", w.Code, w.Body.String())
	}
	data := AssertOk(t, w, http.StatusCreated)

	convIDRaw, ok := data["default_conv_id"]
	if !ok {
		t.Fatalf("响应缺 default_conv_id: %s", w.Body.String())
	}
	convID, _ := convIDRaw.(string)
	if convID == "" {
		t.Fatalf("default_conv_id 不应为空")
	}

	agentID, _ := data["id"].(string)
	if agentID == "" {
		t.Fatalf("响应缺 id")
	}

	conv, err := crepo.FindDMByOwnerAgent(t.Context(), owner.ID, agentID)
	if err != nil {
		t.Fatalf("FindDMByOwnerAgent 失败: %v", err)
	}
	if conv == nil || conv.ID != convID {
		t.Fatalf("DB conv 不一致: 期望 %s 实际 %+v", convID, conv)
	}
	if conv.Type != model.ConvTypeDMUserAgent {
		t.Errorf("conv type 错误: 期望 dm_user_agent 实际 %s", conv.Type)
	}
}

// TestAgentHandler_Models 验证 GET /api/agents/:id/models 模型清单端点:
//   - owner 能查到 plugin 上报的模型清单(200,数组非空,updated_at 非空时间戳)
//   - 未上报的 agent 查返空数组 + 200 + updated_at=null(plugin 离线 / server 重启 / opencode 未就绪均合法空态)
//   - 非_owner 被拒(IDOR 防护,403)
//   - 不存在的 agent 返 404
//
// time.Time{}/.IsZero() 默认 marshal 为 "0001-01-01T00:00:00Z" 而非 null,
// handler 内用 any + IsZero 判断保证返 null,本测试显式断言此行为防回归。
func TestAgentHandler_Models(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)
	reg := agent.NewAgentRegistry()
	h := NewAgentHandler(arepo, repository.NewConversationRepo(db), presence.New(nil), reg, agent.NewSlashCatalogRegistry(), agent.NewModeRegistry(), agent.NewPresetRegistry())

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

	// 预先上报 owner agent 的模型清单
	reg.Update(ag.ID, []model.ModelInfo{
		{ProviderID: "zhipuai", ProviderName: "Zhipuai", ModelID: "glm-5.2", ModelName: "GLM-5.2"},
	})

	r := gin.New()
	r.GET("/api/agents/:id/models", func(c *gin.Context) {
		c.Set("userID", c.Query("as_user"))
		h.Models(c)
	})

	t.Run("owner_ok", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/api/agents/"+ag.ID+"/models?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		data := AssertOk(t, w, http.StatusOK)

		if data["agent_id"] != ag.ID {
			t.Fatalf("agent_id: 期望 %s 实际 %v", ag.ID, data["agent_id"])
		}
		models, ok := data["models"].([]any)
		if !ok {
			t.Fatalf("models 不是数组: %T (body=%s)", data["models"], w.Body.String())
		}
		if len(models) != 1 {
			t.Fatalf("期望 1 条模型,实际 %d (body=%s)", len(models), w.Body.String())
		}
		m, _ := models[0].(map[string]any)
		if m["model_id"] != "glm-5.2" {
			t.Fatalf("model_id: 期望 glm-5.2 实际 %v", m["model_id"])
		}
		// 上报后 updated_at 应为非 null 时间戳
		if data["updated_at"] == nil {
			t.Fatalf("上报后 updated_at 不应为 null: %s", w.Body.String())
		}
	})

	t.Run("empty_returns_200_and_null_updated_at", func(t *testing.T) {
		// 新建 agent 不上报,查应返空数组 + 200 + updated_at=null
		ag2, err := arepo.Create(t.Context(), owner.ID, "agent-no-report", "sk2", "")
		if err != nil {
			t.Fatalf("create agent2: %v", err)
		}
		req := httptest.NewRequest("GET", "/api/agents/"+ag2.ID+"/models?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertOk(t, w, http.StatusOK)

		var resp struct {
			Data struct {
				Models    []any `json:"models"`
				UpdatedAt any   `json:"updated_at"`
			} `json:"data"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("unmarshal: %v body=%s", err, w.Body.String())
		}
		if len(resp.Data.Models) != 0 {
			t.Fatalf("未上报期望空数组,实际 %v", resp.Data.Models)
		}
		// 关键断言:未上报时 updated_at 必须 null,不能是 "0001-01-01T00:00:00Z"
		if resp.Data.UpdatedAt != nil {
			t.Fatalf("未上报 updated_at 期望 null,实际 %v (body=%s)", resp.Data.UpdatedAt, w.Body.String())
		}
	})

	t.Run("attacker_forbidden", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/api/agents/"+ag.ID+"/models?as_user="+attacker.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertErr(t, w, http.StatusForbidden, "forbidden")
	})

	t.Run("notfound", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/api/agents/00000000-0000-0000-0000-000000000000/models?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertErr(t, w, http.StatusNotFound, "not_found")
	})
}

// TestAgentHandler_SlashCatalog 验证 GET /api/agents/:id/slash-catalog 命令清单端点:
//   - owner 能查到 plugin 上报的命令清单(200, 数组非空, updated_at 非空)
//   - 未上报的 agent 查返空数组 + 200 + updated_at=null
//   - 非 owner 被拒(IDOR 防护, 403)
//   - 不存在的 agent 返 404
func TestAgentHandler_SlashCatalog(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)
	reg := agent.NewSlashCatalogRegistry()
	h := NewAgentHandler(arepo, repository.NewConversationRepo(db), presence.New(nil), agent.NewAgentRegistry(), reg, agent.NewModeRegistry(), agent.NewPresetRegistry())

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

	// 预先上报 owner agent 的命令清单
	reg.Update(ag.ID, []model.SlashCommandInfo{
		{Name: "compact", Template: "/compact", Description: "压缩", Source: "command"},
	})

	r := gin.New()
	r.GET("/api/agents/:id/slash-catalog", func(c *gin.Context) {
		c.Set("userID", c.Query("as_user"))
		h.SlashCatalog(c)
	})

	t.Run("owner_ok", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/api/agents/"+ag.ID+"/slash-catalog?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		data := AssertOk(t, w, http.StatusOK)

		if data["agent_id"] != ag.ID {
			t.Fatalf("agent_id: 期望 %s 实际 %v", ag.ID, data["agent_id"])
		}
		cmds, ok := data["commands"].([]any)
		if !ok {
			t.Fatalf("commands 不是数组: %T (body=%s)", data["commands"], w.Body.String())
		}
		if len(cmds) != 1 {
			t.Fatalf("期望 1 条命令, 实际 %d (body=%s)", len(cmds), w.Body.String())
		}
		m, _ := cmds[0].(map[string]any)
		if m["name"] != "compact" {
			t.Fatalf("name: 期望 compact 实际 %v", m["name"])
		}
		if m["source"] != "command" {
			t.Fatalf("source: 期望 command 实际 %v", m["source"])
		}
		if data["updated_at"] == nil {
			t.Fatalf("上报后 updated_at 不应为 null: %s", w.Body.String())
		}
	})

	t.Run("empty_returns_200_and_null_updated_at", func(t *testing.T) {
		ag2, err := arepo.Create(t.Context(), owner.ID, "agent-no-report", "sk2", "")
		if err != nil {
			t.Fatalf("create agent2: %v", err)
		}
		req := httptest.NewRequest("GET", "/api/agents/"+ag2.ID+"/slash-catalog?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertOk(t, w, http.StatusOK)

		var resp struct {
			Data struct {
				Commands  []any `json:"commands"`
				UpdatedAt any   `json:"updated_at"`
			} `json:"data"`
		}
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("unmarshal: %v body=%s", err, w.Body.String())
		}
		if len(resp.Data.Commands) != 0 {
			t.Fatalf("未上报期望空数组, 实际 %v", resp.Data.Commands)
		}
		if resp.Data.UpdatedAt != nil {
			t.Fatalf("未上报 updated_at 期望 null, 实际 %v", resp.Data.UpdatedAt)
		}
	})

	t.Run("forbidden_for_non_owner", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/api/agents/"+ag.ID+"/slash-catalog?as_user="+attacker.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		if w.Code != http.StatusForbidden {
			t.Fatalf("非 owner 期望 403, 实际 %d (body=%s)", w.Code, w.Body.String())
		}
	})

	t.Run("not_found_for_missing_agent", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/api/agents/00000000-0000-0000-0000-000000000000/slash-catalog?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		if w.Code != http.StatusNotFound {
			t.Fatalf("不存在 agent 期望 404, 实际 %d", w.Code)
		}
	})
}

// TestAgentHandler_RotateSecret 验证 POST /api/agents/:id/rotate-secret:
//   - owner 能重置密钥,响应包一层 data.secret_key(200,非空,与原 key 不同)
//   - 非 owner 被拒(IDOR 防护,403)
//   - 不存在的 agent 返 404
//   - 新 key 落库生效(用原 key 查 agent 验证已变更)
func TestAgentHandler_RotateSecret(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)
	h := NewAgentHandler(arepo, repository.NewConversationRepo(db), presence.New(nil), agent.NewAgentRegistry(), agent.NewSlashCatalogRegistry(), agent.NewModeRegistry(), agent.NewPresetRegistry())

	owner, err := urepo.Create(t.Context(), shortName(t, "owner_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	attacker, err := urepo.Create(t.Context(), shortName(t, "atk_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create attacker: %v", err)
	}
	const originalKey = "sk-original-12345"
	ag, err := arepo.Create(t.Context(), owner.ID, "test-agent", originalKey, "")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}

	r := gin.New()
	r.POST("/api/agents/:id/rotate-secret", func(c *gin.Context) {
		c.Set("userID", c.Query("as_user"))
		h.RotateSecret(c)
	})

	t.Run("owner_ok_returns_new_key", func(t *testing.T) {
		req := httptest.NewRequest("POST", "/api/agents/"+ag.ID+"/rotate-secret?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		data := AssertOk(t, w, http.StatusOK)

		newKey, ok := data["secret_key"].(string)
		if !ok || newKey == "" {
			t.Fatalf("响应缺 secret_key 或为空: %s", w.Body.String())
		}
		if newKey == originalKey {
			t.Fatalf("新 key 不应等于原 key")
		}
		if len(newKey) != 64 {
			t.Fatalf("新 key 期望 64 字符 hex(256-bit), 实际 %d", len(newKey))
		}
	})

	t.Run("attacker_forbidden", func(t *testing.T) {
		req := httptest.NewRequest("POST", "/api/agents/"+ag.ID+"/rotate-secret?as_user="+attacker.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertErr(t, w, http.StatusForbidden, "forbidden")
	})

	t.Run("not_found", func(t *testing.T) {
		req := httptest.NewRequest("POST", "/api/agents/00000000-0000-0000-0000-000000000000/rotate-secret?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertErr(t, w, http.StatusNotFound, "not_found")
	})

	t.Run("new_key_persists_in_db", func(t *testing.T) {
		req := httptest.NewRequest("POST", "/api/agents/"+ag.ID+"/rotate-secret?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		data := AssertOk(t, w, http.StatusOK)
		newKey, _ := data["secret_key"].(string)

		updated, err := arepo.GetByID(t.Context(), ag.ID)
		if err != nil {
			t.Fatalf("GetByID: %v", err)
		}
		if updated.SecretKey != newKey {
			t.Fatalf("DB 中 key 未更新: 期望 %s 实际 %s", newKey, updated.SecretKey)
		}
		if updated.SecretKey == originalKey {
			t.Fatalf("DB 中 key 仍为原 key,重置未生效")
		}
	})
}

// TestAgentHandler_Modes 验证 GET /api/agents/:id/modes 模式清单端点:
// owner 可查上报清单 / 未上报返空 + updated_at=null / 非 owner 403 / 不存在 404。
func TestAgentHandler_Modes(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)
	reg := agent.NewModeRegistry()
	h := NewAgentHandler(arepo, repository.NewConversationRepo(db), presence.New(nil), agent.NewAgentRegistry(), agent.NewSlashCatalogRegistry(), reg, agent.NewPresetRegistry())

	owner, err := urepo.Create(t.Context(), shortName(t, "owner_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	other, err := urepo.Create(t.Context(), shortName(t, "other_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create other: %v", err)
	}
	ag, err := arepo.Create(t.Context(), owner.ID, "test-agent", "sk", "")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}

	reg.Update(ag.ID, []model.AgentModeInfo{
		{ID: "build", Label: "构建", Style: "default"},
		{ID: "plan", Label: "计划", Style: "plan"},
	})

	r := gin.New()
	r.GET("/api/agents/:id/modes", func(c *gin.Context) {
		c.Set("userID", c.Query("as_user"))
		h.Modes(c)
	})

	t.Run("owner_ok", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/api/agents/"+ag.ID+"/modes?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		data := AssertOk(t, w, http.StatusOK)

		modes, ok := data["modes"].([]any)
		if !ok {
			t.Fatalf("modes 不是数组: %T (body=%s)", data["modes"], w.Body.String())
		}
		if len(modes) != 2 {
			t.Fatalf("期望 2 个 mode, 实际 %d (body=%s)", len(modes), w.Body.String())
		}
		m, _ := modes[1].(map[string]any)
		if m["id"] != "plan" || m["style"] != "plan" {
			t.Fatalf("第 2 条期望 plan/plan, 实际 %v", m)
		}
		if data["updated_at"] == nil {
			t.Fatalf("已上报 updated_at 不应为 null (body=%s)", w.Body.String())
		}
	})

	t.Run("not_reported_empty", func(t *testing.T) {
		ag2, _ := arepo.Create(t.Context(), owner.ID, "agent-no-report", "sk", "")
		req := httptest.NewRequest("GET", "/api/agents/"+ag2.ID+"/modes?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		data := AssertOk(t, w, http.StatusOK)

		modes, _ := data["modes"].([]any)
		if len(modes) != 0 {
			t.Fatalf("未上报期望空数组, 实际 %v", modes)
		}
		if data["updated_at"] != nil {
			t.Fatalf("未上报 updated_at 应为 null, 实际 %v", data["updated_at"])
		}
	})

	t.Run("not_owner_403", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/api/agents/"+ag.ID+"/modes?as_user="+other.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertErr(t, w, http.StatusForbidden, "forbidden")
	})

	t.Run("not_found_404", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/api/agents/00000000-0000-0000-0000-000000000000/modes?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertErr(t, w, http.StatusNotFound, "not_found")
	})
}

// TestAgentHandler_Presets 验证 GET /api/agents/:id/presets 预设清单端点:
// owner 可查上报清单(含 trust 字段透传) / 未上报返空 / 非 owner 403 / 不存在 404。
func TestAgentHandler_Presets(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)
	reg := agent.NewPresetRegistry()
	h := NewAgentHandler(arepo, repository.NewConversationRepo(db), presence.New(nil), agent.NewAgentRegistry(), agent.NewSlashCatalogRegistry(), agent.NewModeRegistry(), reg)

	owner, err := urepo.Create(t.Context(), shortName(t, "owner_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	other, err := urepo.Create(t.Context(), shortName(t, "other_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create other: %v", err)
	}
	ag, err := arepo.Create(t.Context(), owner.ID, "test-agent", "sk", "")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}

	reg.Update(ag.ID, []model.AgentPresetInfo{
		{ID: "standard", Label: "标准", Trust: "system", Order: 1},
		{ID: "my-agent", Label: "我的定制", Trust: "user"},
	})

	r := gin.New()
	r.GET("/api/agents/:id/presets", func(c *gin.Context) {
		c.Set("userID", c.Query("as_user"))
		h.Presets(c)
	})

	t.Run("owner_ok", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/api/agents/"+ag.ID+"/presets?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		data := AssertOk(t, w, http.StatusOK)

		presets, ok := data["presets"].([]any)
		if !ok {
			t.Fatalf("presets 不是数组: %T (body=%s)", data["presets"], w.Body.String())
		}
		if len(presets) != 2 {
			t.Fatalf("期望 2 个 preset, 实际 %d (body=%s)", len(presets), w.Body.String())
		}
		m, _ := presets[1].(map[string]any)
		if m["trust"] != "user" {
			t.Fatalf("第 2 条期望 trust=user, 实际 %v", m)
		}
	})

	t.Run("not_reported_empty", func(t *testing.T) {
		ag2, _ := arepo.Create(t.Context(), owner.ID, "agent-no-report", "sk", "")
		req := httptest.NewRequest("GET", "/api/agents/"+ag2.ID+"/presets?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		data := AssertOk(t, w, http.StatusOK)

		presets, _ := data["presets"].([]any)
		if len(presets) != 0 {
			t.Fatalf("未上报期望空数组, 实际 %v", presets)
		}
	})

	t.Run("not_owner_403", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/api/agents/"+ag.ID+"/presets?as_user="+other.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertErr(t, w, http.StatusForbidden, "forbidden")
	})

	t.Run("not_found_404", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/api/agents/00000000-0000-0000-0000-000000000000/presets?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertErr(t, w, http.StatusNotFound, "not_found")
	})
}
