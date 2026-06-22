package message

import (
	"encoding/json"
	"log"
	"sync/atomic"

	"github.com/wanling/server/internal/hub"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// Processor 处理 WebSocket 消息的持久化和转发
type Processor struct {
	hub       *hub.Hub
	convRepo  *repository.ConversationRepo
	msgRepo   *repository.MessageRepo
	agentRepo *repository.AgentRepo
	seq       int64
}

// NewProcessor 创建新的消息处理器
func NewProcessor(h *hub.Hub, convRepo *repository.ConversationRepo, msgRepo *repository.MessageRepo, agentRepo *repository.AgentRepo) *Processor {
	return &Processor{hub: h, convRepo: convRepo, msgRepo: msgRepo, agentRepo: agentRepo}
}

// HandleIncoming 处理收到的 WebSocket 消息
func (p *Processor) HandleIncoming(senderType, senderID string, wsMsg *model.WSMessage) {
	// TYPING_START：agent → user 直接透传，不持久化（typing 是瞬态状态）。
	// payload 里 user_id 是目标 user；agent_id 用于 APP 端 typingProvider 路由。
	if wsMsg.T == "TYPING_START" {
		var payload struct {
			UserID string `json:"user_id"`
		}
		if err := json.Unmarshal(wsMsg.D, &payload); err != nil {
			log.Println("解析 TYPING_START 失败:", err)
			return
		}
		if payload.UserID == "" || senderType != "agent" {
			return
		}
		p.hub.SendToUser(payload.UserID, wsMsg)
		return
	}

	if wsMsg.T != model.EventMessageCreate {
		return
	}

	// payload 同时包含两端 ID（user 发给 agent 带 agent_id，agent 回复带 user_id），
	// content 是消息正文。一次解析全字段，避免 user/agent 分支重复 Unmarshal。
	var payload struct {
		AgentID string          `json:"agent_id"`
		UserID  string          `json:"user_id"`
		Content json.RawMessage `json:"content"`
	}
	if err := json.Unmarshal(wsMsg.D, &payload); err != nil {
		log.Println("解析消息失败:", err)
		return
	}

	// 根据 sender 推导对端与会话双方 ID：
	// - user 发送：自己是 user，agent 来自 payload.agent_id；
	// - agent 发送：自己是 agent，user 来自 payload.user_id。
	var userID, agentID string
	if senderType == "user" {
		userID = senderID
		agentID = payload.AgentID
	} else {
		userID = payload.UserID
		agentID = senderID
	}

	conv, err := p.convRepo.FindOrCreate(userID, agentID)
	if err != nil {
		log.Println("创建会话失败:", err)
		return
	}
	convID := conv.ID

	// seq 是 dispatch 序号，与持久化无关，放在事务外即可（避免事务内提序列号在回滚时漏号）。
	newSeq := atomic.AddInt64(&p.seq, 1)

	// 事务边界：消息写入 + last_message_content 缓存更新必须原子化。
	// 否则 crash 时会出现"消息已写但缓存未更新"的不一致，IM 列表会显示旧 last_message。
	tx, err := p.convRepo.BeginTx()
	if err != nil {
		log.Println("开启事务失败:", err)
		return
	}
	defer tx.Rollback() // commit 后调用为 no-op（database/sql 保证）

	msg, err := p.msgRepo.CreateTx(tx, convID, senderType, senderID, payload.Content)
	if err != nil {
		log.Println("保存消息失败:", err)
		return
	}
	if err := p.convRepo.UpdateLastMessageTx(tx, convID, payload.Content); err != nil {
		log.Println("更新会话缓存失败:", err)
		return
	}
	// agent → user 方向累加未读（user 给 agent 的消息不算 user 自己的未读）
	if senderType == "agent" {
		if err := p.convRepo.IncrUnreadTx(tx, convID); err != nil {
			log.Println("未读计数失败:", err)
			return
		}
	}
	if err := tx.Commit(); err != nil {
		log.Println("提交事务失败:", err)
		return
	}

	dispatch := model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageCreate,
		S:  newSeq,
	}
	dispatchData, _ := json.Marshal(map[string]interface{}{
		"id":              msg.ID,
		"conversation_id": convID,
		"sender_type":     senderType,
		"sender_id":       senderID,
		"content":         msg.Content,
		"created_at":      msg.CreatedAt,
	})
	dispatch.D = dispatchData

	// 投递：user 发送时同时回显给自己（多端同步），agent 发送时只投递给 user。
	if senderType == "user" {
		p.hub.SendToAgent(agentID, &dispatch)
		p.hub.SendToUser(userID, &dispatch)
	} else {
		p.hub.SendToUser(userID, &dispatch)
	}
}
