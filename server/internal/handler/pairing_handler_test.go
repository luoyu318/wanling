package handler

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/repository"
)

// setupPairHandler 公共构造：起 PG + 建 handler + gin router。
// 返回 (handler, pairingRepo, agentRepo, router)，测试自己注入 userID 模拟 JWT。
func setupPairHandler(t *testing.T) (*PairingHandler, *repository.PairingRepo, *repository.AgentRepo, *gin.Engine) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	db := repository.SetupTestDB(t)
	repo := repository.NewPairingRepo(db)
	arepo := repository.NewAgentRepo(db)
	h := NewPairingHandler(repo, arepo)
	r := gin.New()
	return h, repo, arepo, r
}

// ─── Task 7: CreateTicket ────────────────────────────────────────────────────

func TestPairingHandler_CreateTicket_ReturnsTicketID(t *testing.T) {
	h, _, _, r := setupPairHandler(t)
	r.POST("/api/pair/tickets", h.CreateTicket)

	req := httptest.NewRequest("POST", "/api/pair/tickets", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusCreated {
		t.Fatalf("状态码 %d，body %s", w.Code, w.Body.String())
	}
	var resp map[string]interface{}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatalf("解析响应: %v", err)
	}
	ticketID, ok := resp["ticket_id"].(string)
	if !ok || ticketID == "" {
		t.Fatalf("响应缺少 ticket_id: %v", resp)
	}
	// 256-bit hex = 64 字符
	if len(ticketID) != 64 {
		t.Fatalf("ticket_id 长度 %d，期望 64", len(ticketID))
	}
}

