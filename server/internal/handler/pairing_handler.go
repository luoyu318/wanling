package handler

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// PairingHandler 扫码配对处理器。
// 三方握手：hermes 终端（凭 ticket_id）↔ 万灵 server ↔ 万灵 app（凭 user JWT）。
type PairingHandler struct {
	repo      *repository.PairingRepo
	agentRepo *repository.AgentRepo
	convRepo  *repository.ConversationRepo
}

func NewPairingHandler(repo *repository.PairingRepo, agentRepo *repository.AgentRepo, convRepo *repository.ConversationRepo) *PairingHandler {
	return &PairingHandler{repo: repo, agentRepo: agentRepo, convRepo: convRepo}
}

// generateTicketID 生成 256-bit hex ticket_id（32 字节 → 64 字符）。
// 作为 ticket 自身的鉴权凭据，不可猜。
func generateTicketID() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// statusStr 把 model.PairingStatus 转 JSON 响应里的 status 字符串。
func statusStr(s model.PairingStatus) string { return string(s) }

// CreateTicketRequest create 请求体。type 可选(默认空串=普通 agent,
// opencode=OpenCode agent),由 hermes 声明自己类型,CompleteTicket 透传到新建 agent。
type CreateTicketRequest struct {
	Type string `json:"type" binding:"omitempty,max=32"`
}

// CreateTicket POST /api/pair/tickets
// hermes 终端调用，匿名（无鉴权）。生成一张 pending 票据。
// 请求 body 可选 {type} 声明 agent 类型(opencode 等),默认空串=普通 agent。
// type 存入 ticket,CompleteTicket 读它建对应类型的 agent,实现 type 全链路透传。
func (h *PairingHandler) CreateTicket(c *gin.Context) {
	var req CreateTicketRequest
	// body 可空(老 hermes 不传 body),忽略 EOF;非空时校验 binding。
	if err := c.ShouldBindJSON(&req); err != nil && !errors.Is(err, io.EOF) {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	id, err := generateTicketID()
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "生成票据失败")
		return
	}
	if _, err := h.repo.Create(c.Request.Context(), id, req.Type); err != nil {
		ErrMsg(c, http.StatusInternalServerError, "创建票据失败")
		return
	}
	OkCreated(c, gin.H{
		"ticket_id":   id,
		"server_time": time.Now().UTC().Format(time.RFC3339),
	})
}

// GetTicket GET /api/pair/tickets/:id
// hermes 终端轮询。统一返 200 + {status}。
//   - completed 且 secret_key 未领过：返回凭据，并立即清空（领完即焚）
//   - completed 且 secret_key 已领：返 completed（带 agent_id，不带凭据）
//   - pending/scanned：返对应 status
//   - 过期：返 expired
//   - 不存在：返 not_found
func (h *PairingHandler) GetTicket(c *gin.Context) {
	id := c.Param("id")
	ticket, err := h.repo.GetByID(c.Request.Context(), id)
	if err != nil || ticket == nil {
		Ok(c, gin.H{"status": "not_found"})
		return
	}

	// 过期判定（completed 不算过期）
	if ticket.IsExpired() {
		Ok(c, gin.H{"status": statusStr(model.PairingStatusExpired)})
		return
	}

	// completed 且有凭据：原子消费（UPDATE...RETURNING 读+清原子，消除竞态）
	if ticket.Status == model.PairingStatusCompleted && ticket.SecretKey != nil && *ticket.SecretKey != "" {
		secretKey, agentID, userID, err := h.repo.ConsumeSecretKey(c.Request.Context(), id)
		if err != nil {
			ErrMsg(c, http.StatusInternalServerError, "消费凭据失败")
			return
		}
		if secretKey == "" {
			// 已被其他消费者领走
			resp := gin.H{"status": statusStr(model.PairingStatusCompleted)}
			if ticket.AgentID != nil {
				resp["agent_id"] = *ticket.AgentID
			}
			Ok(c, resp)
			return
		}
		Ok(c, gin.H{
			"status":        statusStr(model.PairingStatusCompleted),
			"agent_id":      agentID,
			"secret_key":    secretKey,
			"owner_user_id": userID,
			"owner_conv_id": h.lookupOwnerConvID(c, userID, agentID),
		})
		return
	}

	// 其他状态：只返 status（completed 已领的也带 agent_id 便于 hermes 日志）
	resp := gin.H{"status": statusStr(ticket.Status)}
	if ticket.Status == model.PairingStatusCompleted && ticket.AgentID != nil {
		resp["agent_id"] = *ticket.AgentID
	}
	Ok(c, resp)
}

