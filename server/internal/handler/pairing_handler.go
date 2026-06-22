package handler

import (
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// PairingHandler 扫码配对处理器。
// 三方握手：hermes 终端（凭 ticket_id）↔ 万灵 server ↔ 万灵 app（凭 user JWT）。
type PairingHandler struct {
	repo      *repository.PairingRepo
	agentRepo *repository.AgentRepo
}

func NewPairingHandler(repo *repository.PairingRepo, agentRepo *repository.AgentRepo) *PairingHandler {
	return &PairingHandler{repo: repo, agentRepo: agentRepo}
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

// CreateTicket POST /api/pair/tickets
// hermes 终端调用，匿名（无鉴权）。生成一张 pending 票据。
func (h *PairingHandler) CreateTicket(c *gin.Context) {
	id, err := generateTicketID()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "生成票据失败"})
		return
	}
	if _, err := h.repo.Create(id); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建票据失败"})
		return
	}
	c.JSON(http.StatusCreated, gin.H{
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
	ticket, err := h.repo.GetByID(id)
	if err != nil || ticket == nil {
		c.JSON(http.StatusOK, gin.H{"status": "not_found"})
		return
	}

	// 过期判定（completed 不算过期）
	if ticket.IsExpired() {
		c.JSON(http.StatusOK, gin.H{"status": statusStr(model.PairingStatusExpired)})
		return
	}

	// completed 且有凭据：返回凭据 + 领完即焚
	if ticket.Status == model.PairingStatusCompleted && ticket.SecretKey != nil && *ticket.SecretKey != "" {
		agentID := ""
		if ticket.AgentID != nil {
			agentID = *ticket.AgentID
		}
		userID := ""
		if ticket.UserID != nil {
			userID = *ticket.UserID
		}
		c.JSON(http.StatusOK, gin.H{
			"status":         statusStr(model.PairingStatusCompleted),
			"agent_id":       agentID,
			"secret_key":     *ticket.SecretKey,
			"owner_user_id":  userID,
		})
		// 领完即焚：清空 secret_key。失败只忽略，不影响已返回的响应。
		_ = h.repo.ClearSecretKey(id)
		return
	}

	// 其他状态：只返 status（completed 已领的也带 agent_id 便于 hermes 日志）
	resp := gin.H{"status": statusStr(ticket.Status)}
	if ticket.Status == model.PairingStatusCompleted && ticket.AgentID != nil {
		resp["agent_id"] = *ticket.AgentID
	}
	c.JSON(http.StatusOK, resp)
}

// ScanTicket POST /api/pair/tickets/:id/scan
// app 扫码后调用（user JWT）。幂等：同 user 重扫返列表，不同 user 403。
// 返回该 user 名下 agent 列表（不含 secret_key）。
func (h *PairingHandler) ScanTicket(c *gin.Context) {
	id := c.Param("id")
	userID := c.GetString("userID")

	ticket, err := h.repo.GetByID(id)
	if err != nil || ticket == nil {
		c.JSON(http.StatusOK, gin.H{"status": "not_found"})
		return
	}
	if ticket.IsExpired() {
		c.JSON(http.StatusOK, gin.H{"status": statusStr(model.PairingStatusExpired)})
		return
	}

	// 幂等：已 scanned
	if ticket.Status == model.PairingStatusScanned {
		if ticket.UserID != nil && *ticket.UserID != userID {
			c.JSON(http.StatusForbidden, gin.H{"error": "该配对码已被其他用户使用"})
			return
		}
		// 同 user，落库到下方统一返列表
	} else if ticket.Status != model.PairingStatusPending {
		// completed 等其他状态不允许 scan
		c.JSON(http.StatusBadRequest, gin.H{"error": "配对码状态不可用"})
		return
	} else {
		// 首次 scan：写 user_id + scanned
		if err := h.repo.MarkScanned(id, userID); err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "扫码失败"})
			return
		}
	}

	agents, err := h.agentRepo.ListByOwner(userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询 Agent 失败"})
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
	c.JSON(http.StatusOK, gin.H{"agents": summaries})
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
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	ticket, err := h.repo.GetByID(id)
	if err != nil || ticket == nil {
		c.JSON(http.StatusOK, gin.H{"status": "not_found"})
		return
	}
	if ticket.IsExpired() {
		c.JSON(http.StatusOK, gin.H{"status": statusStr(model.PairingStatusExpired)})
		return
	}
	if ticket.Status != model.PairingStatusScanned {
		c.JSON(http.StatusBadRequest, gin.H{"error": "配对码状态不可用"})
		return
	}
	if ticket.UserID == nil || *ticket.UserID != userID {
		c.JSON(http.StatusForbidden, gin.H{"error": "无权操作该配对码"})
		return
	}

	var agentID, secretKey, agentName string

	switch {
	case req.AgentID != "":
		// 选已有：校验 owner
		agent, err := h.agentRepo.GetByID(req.AgentID)
		if err != nil || agent == nil {
			c.JSON(http.StatusNotFound, gin.H{"error": "Agent 不存在"})
			return
		}
		if agent.OwnerID != userID {
			c.JSON(http.StatusForbidden, gin.H{"error": "无权操作该 Agent"})
			return
		}
		newKey, err := h.agentRepo.ResetSecretKey(agent.ID)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "重置密钥失败"})
			return
		}
		agentID = agent.ID
		agentName = agent.Name
		secretKey = newKey

	case req.NewAgentName != "":
		// 新建
		newKey, err := generateTicketID() // 复用 256-bit hex 生成
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "生成密钥失败"})
			return
		}
		agent, err := h.agentRepo.Create(userID, req.NewAgentName, newKey)
		if err != nil {
			c.JSON(http.StatusInternalServerError, gin.H{"error": "创建 Agent 失败"})
			return
		}
		agentID = agent.ID
		agentName = agent.Name
		secretKey = newKey

	default:
		c.JSON(http.StatusBadRequest, gin.H{"error": "必须提供 agent_id 或 new_agent_name"})
		return
	}

	// ticket 落 completed + 凭据（待 hermes 领）
	if err := h.repo.MarkCompleted(id, agentID, secretKey); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "完成配对失败"})
		return
	}

	c.JSON(http.StatusOK, gin.H{
		"agent_id":      agentID,
		"agent_name":    agentName,
		"owner_user_id": userID,
	})
}