// 两次生成的 ticket_id 不能相同。
func TestPairingHandler_CreateTicket_UniqueIDs(t *testing.T) {
	h, _, _, r := setupPairHandler(t)
	r.POST("/api/pair/tickets", h.CreateTicket)

	ids := map[string]bool{}
	for i := 0; i < 10; i++ {
		req := httptest.NewRequest("POST", "/api/pair/tickets", nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		var resp map[string]interface{}
		json.Unmarshal(w.Body.Bytes(), &resp)
		id := resp["ticket_id"].(string)
		if ids[id] {
			t.Fatalf("第 %d 次生成的 ticket_id 重复: %s", i+1, id)
		}
		ids[id] = true
	}
}

// ─── Task 8: GetTicket ───────────────────────────────────────────────────────

func TestPairingHandler_GetTicket_Pending(t *testing.T) {
	h, repo, _, r := setupPairHandler(t)
	r.GET("/api/pair/tickets/:id", h.GetTicket)

	ticket, _ := repo.Create("get-pending-001")
	req := httptest.NewRequest("GET", "/api/pair/tickets/"+ticket.ID, nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != 200 {
		t.Fatalf("状态码 %d", w.Code)
	}
	var resp map[string]interface{}
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["status"] != "pending" {
		t.Fatalf("status = %v, want pending", resp["status"])
	}
	if _, exists := resp["secret_key"]; exists {
		t.Fatal("pending 状态不应返回 secret_key")
	}
}

func TestPairingHandler_GetTicket_NotFound(t *testing.T) {
	h, _, _, r := setupPairHandler(t)
	r.GET("/api/pair/tickets/:id", h.GetTicket)

	req := httptest.NewRequest("GET", "/api/pair/tickets/nonexistent-id", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != 200 {
		t.Fatalf("状态码 %d，期望 200", w.Code)
	}
	var resp map[string]interface{}
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["status"] != "not_found" {
		t.Fatalf("status = %v, want not_found", resp["status"])
	}
}

func TestPairingHandler_GetTicket_Completed_ReturnsSecretKeyOnce(t *testing.T) {
	h, repo, arepo, r := setupPairHandler(t)
	r.GET("/api/pair/tickets/:id", h.GetTicket)

	urepo := repository.NewUserRepo(arepo.DBForTest())
	user, _ := urepo.Create(shortName(t, "getcomp_"), "$2a$10$hash")
	agent, _ := arepo.Create(user.ID, "Agent", "orig-secret")
	ticket, _ := repo.Create("get-completed-001")
	_ = repo.MarkScanned(ticket.ID, user.ID)
	_ = repo.MarkCompleted(ticket.ID, agent.ID, "the-new-secret")

	// 第一次 GET：应该返回 secret_key
	req := httptest.NewRequest("GET", "/api/pair/tickets/"+ticket.ID, nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	var resp map[string]interface{}
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["status"] != "completed" {
		t.Fatalf("status = %v, want completed", resp["status"])
	}
	if resp["agent_id"] != agent.ID {
		t.Fatalf("agent_id = %v, want %s", resp["agent_id"], agent.ID)
	}
	if resp["secret_key"] != "the-new-secret" {
		t.Fatalf("secret_key = %v, want the-new-secret", resp["secret_key"])
	}
	// owner_user_id 应同步返回（hermes 端用作 home_user）
	if resp["owner_user_id"] != user.ID {
		t.Fatalf("owner_user_id = %v, want %s", resp["owner_user_id"], user.ID)
	}

	// 第二次 GET：领完即焚，secret_key 应消失
	req2 := httptest.NewRequest("GET", "/api/pair/tickets/"+ticket.ID, nil)
	w2 := httptest.NewRecorder()
	r.ServeHTTP(w2, req2)
	var resp2 map[string]interface{}
	json.Unmarshal(w2.Body.Bytes(), &resp2)
	if resp2["status"] != "completed" {
		t.Fatalf("第二次 status = %v, want completed", resp2["status"])
	}
	if _, exists := resp2["secret_key"]; exists {
		t.Fatalf("第二次 GET 不应再返回 secret_key（领完即焚）: %v", resp2["secret_key"])
	}
}

func TestPairingHandler_GetTicket_Expired(t *testing.T) {
	h, repo, _, r := setupPairHandler(t)
	r.GET("/api/pair/tickets/:id", h.GetTicket)

	// 造一条老记录
	old := time.Now().Add(-10 * time.Minute)
	repo.DBForTest().Exec(
		`INSERT INTO pairing_tickets (id, status, created_at) VALUES ($1, 'pending', $2)`,
		"get-expired-001", old,
	)

	req := httptest.NewRequest("GET", "/api/pair/tickets/get-expired-001", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	var resp map[string]interface{}
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["status"] != "expired" {
		t.Fatalf("status = %v, want expired", resp["status"])
	}
}

// ─── Task 9: ScanTicket ──────────────────────────────────────────────────────

func TestPairingHandler_ScanTicket_ReturnsAgentList(t *testing.T) {
	h, repo, arepo, r := setupPairHandler(t)
	urepo := repository.NewUserRepo(arepo.DBForTest())
	user, _ := urepo.Create(shortName(t, "scanlist_"), "$2a$10$hash")
	arepo.Create(user.ID, "ScanAgent1", "s1")
	arepo.Create(user.ID, "ScanAgent2", "s2")

	ticket, _ := repo.Create("scan-001")
	r.POST("/api/pair/tickets/:id/scan", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.ScanTicket(c)
	})

	req := httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/scan", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != 200 {
		t.Fatalf("状态码 %d, body %s", w.Code, w.Body.String())
	}
	var resp map[string]interface{}
	json.Unmarshal(w.Body.Bytes(), &resp)
	agents := resp["agents"].([]interface{})
	if len(agents) != 2 {
		t.Fatalf("agents 数量 %d, want 2", len(agents))
	}
	// 不应含 secret_key
	for _, a := range agents {
		am := a.(map[string]interface{})
		if _, exists := am["secret_key"]; exists {
			t.Fatal("scan 响应的 agent 不应含 secret_key")
		}
	}
}

func TestPairingHandler_ScanTicket_IdempotentSameUser(t *testing.T) {
	h, repo, arepo, r := setupPairHandler(t)
	urepo := repository.NewUserRepo(arepo.DBForTest())
	user, _ := urepo.Create(shortName(t, "scanidem_"), "$2a$10$hash")
	arepo.Create(user.ID, "IdemAgent", "s1")

	ticket, _ := repo.Create("scan-002")
	r.POST("/api/pair/tickets/:id/scan", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.ScanTicket(c)
	})

	// 第一次 scan
	req := httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/scan", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != 200 {
		t.Fatalf("第一次 scan 状态码 %d", w.Code)
	}
	// 第二次 scan（同 user）应幂等成功
	req2 := httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/scan", nil)
	w2 := httptest.NewRecorder()
	r.ServeHTTP(w2, req2)
	if w2.Code != 200 {
		t.Fatalf("第二次幂等 scan 状态码 %d, body %s", w2.Code, w2.Body.String())
	}
}

func TestPairingHandler_ScanTicket_DifferentUserForbidden(t *testing.T) {
	h, repo, _, _ := setupPairHandler(t)
	urepo := repository.NewUserRepo(repo.DBForTest())
	user1, _ := urepo.Create(shortName(t, "scanu1_"), "$2a$10$hash")
	user2, _ := urepo.Create(shortName(t, "scanu2_"), "$2a$10$hash")

	ticket, _ := repo.Create("scan-003")
	// user1 先扫
	r1 := gin.New()
	r1.POST("/api/pair/tickets/:id/scan", func(c *gin.Context) {
		c.Set("userID", user1.ID)
		h.ScanTicket(c)
	})
	r1.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/scan", nil))

	// user2 来扫：应 403
	r2 := gin.New()
	r2.POST("/api/pair/tickets/:id/scan", func(c *gin.Context) {
		c.Set("userID", user2.ID)
		h.ScanTicket(c)
	})
	req2 := httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/scan", nil)
	w2 := httptest.NewRecorder()
	r2.ServeHTTP(w2, req2)
	if w2.Code != http.StatusForbidden {
		t.Fatalf("不同用户 scan 期望 403，实际 %d", w2.Code)
	}
}

func TestPairingHandler_ScanTicket_ExpiredTicket(t *testing.T) {
	h, repo, _, r := setupPairHandler(t)
	r.POST("/api/pair/tickets/:id/scan", func(c *gin.Context) {
		c.Set("userID", "some-user")
		h.ScanTicket(c)
	})

	old := time.Now().Add(-10 * time.Minute)
	repo.DBForTest().Exec(
		`INSERT INTO pairing_tickets (id, status, created_at) VALUES ($1, 'pending', $2)`,
		"scan-expired-001", old,
	)

	req := httptest.NewRequest("POST", "/api/pair/tickets/scan-expired-001/scan", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	var resp map[string]interface{}
	json.Unmarshal(w.Body.Bytes(), &resp)
	if resp["status"] != "expired" {
		t.Fatalf("status = %v, want expired", resp["status"])
	}
}

// ─── Task 10: CompleteTicket ─────────────────────────────────────────────────

func TestPairingHandler_CompleteTicket_SelectExisting_ResetsKey(t *testing.T) {
	h, repo, arepo, r := setupPairHandler(t)
	urepo := repository.NewUserRepo(arepo.DBForTest())
	user, _ := urepo.Create(shortName(t, "compsel_"), "$2a$10$hash")
	agent, _ := arepo.Create(user.ID, "CompleteSelAgent", "orig-secret")
	ticket, _ := repo.Create("complete-sel-001")

	r.POST("/api/pair/tickets/:id/complete", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.CompleteTicket(c)
	})
	r.POST("/api/pair/tickets/:id/scan", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.ScanTicket(c)
	})
	r.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/scan", nil))

	// complete 选已有
	body := strings.NewReader(`{"agent_id":"` + agent.ID + `"}`)
	req2 := httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/complete", body)
	req2.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req2)
	if w.Code != 200 {
		t.Fatalf("状态码 %d, body %s", w.Code, w.Body.String())
	}

	// agent 的 secret_key 应被重置
	after, _ := arepo.GetByID(agent.ID)
	if after.SecretKey == "orig-secret" {
		t.Fatal("secret_key 未被重置")
	}

	// ticket 应进入 completed，且 secret_key 落盘（待 hermes 领）
	got, _ := repo.GetByID(ticket.ID)
	if got.Status != "completed" {
		t.Fatalf("ticket status = %q", got.Status)
	}
	if got.SecretKey == nil || *got.SecretKey != after.SecretKey {
		t.Fatalf("ticket secret_key 与 agent 不一致")
	}
}

