package message

import (
	"encoding/json"
	"log"
	"sync/atomic"

	"github.com/wanling/server/internal/hub"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// Processor 处理 WebSocket 消息的持久化和转发。
//
// participants 模型重构后,事务内 3 个写操作:
//  1. msgRepo.CreateTx    — INSERT messages
//  2. deliveryRepo.CreateBatchTx — 给非 sender 全员插 message_deliveries(read_at=NULL)
//  3. participantRepo.IncrUnreadTx — 给非 sender 全员 unread_count+1
//
// IM 列表的 last_message_content / last_message_at 不再缓存(conversations 表字段已删,
// 见 migration 017),由 ConversationRepo.ListForUser 子查询实时算。
//
// 原子提交保证「消息可见 ⟺ 未读计数对齐 ⟺ 投递状态对齐」。
// 设计见 docs/superpowers/specs/2026-07-02-participants-model-refactor-design.md §3.3。
type Processor struct {
	hub             *hub.Hub
	convRepo        *repository.ConversationRepo
	msgRepo         *repository.MessageRepo
	agentRepo       *repository.AgentRepo
	fileRepo        *repository.FileRepo
	participantRepo *repository.ParticipantRepo
	deliveryRepo    *repository.DeliveryRepo
	seq             int64
}

// NewProcessor 创建新的消息处理器。
// 调用方(main.go)负责提前实例化所有 repo 并注入。
func NewProcessor(
	h *hub.Hub,
	convRepo *repository.ConversationRepo,
	msgRepo *repository.MessageRepo,
	agentRepo *repository.AgentRepo,
	fileRepo *repository.FileRepo,
	participantRepo *repository.ParticipantRepo,
	deliveryRepo *repository.DeliveryRepo,
) *Processor {
	return &Processor{
		hub:             h,
		convRepo:        convRepo,
		msgRepo:         msgRepo,
		agentRepo:       agentRepo,
		fileRepo:        fileRepo,
		participantRepo: participantRepo,
		deliveryRepo:    deliveryRepo,
	}
}

// HandleIncoming 处理收到的 WebSocket 消息。
//
// 协议:wsMsg.D 含 {agent_id?, user_id?, content}。user 发给 agent 带 agent_id;
// agent 回复带 user_id。一次解析全字段,避免分支重复 Unmarshal。
//
// 在 participants 模型下:用 sender + payload 推导 dm 的对端,FindOrCreateDM
// 拿/建会话(自动按 member_type 选 dm_user_user / dm_user_agent)。后续 N 方
// 群聊由 handler 显式 POST /api/conversations 创建,processor 不负责建群。
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

	// payload 同时包含两端 ID + content + 可选 conversation_id。
	// conversation_id 路由（新协议）：APP 端用，先建会话再发消息，server 直发不建。
	// agent_id / user_id 路由（旧协议）：hermes adapter 用，按对端 ID FindOrCreateDM。
	var payload struct {
		AgentID        string          `json:"agent_id"`
		UserID         string          `json:"user_id"`
		ConversationID string          `json:"conversation_id"`
		Content        json.RawMessage `json:"content"`
	}
	if err := json.Unmarshal(wsMsg.D, &payload); err != nil {
		log.Println("解析消息失败:", err)
		return
	}

	var convID string
	if payload.ConversationID != "" {
		// 新路径：直发到指定会话。校验 sender 是 participant（fail fast 防伪造 conv_id）。
		convID = payload.ConversationID
		ok, err := p.participantRepo.Exists(convID, senderID, senderType)
		if err != nil {
			log.Printf("校验 sender participant 失败 conv=%s: %v", convID, err)
			return
		}
		if !ok {
			log.Printf("sender 不在会话 participants 中 conv=%s sender=%s/%s",
				convID, senderType, senderID)
			return
		}
	} else {
		// 旧路径：按对端 ID 路由 + FindOrCreateDM。
		// 根据 sender 推导对端与会话双方 ID + 类型。
		// user 发送：sender=(userID, user)，对端 agent；agent 发送：sender=(agentID, agent)，对端 user。
		var otherID, otherType string
		if senderType == "user" {
			otherID = payload.AgentID
			otherType = "agent"
		} else {
			otherID = payload.UserID
			otherType = "user"
		}
		if otherID == "" {
			log.Printf("消息缺对端 ID: sender=%s/%s", senderType, senderID)
			return
		}

		// dm type 按对端 member_type 自动选:
		//   user ↔ agent → dm_user_agent
		//   user ↔ user  → dm_user_user
		//   agent ↔ agent → 不支持(本期 hermes 不发 agent↔agent 消息,且 agents.owner_id 外键
		//                   到 users,业务上 agent 不应作为 dm_user_user 的发起方)
		dmType := "dm_user_agent"
		if senderType == "user" && otherType == "user" {
			dmType = "dm_user_user"
		}

		conv, err := p.convRepo.FindOrCreateDM(dmType, repository.DMMembers{
			Initiator: repository.ParticipantInput{
				MemberID:   senderID,
				MemberType: senderType,
				Role:       "owner",
			},
			Other: repository.ParticipantInput{
				MemberID:   otherID,
				MemberType: otherType,
				Role:       "member",
			},
		})
		if err != nil {
			log.Printf("创建会话失败 (%s): %v", dmType, err)
			return
		}
		convID = conv.ID
	}

	// seq 是 dispatch 序号，与持久化无关，放在事务外即可（避免事务内提序列号在回滚时漏号）。
	newSeq := atomic.AddInt64(&p.seq, 1)

	// 事务边界：3 个写操作(message + deliveries + participants)原子提交。
	// 否则 crash / 并发会出现"消息可见但未读计数错"或"投递状态错"等不一致。
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

	// 1. 创建 message(已无 is_read 字段,per-recipient 状态走 deliveries 表)
	msg, err := p.msgRepo.CreateTx(tx, convID, senderType, senderID, enhancedContent)
	if err != nil {
		log.Printf("保存消息失败 conv=%s sender=%s/%s: %v", convID, senderType, senderID, err)
		return
	}

	// 2. 同事务查 participants(避免并发邀请 / 退群脏读)
	participants, err := p.participantRepo.ListByConversationTx(tx, convID)
	if err != nil {
		log.Printf("查 participants 失败 conv=%s: %v", convID, err)
		return
	}

	// 3. 过滤 sender,得到 recipients(本消息的接收方)
	recipients := make([]model.ConversationParticipant, 0, len(participants))
	senderRole := "member" // fallback:sender 不在 participants 时(理论不应发生)
	for _, pt := range participants {
		if pt.MemberID == senderID && pt.MemberType == senderType {
			senderRole = pt.Role
			continue
		}
		recipients = append(recipients, pt)
	}

	// 4. 批量插 deliveries(每 recipient 一行,read_at=NULL)
	if err := p.deliveryRepo.CreateBatchTx(tx, msg.ID, recipients); err != nil {
		log.Printf("插 deliveries 失败 msg=%s: %v", msg.ID, err)
		return
	}

	// 5. 全员 unread_count+1(除 sender)
	//    IncrUnreadTx 是无条件给非 sender 全员 +1,与「是否在看会话」无关;
	//    client 端 chat_page.dart 在底部时收到消息立即 _markRead() 归零,
	//    不在底部时本地 +1(显示浮标)。这是 N 方模型的标准口径。
	if err := p.participantRepo.IncrUnreadTx(tx, convID, senderID, senderType); err != nil {
		log.Printf("未读计数失败 conv=%s: %v", convID, err)
		return
	}

	if err := tx.Commit(); err != nil {
		log.Printf("提交事务失败 conv=%s: %v", convID, err)
		return
	}

	// 6. dispatch(commit 之后):遍历 recipients 按 member_type 路由
	//    必须在 commit 之后才 dispatch,否则 dispatch 了的消息可能因 rollback 没真存。
	//    payload 加 sender_role 字段(spec §5.2):client 不破坏(忽略未知字段),新版 APP
	//    可用于权限按钮显隐(owner/admin/member 显示不同的会话操作)。
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
		"sender_role":     senderRole,
		"content":         msg.Content,
		"created_at":      msg.CreatedAt,
	})
	dispatch.D = dispatchData

	for _, r := range recipients {
		if r.MemberType == "user" {
			p.hub.SendToUser(r.MemberID, &dispatch)
		} else {
			p.hub.SendToAgent(r.MemberID, &dispatch)
		}
	}
}

// enhanceImageContent 对 image 类型消息的 content 补 width/height。
//
// 主路径（新消息零跳动）：前端发图时只带 file_id，server 在持久化前从 files 表
// 查到原图宽高，补进 content.data。补完后存库 + dispatch 两处都带上宽高，
// 前端加载前即知比例，按真实尺寸渲染无跳动。
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
