package handler

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"
	"github.com/wanling/server/internal/agent"
	"github.com/wanling/server/internal/presence"
	"github.com/wanling/server/internal/repository"
)

// TestAgentSubKeyHandler_List 验证 GET /api/agents/:id/subkeys:
//   - owner 列表含新建子密钥,响应不含 secret_key 字段(明文也不得出现在 body)
//   - 他人 agent 403(IDOR 防护,owner 是数据边界)
//   - 不存在的 agent 返 404
func TestAgentSubKeyHandler_List(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)
	skrepo := repository.NewAgentSubKeyRepo(db)
	h := NewAgentSubKeyHandler(arepo, skrepo)

	owner, err := urepo.Create(t.Context(), shortName(t, "owner_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	attacker, err := urepo.Create(t.Context(), shortName(t, "atk_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create attacker: %v", err)
	}
	ag, err := arepo.Create(t.Context(), owner.ID, "test-agent", "sk-main", "")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}
	const plainKey = "wlsk-plaintext-should-not-leak"
	if _, err := skrepo.Create(t.Context(), ag.ID, "ci-key", plainKey); err != nil {
		t.Fatalf("create subkey1: %v", err)
	}
	if _, err := skrepo.Create(t.Context(), ag.ID, "old-key", "wlsk-second"); err != nil {
		t.Fatalf("create subkey2: %v", err)
	}

	r := gin.New()
	r.GET("/api/agents/:id/subkeys", func(c *gin.Context) {
		c.Set("userID", c.Query("as_user"))
		c.Set("role", "user")
		h.List(c)
	})

	t.Run("owner_ok_without_secret_key", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/api/agents/"+ag.ID+"/subkeys?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		data := AssertOk(t, w, http.StatusOK)

		subkeys, ok := data["subkeys"].([]any)
		if !ok {
			t.Fatalf("subkeys 不是数组: %T (body=%s)", data["subkeys"], w.Body.String())
		}
		if len(subkeys) != 2 {
			t.Fatalf("期望 2 条子密钥, 实际 %d (body=%s)", len(subkeys), w.Body.String())
		}
		names := map[string]bool{}
		for i, raw := range subkeys {
			m, ok := raw.(map[string]any)
			if !ok {
				t.Fatalf("subkeys[%d] 不是 map: %T", i, raw)
			}
			if _, exists := m["secret_key"]; exists {
				t.Fatalf("subkeys[%d] 响应含 secret_key 字段(必须隐藏): %v", i, m)
			}
			if m["revoked_at"] != nil {
				t.Fatalf("新建子密钥 revoked_at 应为 null: %v", m)
			}
			name, _ := m["name"].(string)
			names[name] = true
		}
		if !names["ci-key"] || !names["old-key"] {
			t.Fatalf("列表缺新建子密钥: %v", names)
		}
		// 双保险:明文凭据不得出现在原始 JSON body(防标签遗漏绕过)
		if bytes.Contains(w.Body.Bytes(), []byte(plainKey)) {
			t.Fatalf("List 响应泄漏明文子密钥: %s", w.Body.String())
		}
	})

	t.Run("attacker_forbidden", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/api/agents/"+ag.ID+"/subkeys?as_user="+attacker.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertErr(t, w, http.StatusForbidden, "forbidden")
	})

	t.Run("agent_not_found", func(t *testing.T) {
		req := httptest.NewRequest("GET", "/api/agents/00000000-0000-0000-0000-000000000000/subkeys?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertErr(t, w, http.StatusNotFound, "not_found")
	})
}