func TestPairingHandler_CompleteTicket_CreateNew(t *testing.T) {
	h, repo, arepo, r := setupPairHandler(t)
	urepo := repository.NewUserRepo(arepo.DBForTest())
	user, _ := urepo.Create(shortName(t, "compnew_"), "$2a$10$hash")
	ticket, _ := repo.Create("complete-new-001")

	r.POST("/api/pair/tickets/:id/complete", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.CompleteTicket(c)
	})
	r.POST("/api/pair/tickets/:id/scan", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.ScanTicket(c)
	})
	r.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/scan", nil))

	body := strings.NewReader(`{"new_agent_name":"我的 hermes"}`)
	req := httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/complete", body)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != 200 {
		t.Fatalf("状态码 %d, body %s", w.Code, w.Body.String())
	}

	var resp map[string]interface{}
	json.Unmarshal(w.Body.Bytes(), &resp)
	agentID, _ := resp["agent_id"].(string)
	if agentID == "" {
		t.Fatal("响应缺少 agent_id")
	}
	// owner 应为当前 user
	created, _ := arepo.GetByID(agentID)
	if created.OwnerID != user.ID {
		t.Fatalf("owner = %s, want %s", created.OwnerID, user.ID)
	}
}

func TestPairingHandler_CompleteTicket_NotOwnerForbidden(t *testing.T) {
	h, repo, arepo, r := setupPairHandler(t)
	urepo := repository.NewUserRepo(arepo.DBForTest())
	user1, _ := urepo.Create(shortName(t, "compown1_"), "$2a$10$hash")
	user2, _ := urepo.Create(shortName(t, "compown2_"), "$2a$10$hash")
	// user1 的 agent
	agent, _ := arepo.Create(user1.ID, "Owner1Agent", "s1")
	ticket, _ := repo.Create("complete-forbidden-001")

	r.POST("/api/pair/tickets/:id/complete", func(c *gin.Context) {
		c.Set("userID", user2.ID) // user2 试图绑定 user1 的 agent
		h.CompleteTicket(c)
	})
	r.POST("/api/pair/tickets/:id/scan", func(c *gin.Context) {
		c.Set("userID", user2.ID)
		h.ScanTicket(c)
	})
	r.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/scan", nil))

	body := strings.NewReader(`{"agent_id":"` + agent.ID + `"}`)
	req := httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/complete", body)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	if w.Code != http.StatusForbidden {
		t.Fatalf("越权 complete 期望 403，实际 %d", w.Code)
	}
}

func TestPairingHandler_CompleteTicket_AlreadyCompleted(t *testing.T) {
	h, repo, arepo, r := setupPairHandler(t)
	urepo := repository.NewUserRepo(arepo.DBForTest())
	user, _ := urepo.Create(shortName(t, "comptwice_"), "$2a$10$hash")
	agent, _ := arepo.Create(user.ID, "TwiceAgent", "s1")
	ticket, _ := repo.Create("complete-twice-001")

	r.POST("/api/pair/tickets/:id/complete", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.CompleteTicket(c)
	})
	r.POST("/api/pair/tickets/:id/scan", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.ScanTicket(c)
	})
	r.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/scan", nil))

	body := strings.NewReader(`{"agent_id":"` + agent.ID + `"}`)
	req := httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/complete", body)
	req.Header.Set("Content-Type", "application/json")
	r.ServeHTTP(httptest.NewRecorder(), req)

	// 第二次 complete
	req2 := httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/complete", body)
	req2.Header.Set("Content-Type", "application/json")
	w2 := httptest.NewRecorder()
	r.ServeHTTP(w2, req2)
	if w2.Code != http.StatusBadRequest {
		t.Fatalf("已完成的 ticket 再次 complete 期望 400，实际 %d", w2.Code)
	}
}
