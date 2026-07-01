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
	fileRepo  *repository.FileRepo
	seq       int64
}

// NewProcessor 创建新的消息处理器
func NewProcessor(h *hub.Hub, convRepo *repository.ConversationRepo, msgRepo *repository.MessageRepo, agentRepo *repository.AgentRepo, fileRepo *repository.FileRepo) *Processor {
	return &Processor{hub: h, convRepo: convRepo, msgRepo: msgRepo, agentRepo: agentRepo, fileRepo: fileRepo}
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

	// image 消息增强：补 width/height 到 content.data（前端加载前可知比例，做等比缩放）。
	// 宽高数据来源 files 表（上传时 imaging 包已生成）。幂等：已有宽高则跳过，避免每条查询。
	// fail-soft：查不到 / 解析失败都不阻断消息发送，保留原 content（前端走探测兜底）。
	enhancedContent := p.enhanceImageContent(payload.Content)

	msg, err := p.msgRepo.CreateTx(tx, convID, senderType, senderID, enhancedContent)
	if err != nil {
		log.Println("保存消息失败:", err)
		return
	}
	if err := p.convRepo.UpdateLastMessageTx(tx, convID, enhancedContent); err != nil {
		log.Println("更新会话缓存失败:", err)
		return
	}
	// agent → user 方向累加未读（user 给 agent 的消息不算 user 自己的未读）。
	// 所有 agent 消息一律计未读:client 端 chat_page.dart 在底部时收到新消息会立即
	// _markRead() 同步归零,不在底部时本地 +1(显示浮标)。server 端不再用
	// IsUserViewingConv 守卫——「在会话」≠「看到了消息」(用户可能滚到顶部看历史)。
	// TODO(participants-refactor): participants 模型下,unread_count 应按每个 participant
	// 各自维护,client 端「看到就 ack」语义对齐主流 IM 标准模型。
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
		"is_read":         msg.IsRead,
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

// enhanceImageContent 对 image 类型消息的 content 补 width/height。
//
// 主路径（新消息零跳动）：前端发图时只带 file_id，server 在持久化前从 files 表
// 查到原图宽高，补进 content.data。补完后存库 + last_message_content 缓存 + dispatch
// 三处都带上宽高，前端加载前即知比例，按真实尺寸渲染无跳动。
//
// 幂等：data 已有 width/height（非 0）则直接返回原 content，避免每条消息多一次 DB 查询。
// fail-soft：非 image 消息 / file_id 缺失 / files 表查不到 / 宽高为 NULL / json 解析失败，
// 均静默返回原 content 不阻断发送（前端走 ImageProvider.resolve 探测兜底）。
func (p *Processor) enhanceImageContent(raw json.RawMessage) json.RawMessage {
	// 解析 content 结构，判断是否 image 类型且缺宽高
	var content struct {
		MsgType string `json:"msg_type"`
		Data    struct {
			FileID string `json:"file_id"`
			Width  *int   `json:"width"`
			Height *int   `json:"height"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &content); err != nil {
		return raw // 解析失败保留原样
	}
	if content.MsgType != "image" {
		return raw // 非 image 不处理
	}
	// 已有有效宽高则幂等跳过（width/height 非空且非 0）
	if content.Data.Width != nil && *content.Data.Width > 0 &&
		content.Data.Height != nil && *content.Data.Height > 0 {
		return raw
	}
	if content.Data.FileID == "" {
		return raw // 无 file_id 无法查询
	}

	// 查 files 表拿权威宽高（上传时 imaging 包已生成）
	f, err := p.fileRepo.GetByID(content.Data.FileID)
	if err != nil || f == nil || f.Width == nil || f.Height == nil {
		return raw // 查不到或无宽高，保留原样
	}

	// 重新构造 content，补上 width/height（其余字段原样保留）
	var generic map[string]interface{}
	if err := json.Unmarshal(raw, &generic); err != nil {
		return raw
	}
	if data, ok := generic["data"].(map[string]interface{}); ok {
		data["width"] = *f.Width
		data["height"] = *f.Height
	} else {
		return raw // data 结构异常，不动
	}
	enhanced, err := json.Marshal(generic)
	if err != nil {
		return raw
	}
	return enhanced
}