// ScanTicket POST /api/pair/tickets/:id/scan
// app 扫码后调用（user JWT）。幂等：同 user 重扫返列表，不同 user 403。
// 返回该 user 名下 agent 列表（不含 secret_key）。
func (h *PairingHandler) ScanTicket(c *gin.Context) {
	id := c.Param("id")
	userID := c.GetString("userID")

	ticket, err := h.repo.GetByID(c.Request.Context(), id)
	if err != nil || ticket == nil {
		Ok(c, gin.H{"status": "not_found"})
		return
	}
	if ticket.IsExpired() {
		Ok(c, gin.H{"status": statusStr(model.PairingStatusExpired)})
		return
	}

	// 幂等：已 scanned
	if ticket.Status == model.PairingStatusScanned {
		if ticket.UserID != nil && *ticket.UserID != userID {
			Err(c, http.StatusForbidden, "forbidden", "该配对码已被其他用户使用")
			return
		}
		// 同 user，落库到下方统一返列表
	} else if ticket.Status != model.PairingStatusPending {
		// completed 等其他状态不允许 scan
		Err(c, http.StatusBadRequest, "bad_request", "配对码状态不可用")
		return
	} else {
		// 首次 scan：写 user_id + scanned
		if err := h.repo.MarkScanned(c.Request.Context(), id, userID); err != nil {
			ErrMsg(c, http.StatusInternalServerError, "扫码失败")
			return
		}
	}

	agents, err := h.agentRepo.ListByOwner(c.Request.Context(), userID)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "查询 Agent 失败")
		return
	}
	// 转成摘要去掉 secret_key（ListByOwner 返回完整 Agent）
	summaries := make([]gin.H, 0, len(agents))
	for _, a := range agents {
		summaries = append(summaries, gin.H{
			"id":         a.ID,
			"name":       a.Name,
			"avatar_url": a.AvatarURL,
			"bio":        a.Bio,
			"status":     string(a.Status),
		})
	}
	Ok(c, summaries)
}

// CompleteTicketRequest complete 请求。二选一：agent_id（选已有）或 new_agent_name（新建）。
type CompleteTicketRequest struct {
	AgentID      string `json:"agent_id"`
	NewAgentName string `json:"new_agent_name"`
}

