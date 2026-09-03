package handler

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// AgentSubKeyHandler 处理 agent 子密钥管理请求(列表/吊销),
// 协议详见 docs/ai-handbook/agent-subkeys.md。
type AgentSubKeyHandler struct {
	agentRepo  *repository.AgentRepo
	subKeyRepo *repository.AgentSubKeyRepo
}

func NewAgentSubKeyHandler(agentRepo *repository.AgentRepo, subKeyRepo *repository.AgentSubKeyRepo) *AgentSubKeyHandler {
	return &AgentSubKeyHandler{agentRepo: agentRepo, subKeyRepo: subKeyRepo}
}

// requireOwnedAgent IDOR 防护(审计 H1/M1):agent 存在(404) + owner 归属(403)。
// owner 是数据边界:HTTP 中间件已把 admin 归一为 user,admin 也不例外。
// 返回 false 表示响应已写,调用方直接 return。
func (h *AgentSubKeyHandler) requireOwnedAgent(c *gin.Context, id string) (*model.Agent, bool) {
	userID := c.GetString("userID")                         // 不用 MustGet(审计 C2)
	ag, err := h.agentRepo.GetByID(c.Request.Context(), id) // ctx 透传(审计 H4)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "服务器错误")
		return nil, false
	}
	if ag == nil {
		Err(c, http.StatusNotFound, "not_found", "Agent 不存在")
		return nil, false
	}
	if ag.OwnerID != userID {
		Err(c, http.StatusForbidden, "forbidden", "无权操作该 Agent")
		return nil, false
	}
	return ag, true
}

// List GET /api/agents/:id/subkeys:列出 agent 全部子密钥(含已吊销,created_at DESC)。
// 响应绝不包含 secret_key(model json:"-" 已保证,handler 响应结构亦不引入该字段)。
func (h *AgentSubKeyHandler) List(c *gin.Context) {
	ag, ok := h.requireOwnedAgent(c, c.Param("id"))
	if !ok {
		return
	}
	keys, err := h.subKeyRepo.ListByAgent(c.Request.Context(), ag.ID)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "查询失败")
		return
	}
	if keys == nil { // 空列表返 [] 而非 null,对齐 agent List 惯例
		keys = []model.AgentSubKey{}
	}
	Ok(c, gin.H{"subkeys": keys})
}

// Revoke DELETE /api/agents/:id/subkeys/:keyId:吊销单个子密钥,幂等 200。
// 404 仅当 agent 不存在;keyId 不存在(含不属于该 agent)也返 200——幂等吊销语义。
// 归属限定经 ListByAgent 白名单校验:即使请求方是 owner,也不得借自己的 agent
// 越权吊销他人 agent 名下的子密钥(keyId 跨 agent 不可枚举操作)。
func (h *AgentSubKeyHandler) Revoke(c *gin.Context) {
	ag, ok := h.requireOwnedAgent(c, c.Param("id"))
	if !ok {
		return
	}
	keyID := c.Param("keyId")

	// repo 无按 id 单查方法,用 ListByAgent 圈定该 agent 名下密钥做白名单匹配;
	// 不在名下视为「不存在」,按幂等语义直接 200。
	keys, err := h.subKeyRepo.ListByAgent(c.Request.Context(), ag.ID)
	if err != nil {
		ErrMsg(c, http.StatusInternalServerError, "查询失败")
		return
	}
	owned := false
	for _, k := range keys {
		if k.ID == keyID {
			owned = true
			break
		}
	}
	if !owned {
		Ok(c, gin.H{"message": "吊销成功"})
		return
	}
	if err := h.subKeyRepo.Revoke(c.Request.Context(), keyID); err != nil {
		ErrMsg(c, http.StatusInternalServerError, "吊销失败")
		return
	}
	Ok(c, gin.H{"message": "吊销成功"})
}
