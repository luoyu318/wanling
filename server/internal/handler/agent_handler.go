package handler

import (
	"crypto/rand"
	"encoding/hex"
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/presence"
	"github.com/wanling/server/internal/repository"
)

type AgentHandler struct {
	agentRepo *repository.AgentRepo
	presence  *presence.Presence
}

func NewAgentHandler(agentRepo *repository.AgentRepo, p *presence.Presence) *AgentHandler {
	return &AgentHandler{agentRepo: agentRepo, presence: p}
}

func generateSecretKey() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

type CreateAgentRequest struct {
	Name string `json:"name" binding:"required"`
}

func (h *AgentHandler) Create(c *gin.Context) {
	var req CreateAgentRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	userID := c.GetString("userID")
	secretKey, err := generateSecretKey()
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "生成密钥失败"})
		return
	}

	agent, err := h.agentRepo.Create(userID, req.Name, secretKey)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "创建失败"})
		return
	}

	c.JSON(http.StatusCreated, agent)
}

func (h *AgentHandler) List(c *gin.Context) {
	userID := c.GetString("userID")
	agents, err := h.agentRepo.ListByOwner(userID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "查询失败"})
		return
	}
	if agents == nil {
		agents = []model.Agent{}
	}
	for i := range agents {
		if h.presence.IsOnline("agent", agents[i].ID) {
			agents[i].Status = model.AgentStatusOnline
		} else {
			agents[i].Status = model.AgentStatusOffline
		}
	}
	c.JSON(http.StatusOK, agents)
}

type UpdateAgentRequest struct {
	Name      string  `json:"name"       binding:"omitempty,max=128"`
	AvatarURL string  `json:"avatar_url" binding:"omitempty,max=256"`
	Bio       *string `json:"bio"        binding:"omitempty,max=200"`
}

func (h *AgentHandler) Update(c *gin.Context) {
	id := c.Param("id")
	var req UpdateAgentRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"error": err.Error()})
		return
	}

	agent, err := h.agentRepo.Update(id, req.Name, req.AvatarURL, req.Bio)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "更新失败"})
		return
	}
	if agent == nil {
		c.JSON(http.StatusNotFound, gin.H{"error": "Agent 不存在"})
		return
	}
	// 同步在线状态（与 List 一致）
	if h.presence.IsOnline("agent", agent.ID) {
		agent.Status = model.AgentStatusOnline
	} else {
		agent.Status = model.AgentStatusOffline
	}
	c.JSON(http.StatusOK, agent)
}

func (h *AgentHandler) Delete(c *gin.Context) {
	id := c.Param("id")
	if err := h.agentRepo.Delete(id); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "删除失败"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "删除成功"})
}