// TestAgentSubKeyHandler_Revoke 验证 DELETE /api/agents/:id/subkeys/:keyId:
//   - 吊销后列表 revoked_at 非空,活跃数归零
//   - 再 DELETE 同一 key 幂等 200,且不覆盖原吊销时间
//   - keyId 不存在也 200(幂等吊销语义)
//   - agent 不存在才 404
func TestAgentSubKeyHandler_Revoke(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)
	skrepo := repository.NewAgentSubKeyRepo(db)
	h := NewAgentSubKeyHandler(arepo, skrepo)

	owner, err := urepo.Create(t.Context(), shortName(t, "owner_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	ag, err := arepo.Create(t.Context(), owner.ID, "test-agent", "sk-main", "")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}
	k, err := skrepo.Create(t.Context(), ag.ID, "ci-key", "wlsk-to-revoke")
	if err != nil {
		t.Fatalf("create subkey: %v", err)
	}

	r := gin.New()
	r.DELETE("/api/agents/:id/subkeys/:keyId", func(c *gin.Context) {
		c.Set("userID", c.Query("as_user"))
		c.Set("role", "user")
		h.Revoke(c)
	})

	t.Run("revoke_marks_revoked_at", func(t *testing.T) {
		req := httptest.NewRequest("DELETE", "/api/agents/"+ag.ID+"/subkeys/"+k.ID+"?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertOk(t, w, http.StatusOK)

		keys, err := skrepo.ListByAgent(t.Context(), ag.ID)
		if err != nil {
			t.Fatalf("ListByAgent: %v", err)
		}
		if len(keys) != 1 || keys[0].RevokedAt == nil {
			t.Fatalf("吊销后 revoked_at 应非空: %+v", keys)
		}
		n, err := skrepo.CountActive(t.Context(), ag.ID)
		if err != nil {
			t.Fatalf("CountActive: %v", err)
		}
		if n != 0 {
			t.Fatalf("吊销后活跃数应为 0, 实际 %d", n)
		}
	})

	t.Run("second_revoke_idempotent_200", func(t *testing.T) {
		before, err := skrepo.ListByAgent(t.Context(), ag.ID)
		if err != nil {
			t.Fatalf("ListByAgent: %v", err)
		}
		req := httptest.NewRequest("DELETE", "/api/agents/"+ag.ID+"/subkeys/"+k.ID+"?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertOk(t, w, http.StatusOK)

		after, err := skrepo.ListByAgent(t.Context(), ag.ID)
		if err != nil {
			t.Fatalf("ListByAgent: %v", err)
		}
		// 幂等:二次吊销不报错且不覆盖原吊销时间
		if !after[0].RevokedAt.Equal(*before[0].RevokedAt) {
			t.Fatalf("二次吊销不应覆盖原 revoked_at: 前 %v 后 %v", before[0].RevokedAt, after[0].RevokedAt)
		}
	})

	t.Run("missing_key_id_still_200", func(t *testing.T) {
		req := httptest.NewRequest("DELETE", "/api/agents/"+ag.ID+"/subkeys/"+uuid.NewString()+"?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertOk(t, w, http.StatusOK)
	})

	t.Run("agent_not_found_404", func(t *testing.T) {
		req := httptest.NewRequest("DELETE", "/api/agents/00000000-0000-0000-0000-000000000000/subkeys/"+k.ID+"?as_user="+owner.ID, nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		AssertErr(t, w, http.StatusNotFound, "not_found")
	})
}

// TestAgentSubKeyHandler_RotateSecretCascade 验证 rotate-secret 级联吊销:
// 主密钥重置成功后,该 agent 名下全部活跃子密钥 revoked_at 非空(含跨次吊销语义),
// 活跃数归零;新主密钥正常下发。
func TestAgentSubKeyHandler_RotateSecretCascade(t *testing.T) {
	db := repository.SetupTestDB(t)
	arepo := repository.NewAgentRepo(db)
	urepo := repository.NewUserRepo(db)
	skrepo := repository.NewAgentSubKeyRepo(db)
	ah := NewAgentHandler(arepo, repository.NewConversationRepo(db), presence.New(nil), agent.NewAgentRegistry(), agent.NewSlashCatalogRegistry(), agent.NewModeRegistry(), agent.NewPresetRegistry(), repository.NewAgentTypeRepo(db), skrepo)

	owner, err := urepo.Create(t.Context(), shortName(t, "owner_"), "$2a$10$hash")
	if err != nil {
		t.Fatalf("create owner: %v", err)
	}
	const originalKey = "sk-original-12345"
	ag, err := arepo.Create(t.Context(), owner.ID, "test-agent", originalKey, "")
	if err != nil {
		t.Fatalf("create agent: %v", err)
	}
	if _, err := skrepo.Create(t.Context(), ag.ID, "k1", "wlsk-1"); err != nil {
		t.Fatalf("create subkey1: %v", err)
	}
	if _, err := skrepo.Create(t.Context(), ag.ID, "k2", "wlsk-2"); err != nil {
		t.Fatalf("create subkey2: %v", err)
	}

	r := gin.New()
	r.POST("/api/agents/:id/rotate-secret", func(c *gin.Context) {
		c.Set("userID", c.Query("as_user"))
		c.Set("role", "user")
		ah.RotateSecret(c)
	})

	req := httptest.NewRequest("POST", "/api/agents/"+ag.ID+"/rotate-secret?as_user="+owner.ID, nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	data := AssertOk(t, w, http.StatusOK)

	newKey, ok := data["secret_key"].(string)
	if !ok || newKey == "" || newKey == originalKey {
		t.Fatalf("rotate 响应 secret_key 异常: %v (body=%s)", data["secret_key"], w.Body.String())
	}

	keys, err := skrepo.ListByAgent(t.Context(), ag.ID)
	if err != nil {
		t.Fatalf("ListByAgent: %v", err)
	}
	if len(keys) != 2 {
		t.Fatalf("期望 2 条子密钥, 实际 %d", len(keys))
	}
	for _, k := range keys {
		if k.RevokedAt == nil {
			t.Fatalf("rotate 后子密钥 %s(%s) 应被级联吊销", k.ID, k.Name)
		}
	}
	n, err := skrepo.CountActive(t.Context(), ag.ID)
	if err != nil {
		t.Fatalf("CountActive: %v", err)
	}
	if n != 0 {
		t.Fatalf("rotate 后活跃子密钥数应为 0, 实际 %d", n)
	}
}
