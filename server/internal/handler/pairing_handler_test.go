package handler

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// setupPairHandler 公共构造：起 PG + 建 handler + gin router。
// 返回 (handler, pairingRepo, agentRepo, convRepo, router)，测试自己注入 userID 模拟 JWT。
func setupPairHandler(t *testing.T) (*PairingHandler, *repository.PairingRepo, *repository.AgentRepo, *repository.ConversationRepo, *gin.Engine) {
	t.Helper()
	gin.SetMode(gin.TestMode)
	db := repository.SetupTestDB(t)
	repo := repository.NewPairingRepo(db)
	arepo := repository.NewAgentRepo(db)
	crepo := repository.NewConversationRepo(db)
	h := NewPairingHandler(repo, arepo, crepo)
	r := gin.New()
	return h, repo, arepo, crepo, r
}

// ─── Task 7: CreateTicket ────────────────────────────────────────────────────

func TestPairingHandler_CreateTicket_ReturnsTicketID(t *testing.T) {
	h, _, _, _, r := setupPairHandler(t)
	r.POST("/api/pair/tickets", h.CreateTicket)

	req := httptest.NewRequest("POST", "/api/pair/tickets", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	data := AssertOk(t, w, http.StatusCreated)
	ticketID, ok := data["ticket_id"].(string)
	if !ok || ticketID == "" {
		t.Fatalf("响应缺少 ticket_id: %v", data)
	}
	// 256-bit hex = 64 字符
	if len(ticketID) != 64 {
		t.Fatalf("ticket_id 长度 %d，期望 64", len(ticketID))
	}
}

// 两次生成的 ticket_id 不能相同。
func TestPairingHandler_CreateTicket_UniqueIDs(t *testing.T) {
	h, _, _, _, r := setupPairHandler(t)
	r.POST("/api/pair/tickets", h.CreateTicket)

	ids := map[string]bool{}
	for i := 0; i < 10; i++ {
		req := httptest.NewRequest("POST", "/api/pair/tickets", nil)
		w := httptest.NewRecorder()
		r.ServeHTTP(w, req)
		data := AssertOk(t, w, http.StatusCreated)
		id := data["ticket_id"].(string)
		if ids[id] {
			t.Fatalf("第 %d 次生成的 ticket_id 重复: %s", i+1, id)
		}
		ids[id] = true
	}
}

// ─── Task 8: GetTicket ───────────────────────────────────────────────────────

func TestPairingHandler_GetTicket_Pending(t *testing.T) {
	h, repo, _, _, r := setupPairHandler(t)
	r.GET("/api/pair/tickets/:id", h.GetTicket)

	ticket, _ := repo.Create(t.Context(), "get-pending-001", "")
	req := httptest.NewRequest("GET", "/api/pair/tickets/"+ticket.ID, nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	data := AssertOk(t, w, http.StatusOK)
	if data["status"] != "pending" {
		t.Fatalf("status = %v, want pending", data["status"])
	}
	if _, exists := data["secret_key"]; exists {
		t.Fatal("pending 状态不应返回 secret_key")
	}
}

func TestPairingHandler_GetTicket_NotFound(t *testing.T) {
	h, _, _, _, r := setupPairHandler(t)
	r.GET("/api/pair/tickets/:id", h.GetTicket)

	req := httptest.NewRequest("GET", "/api/pair/tickets/nonexistent-id", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	data := AssertOk(t, w, http.StatusOK)
	if data["status"] != "not_found" {
		t.Fatalf("status = %v, want not_found", data["status"])
	}
}

func TestPairingHandler_GetTicket_Completed_ReturnsSecretKeyOnce(t *testing.T) {
	h, repo, arepo, crepo, r := setupPairHandler(t)
	r.GET("/api/pair/tickets/:id", h.GetTicket)

	urepo := repository.NewUserRepo(arepo.DBForTest())
	user, _ := urepo.Create(t.Context(), shortName(t, "getcomp_"), "$2a$10$hash")
	agent, _ := arepo.Create(t.Context(), user.ID, "Agent", "orig-secret", "")
	// arepo.Create 绕过 agent_handler.Create,需手动建 owner↔agent conv
	// 模拟真实场景(pairing/agent_handler.Create 都会兜底建)
	conv, _ := crepo.FindOrCreateDM(t.Context(), model.ConvTypeDMUserAgent, repository.DMMembers{
		Initiator: repository.ParticipantInput{MemberID: user.ID, MemberType: "user", Role: "owner"},
		Other:     repository.ParticipantInput{MemberID: agent.ID, MemberType: "agent", Role: "member"},
	})
	ticket, _ := repo.Create(t.Context(), "get-completed-001", "")
	_ = repo.MarkScanned(t.Context(), ticket.ID, user.ID)
	_ = repo.MarkCompleted(t.Context(), ticket.ID, agent.ID, "the-new-secret")

	// 第一次 GET：应该返回 secret_key + owner_conv_id
	req := httptest.NewRequest("GET", "/api/pair/tickets/"+ticket.ID, nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	data := AssertOk(t, w, http.StatusOK)
	if data["status"] != "completed" {
		t.Fatalf("status = %v, want completed", data["status"])
	}
	if data["agent_id"] != agent.ID {
		t.Fatalf("agent_id = %v, want %s", data["agent_id"], agent.ID)
	}
	if data["secret_key"] != "the-new-secret" {
		t.Fatalf("secret_key = %v, want the-new-secret", data["secret_key"])
	}
	// owner_user_id 应同步返回（hermes 端用作 home_user）
	if data["owner_user_id"] != user.ID {
		t.Fatalf("owner_user_id = %v, want %s", data["owner_user_id"], user.ID)
	}
	// owner_conv_id 应为已建的默认 conv(hermes 端写 WANLING_HOME_CONV)
	if data["owner_conv_id"] != conv.ID {
		t.Fatalf("owner_conv_id = %v, want %s", data["owner_conv_id"], conv.ID)
	}

	// 第二次 GET：领完即焚，secret_key 应消失
	req2 := httptest.NewRequest("GET", "/api/pair/tickets/"+ticket.ID, nil)
	w2 := httptest.NewRecorder()
	r.ServeHTTP(w2, req2)
	data2 := AssertOk(t, w2, http.StatusOK)
	if data2["status"] != "completed" {
		t.Fatalf("第二次 status = %v, want completed", data2["status"])
	}
	if _, exists := data2["secret_key"]; exists {
		t.Fatalf("第二次 GET 不应再返回 secret_key（领完即焚）: %v", data2["secret_key"])
	}
}

func TestPairingHandler_GetTicket_Expired(t *testing.T) {
	h, repo, _, _, r := setupPairHandler(t)
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
	data := AssertOk(t, w, http.StatusOK)
	if data["status"] != "expired" {
		t.Fatalf("status = %v, want expired", data["status"])
	}
}

// ─── Task 9: ScanTicket ──────────────────────────────────────────────────────

func TestPairingHandler_ScanTicket_ReturnsAgentList(t *testing.T) {
	h, repo, arepo, _, r := setupPairHandler(t)
	urepo := repository.NewUserRepo(arepo.DBForTest())
	user, _ := urepo.Create(t.Context(), shortName(t, "scanlist_"), "$2a$10$hash")
	arepo.Create(t.Context(), user.ID, "ScanAgent1", "s1", "")
	arepo.Create(t.Context(), user.ID, "ScanAgent2", "s2", "")

	ticket, _ := repo.Create(t.Context(), "scan-001", "")
	r.POST("/api/pair/tickets/:id/scan", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.ScanTicket(c)
	})

	req := httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/scan", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	agents := AssertOkList(t, w, http.StatusOK)
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
	h, repo, arepo, _, r := setupPairHandler(t)
	urepo := repository.NewUserRepo(arepo.DBForTest())
	user, _ := urepo.Create(t.Context(), shortName(t, "scanidem_"), "$2a$10$hash")
	arepo.Create(t.Context(), user.ID, "IdemAgent", "s1", "")

	ticket, _ := repo.Create(t.Context(), "scan-002", "")
	r.POST("/api/pair/tickets/:id/scan", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.ScanTicket(c)
	})

	// 第一次 scan
	req := httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/scan", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	AssertOkList(t, w, http.StatusOK)
	// 第二次 scan（同 user）应幂等成功
	req2 := httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/scan", nil)
	w2 := httptest.NewRecorder()
	r.ServeHTTP(w2, req2)
	AssertOkList(t, w2, http.StatusOK)
}

func TestPairingHandler_ScanTicket_DifferentUserForbidden(t *testing.T) {
	h, repo, _, _, _ := setupPairHandler(t)
	urepo := repository.NewUserRepo(repo.DBForTest())
	user1, _ := urepo.Create(t.Context(), shortName(t, "scanu1_"), "$2a$10$hash")
	user2, _ := urepo.Create(t.Context(), shortName(t, "scanu2_"), "$2a$10$hash")

	ticket, _ := repo.Create(t.Context(), "scan-003", "")
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
	AssertErr(t, w2, http.StatusForbidden, "forbidden")
}

func TestPairingHandler_ScanTicket_ExpiredTicket(t *testing.T) {
	h, repo, _, _, r := setupPairHandler(t)
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
	data := AssertOk(t, w, http.StatusOK)
	if data["status"] != "expired" {
		t.Fatalf("status = %v, want expired", data["status"])
	}
}

// ─── Task 10: CompleteTicket ─────────────────────────────────────────────────

func TestPairingHandler_CompleteTicket_SelectExisting_ResetsKey(t *testing.T) {
	h, repo, arepo, _, r := setupPairHandler(t)
	urepo := repository.NewUserRepo(arepo.DBForTest())
	user, _ := urepo.Create(t.Context(), shortName(t, "compsel_"), "$2a$10$hash")
	agent, _ := arepo.Create(t.Context(), user.ID, "CompleteSelAgent", "orig-secret", "")
	ticket, _ := repo.Create(t.Context(), "complete-sel-001", "")

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
	AssertOk(t, w, http.StatusOK)

	// agent 的 secret_key 应被重置
	after, _ := arepo.GetByID(t.Context(), agent.ID)
	if after.SecretKey == "orig-secret" {
		t.Fatal("secret_key 未被重置")
	}

	// ticket 应进入 completed，且 secret_key 落盘（待 hermes 领）
	got, _ := repo.GetByID(t.Context(), ticket.ID)
	if got.Status != "completed" {
		t.Fatalf("ticket status = %q", got.Status)
	}
	if got.SecretKey == nil || *got.SecretKey != after.SecretKey {
		t.Fatalf("ticket secret_key 与 agent 不一致")
	}
}

func TestPairingHandler_CompleteTicket_CreateNew(t *testing.T) {
	h, repo, arepo, crepo, r := setupPairHandler(t)
	urepo := repository.NewUserRepo(arepo.DBForTest())
	user, _ := urepo.Create(t.Context(), shortName(t, "compnew_"), "$2a$10$hash")
	ticket, _ := repo.Create(t.Context(), "complete-new-001", "")

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
	data := AssertOk(t, w, http.StatusOK)
	agentID, _ := data["agent_id"].(string)
	if agentID == "" {
		t.Fatal("响应缺少 agent_id")
	}
	// owner 应为当前 user
	created, _ := arepo.GetByID(t.Context(), agentID)
	if created.OwnerID != user.ID {
		t.Fatalf("owner = %s, want %s", created.OwnerID, user.ID)
	}
	// handler 内部应已建 owner↔agent 默认 conv,响应返 owner_conv_id
	convID, _ := data["owner_conv_id"].(string)
	if convID == "" {
		t.Fatalf("owner_conv_id 不应为空(handler CreateNew 分支应建 conv): %s", w.Body.String())
	}
	conv, err := crepo.FindDMByOwnerAgent(t.Context(), user.ID, agentID)
	if err != nil || conv == nil || conv.ID != convID {
		t.Fatalf("DB 默认 conv 不一致: 期望 %s 实际 %+v err=%v", convID, conv, err)
	}
}

func TestPairingHandler_CompleteTicket_NotOwnerForbidden(t *testing.T) {
	h, repo, arepo, _, r := setupPairHandler(t)
	urepo := repository.NewUserRepo(arepo.DBForTest())
	user1, _ := urepo.Create(t.Context(), shortName(t, "compown1_"), "$2a$10$hash")
	user2, _ := urepo.Create(t.Context(), shortName(t, "compown2_"), "$2a$10$hash")
	// user1 的 agent
	agent, _ := arepo.Create(t.Context(), user1.ID, "Owner1Agent", "s1", "")
	ticket, _ := repo.Create(t.Context(), "complete-forbidden-001", "")

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
	AssertErr(t, w, http.StatusForbidden, "forbidden")
}

func TestPairingHandler_CompleteTicket_AlreadyCompleted(t *testing.T) {
	h, repo, arepo, _, r := setupPairHandler(t)
	urepo := repository.NewUserRepo(arepo.DBForTest())
	user, _ := urepo.Create(t.Context(), shortName(t, "comptwice_"), "$2a$10$hash")
	agent, _ := arepo.Create(t.Context(), user.ID, "TwiceAgent", "s1", "")
	ticket, _ := repo.Create(t.Context(), "complete-twice-001", "")

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
	AssertErr(t, w2, http.StatusBadRequest, "bad_request")
}

// ─── Part B: agent type 透传 ─────────────────────────────────────────────────

// TestPairingHandler_CreateTicket_AcceptsType 验证 CreateTicket 接受 body 里的
// type 字段并落库(opencode),且空 body(老 hermes)仍兼容。
func TestPairingHandler_CreateTicket_AcceptsType(t *testing.T) {
	h, repo, _, _, r := setupPairHandler(t)
	r.POST("/api/pair/tickets", h.CreateTicket)

	// 带 type=opencode 的 body
	body := strings.NewReader(`{"type":"opencode"}`)
	req := httptest.NewRequest("POST", "/api/pair/tickets", body)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	data := AssertOk(t, w, http.StatusCreated)
	ticketID := data["ticket_id"].(string)

	got, err := repo.GetByID(t.Context(), ticketID)
	if err != nil || got == nil {
		t.Fatalf("GetByID: %v %v", got, err)
	}
	if got.Type != "opencode" {
		t.Errorf("ticket.Type = %q, want opencode", got.Type)
	}
}

// TestPairingHandler_CreateTicket_EmptyBodyBackwardCompat 老 hermes 不传 body
// (Content-Length: 0),CreateTicket 应正常建 ticket(type 默认空串)。
func TestPairingHandler_CreateTicket_EmptyBodyBackwardCompat(t *testing.T) {
	h, _, _, _, r := setupPairHandler(t)
	r.POST("/api/pair/tickets", h.CreateTicket)

	// 空 body(老 hermes 行为)
	req := httptest.NewRequest("POST", "/api/pair/tickets", nil)
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	AssertOk(t, w, http.StatusCreated)
}

// TestPairingHandler_CompleteTicket_TypePassthrough 验收红线:CreateTicket 带
// type=opencode → CompleteTicket(new_agent_name)建的 agent.Type == "opencode"。
// 这是 Phase B Task 7 发现的 bug 修复:之前硬编码空串,扫码配对的 agent 永远是 default。
func TestPairingHandler_CompleteTicket_TypePassthrough(t *testing.T) {
	h, _, arepo, _, r := setupPairHandler(t)
	urepo := repository.NewUserRepo(arepo.DBForTest())
	user, _ := urepo.Create(t.Context(), shortName(t, "passt_"), "$2a$10$hash")

	// 1. CreateTicket 带 type=opencode(模拟 opencode plugin 终端)
	body := strings.NewReader(`{"type":"opencode"}`)
	createReq := httptest.NewRequest("POST", "/api/pair/tickets", body)
	createReq.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.POST("/api/pair/tickets", h.CreateTicket)
	r.ServeHTTP(w, createReq)
	ticketID := AssertOk(t, w, http.StatusCreated)["ticket_id"].(string)

	// 2. scan + complete(模拟 APP 扫码后建新 agent)
	r.POST("/api/pair/tickets/:id/scan", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.ScanTicket(c)
	})
	r.POST("/api/pair/tickets/:id/complete", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.CompleteTicket(c)
	})
	r.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("POST", "/api/pair/tickets/"+ticketID+"/scan", nil))

	completeBody := strings.NewReader(`{"new_agent_name":"my opencode"}`)
	completeReq := httptest.NewRequest("POST", "/api/pair/tickets/"+ticketID+"/complete", completeBody)
	completeReq.Header.Set("Content-Type", "application/json")
	w2 := httptest.NewRecorder()
	r.ServeHTTP(w2, completeReq)
	data := AssertOk(t, w2, http.StatusOK)
	agentID := data["agent_id"].(string)

	// 3. 验收:建的 agent.Type == opencode(而非硬编码空串)
	created, _ := arepo.GetByID(t.Context(), agentID)
	if created.Type != "opencode" {
		t.Fatalf("agent.Type = %q, want opencode(type 未透传)", created.Type)
	}
}