// CompleteTicket POST /api/pair/tickets/:id/complete（user JWT）
// app 选/建 agent 后调用。校验 ticket 是 scanned 且 user 匹配。
//   - {agent_id}：校验 owner，重置 secret_key，ticket 落 completed
//   - {new_agent_name}：创建新 agent（owner=JWT user），ticket 落 completed
//
// 凭据通过 GET /tickets/:id 领取（领完即焚），complete 响应不含 secret_key。
func (h *PairingHandler) CompleteTicket(c *gin.Context) {
	id := c.Param("id")
	userID := c.GetString("userID")

	var req CompleteTicketRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		Err(c, http.StatusBadRequest, "bad_request", err.Error())
		return
	}

	ticket, err := h.repo.GetByID(c.Request.Context(), id)
	if err != nil || ticket == nil {
		Ok(c, gin.H{"status": "not_found"})
		return
	}
	if ticket.IsExpired() {
		Ok(c, gin.H{"status": statusStr(model.PairingStatusExpired)})
		return
	}
	if ticket.Status != model.PairingStatusScanned {
		Err(c, http.StatusBadRequest, "bad_request", "配对码状态不可用")
		return
	}
	if ticket.UserID == nil || *ticket.UserID != userID {
		Err(c, http.StatusForbidden, "forbidden", "无权操作该配对码")
		return
	}

	var agentID, secretKey, agentName string

	switch {
	case req.AgentID != "":
		// 选已有：校验 owner
		agent, err := h.agentRepo.GetByID(c.Request.Context(), req.AgentID)
		if err != nil || agent == nil {
			Err(c, http.StatusNotFound, "not_found", "Agent 不存在")
			return
		}
		if agent.OwnerID != userID {
			Err(c, http.StatusForbidden, "forbidden", "无权操作该 Agent")
			return
		}
		newKey, err := h.agentRepo.ResetSecretKey(c.Request.Context(), agent.ID)
		if err != nil {
			ErrMsg(c, http.StatusInternalServerError, "重置密钥失败")
			return
		}
		// 补写 agent type:ticket 带 type(如 opencode)但老 agent.Type="" 时,
		// 更新 agent type 让多 session 功能生效。type 一致或 ticket 无 type 时跳过。
		if ticket.Type != "" && string(agent.Type) != ticket.Type {
			if err := h.agentRepo.UpdateType(c.Request.Context(), agent.ID, ticket.Type); err != nil {
				logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "pairing UpdateType 失败",
					"agent_id", agent.ID, "type", ticket.Type, "err", err)
				ErrMsg(c, http.StatusInternalServerError, "更新 Agent 类型失败")
				return
			}
		}
		agentID = agent.ID
		agentName = agent.Name
		secretKey = newKey

	case req.NewAgentName != "":
		// 新建:用 ticket.Type 透传 agent 类型(opencode 等),默认空串=普通 agent。
		newKey, err := generateTicketID() // 复用 256-bit hex 生成
		if err != nil {
			ErrMsg(c, http.StatusInternalServerError, "生成密钥失败")
			return
		}
		agent, err := h.agentRepo.Create(c.Request.Context(), userID, req.NewAgentName, newKey, ticket.Type)
		if err != nil {
			ErrMsg(c, http.StatusInternalServerError, "创建 Agent 失败")
			return
		}
		// 建 owner↔agent 默认 conv(对齐 agent_handler.Create 行为,
		// 让 pairing 一次性返完整 owner_conv_id,client 无需再 find_or_create)
		// fail-soft:conv 建失败只 log,后续 lookupOwnerConvID 会返空,client 端可兜底。
		if _, err := h.convRepo.FindOrCreateDM(c.Request.Context(), model.ConvTypeDMUserAgent, repository.DMMembers{
			Initiator: repository.ParticipantInput{MemberID: userID, MemberType: "user", Role: "owner"},
			Other:     repository.ParticipantInput{MemberID: agent.ID, MemberType: "agent", Role: "member"},
		}); err != nil {
			logpkg.FromCtx(c.Request.Context()).ErrorContext(c.Request.Context(), "pairing 建默认 conv 失败",
				"agent_id", agent.ID, "owner_id", userID, "err", err)
		}
		agentID = agent.ID
		agentName = agent.Name
		secretKey = newKey

	default:
		Err(c, http.StatusBadRequest, "bad_request", "必须提供 agent_id 或 new_agent_name")
		return
	}

	// ticket 落 completed + 凭据（待 hermes 领）
	if err := h.repo.MarkCompleted(c.Request.Context(), id, agentID, secretKey); err != nil {
		ErrMsg(c, http.StatusInternalServerError, "完成配对失败")
		return
	}

	Ok(c, gin.H{
		"agent_id":      agentID,
		"agent_name":    agentName,
		"owner_user_id": userID,
		"owner_conv_id": h.lookupOwnerConvID(c, userID, agentID),
	})
}

// lookupOwnerConvID 读 owner↔agent 默认 conv(agent 创建时已建好)。
// 失败时返空串(不阻塞响应),client 端可后续 find_or_create 兜底。
func (h *PairingHandler) lookupOwnerConvID(c *gin.Context, userID, agentID string) string {
	if userID == "" || agentID == "" || h.convRepo == nil {
		return ""
	}
	conv, err := h.convRepo.FindDMByOwnerAgent(c.Request.Context(), userID, agentID)
	if err != nil {
		return ""
	}
	if conv == nil {
		return ""
	}
	return conv.ID
}