// TestPairingHandler_CompleteTicket_DefaultTypeNoTicketType 验证不带 type 的
// 老流程(ticket.Type="")建的 agent 仍是 default(空串),保持向后兼容。
func TestPairingHandler_CompleteTicket_DefaultTypeNoTicketType(t *testing.T) {
	h, repo, arepo, _, r := setupPairHandler(t)
	urepo := repository.NewUserRepo(arepo.DBForTest())
	user, _ := urepo.Create(t.Context(), shortName(t, "deftp_"), "$2a$10$hash")
	// 老 ticket(无 type)
	ticket, _ := repo.Create(t.Context(), "default-type-001", "")

	r.POST("/api/pair/tickets/:id/scan", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.ScanTicket(c)
	})
	r.POST("/api/pair/tickets/:id/complete", func(c *gin.Context) {
		c.Set("userID", user.ID)
		h.CompleteTicket(c)
	})
	r.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/scan", nil))

	body := strings.NewReader(`{"new_agent_name":"normal agent"}`)
	req := httptest.NewRequest("POST", "/api/pair/tickets/"+ticket.ID+"/complete", body)
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	agentID := AssertOk(t, w, http.StatusOK)["agent_id"].(string)

	created, _ := arepo.GetByID(t.Context(), agentID)
	if created.Type != "" {
		t.Errorf("agent.Type = %q, want empty(默认)", created.Type)
	}
}

// TestPairingHandler_CompleteTicket_SelectExisting_UpdatesType 验证 I2 修复:
// 选已有 agent 分支,ticket 带 type=opencode 但老 agent.Type="" 时,
// CompleteTicket 应把 agent.Type 补写为 opencode。
func TestPairingHandler_CompleteTicket_SelectExisting_UpdatesType(t *testing.T) {
	h, repo, arepo, _, r := setupPairHandler(t)
	urepo := repository.NewUserRepo(arepo.DBForTest())
	user, _ := urepo.Create(t.Context(), shortName(t, "selt_"), "$2a$10$hash")
	// 老 agent(type="",普通 agent)
	agent, _ := arepo.Create(t.Context(), user.ID, "OldAgent", "orig-secret", "")
	ticket, _ := repo.Create(t.Context(), "complete-type-001", "opencode")

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
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	AssertOk(t, w, http.StatusOK)

	// 验收:agent.Type 应被补写为 opencode
	after, _ := arepo.GetByID(t.Context(), agent.ID)
	if string(after.Type) != "opencode" {
		t.Fatalf("agent.Type = %q, want opencode(选已有分支未补写 type)", after.Type)
	}
}

// TestPairingHandler_CompleteTicket_SelectExisting_TypeMatch_NoUpdate 验证
// ticket.Type 与 agent.Type 已一致时不触发多余 UPDATE(边界:type="" 老流程不误改)。
func TestPairingHandler_CompleteTicket_SelectExisting_TypeMatch_NoUpdate(t *testing.T) {
	h, repo, arepo, _, r := setupPairHandler(t)
	urepo := repository.NewUserRepo(arepo.DBForTest())
	user, _ := urepo.Create(t.Context(), shortName(t, "seltm_"), "$2a$10$hash")
	// ticket 无 type(老 hermes),老 agent 也 type=""
	agent, _ := arepo.Create(t.Context(), user.ID, "PlainAgent", "orig-secret", "")
	ticket, _ := repo.Create(t.Context(), "complete-notype-001", "")

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
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)
	AssertOk(t, w, http.StatusOK)

	// agent.Type 仍应为空串(未被误改)
	after, _ := arepo.GetByID(t.Context(), agent.ID)
	if string(after.Type) != "" {
		t.Errorf("agent.Type = %q, want empty(ticket 无 type 不应误改)", after.Type)
	}
}
