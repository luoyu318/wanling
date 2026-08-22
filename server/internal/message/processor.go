package message

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/wanling/server/internal/agent"
	"github.com/wanling/server/internal/hub"
	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/model"
	"github.com/wanling/server/internal/repository"
)

// ErrNotParticipant 表示 sender 不是该会话的 participant(权限错误)。
// 供 HTTP /api/messages 路径区分 403(权限) vs 500(内部错误)。
var ErrNotParticipant = errors.New("not a participant")

// ExtractParentRoot 从消息 content JSON 提取 parent_msg_id / root_msg_id 元字段。
//
// plugin 两条发送路径(WS sendTypedMessage / HTTP sendCardMessage)都把这两个字段
// 放在 content 内部;server 在写 DB 前提取出来,落到独立列,并从 content 删除避免残留。
//
// 返回:
//   - parent/root 指针(content 内无对应字段时为 nil)
//   - cleanedContent:删除 parent_msg_id/root_msg_id 后的 content;原样或 marshal 失败时返回原 content
//
// 调用方:HandleIncoming(WS) / SendAsAgent(HTTP) — 两条路径对称使用,避免行为漂移。
func ExtractParentRoot(content []byte) (parent, root *string, cleaned []byte) {
	var fields struct {
		ParentMsgID *string `json:"parent_msg_id"`
		RootMsgID   *string `json:"root_msg_id"`
	}
	_ = json.Unmarshal(content, &fields)
	if fields.ParentMsgID == nil && fields.RootMsgID == nil {
		return nil, nil, content
	}
	cleanedMap := make(map[string]json.RawMessage)
	if err := json.Unmarshal(content, &cleanedMap); err != nil {
		return fields.ParentMsgID, fields.RootMsgID, content
	}
	delete(cleanedMap, "parent_msg_id")
	delete(cleanedMap, "root_msg_id")
	if rebuilt, err := json.Marshal(cleanedMap); err == nil {
		return fields.ParentMsgID, fields.RootMsgID, rebuilt
	}
	return fields.ParentMsgID, fields.RootMsgID, content
}

// stripStreamID 从 content.data 剥离 _stream_id 字段(落库前调用)。
//
// _stream_id 是流式占位关联字段(plugin 流式输出时下发占位,终态消息带同 _stream_id
// 让 APP 同位置替换占位为终态)。属于瞬态控制信息,不应污染历史库。
//
// 与 ExtractParentRoot 对称:都是「落库前从 content 提取控制字段」的 helper,
// 区别是 _stream_id 嵌在 content.data 内层(非 content 顶层)。
//
// 返回剥离后的 content + 提取到的 streamID(无 _stream_id / 类型不匹配 / 非 JSON object 时返原 content + 空串)。
// 调用方:persistAndDispatchOnce(enhanceContentFromFile 之后、CreateTx 之前)。
func stripStreamID(content json.RawMessage) (json.RawMessage, string) {
	var full map[string]json.RawMessage
	if err := json.Unmarshal(content, &full); err != nil || full == nil {
		return content, ""
	}
	rawData, ok := full["data"]
	if !ok {
		return content, ""
	}
	var data map[string]json.RawMessage
	if err := json.Unmarshal(rawData, &data); err != nil || data == nil {
		return content, ""
	}
	rawSID, ok := data["_stream_id"]
	if !ok {
		return content, ""
	}
	var sid string
	if err := json.Unmarshal(rawSID, &sid); err != nil {
		// 类型不匹配(数字/对象等)→ 不剥离,返回原 content,避免误删业务字段。
		return content, ""
	}
	delete(data, "_stream_id")
	full["data"], _ = json.Marshal(data)
	rebuilt, err := json.Marshal(full)
	if err != nil {
		return content, sid
	}
	return rebuilt, sid
}

// injectStreamID 把 _stream_id 重新注入 content.data(广播 payload 用)。
//
// 与 stripStreamID 互逆:落库前剥离的 _stream_id,广播时注入回去,让 APP 收到的
// 终态消息 payload 仍带 _stream_id,据此同位置替换流式占位。
//
// 无 data 字段 / 解析失败时原样返回(理论不会发生:strip 成功提取到 streamID 才调本方法)。
func injectStreamID(content json.RawMessage, streamID string) json.RawMessage {
	var full map[string]json.RawMessage
	if err := json.Unmarshal(content, &full); err != nil || full == nil {
		return content
	}
	rawData, ok := full["data"]
	if !ok {
		return content
	}
	var data map[string]json.RawMessage
	if err := json.Unmarshal(rawData, &data); err != nil || data == nil {
		return content
	}
	data["_stream_id"], _ = json.Marshal(streamID)
	full["data"], _ = json.Marshal(data)
	rebuilt, err := json.Marshal(full)
	if err != nil {
		return content
	}
	return rebuilt
}

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
type Processor struct {
	hub             *hub.Hub
	convRepo        *repository.ConversationRepo
	msgRepo         *repository.MessageRepo
	agentRepo       *repository.AgentRepo
	userRepo        *repository.UserRepo
	fileRepo        *repository.FileRepo
	participantRepo *repository.ParticipantRepo
	deliveryRepo    *repository.DeliveryRepo
	// agentRegistry 缓存 plugin 上报的可选模型清单(AGENT_MODELS 事件写入,
	// REST /api/agents/:id/models 读取)。server 重启清空,plugin 重连后重新上报。
	agentRegistry *agent.AgentRegistry
	// slashCatalogRegistry 缓存 plugin 上报的命令清单(AGENT_SLASH_CATALOG 事件写入,
	// REST /api/agents/:id/slash-catalog 读取)。server 重启清空,plugin 重连后重报。
	slashCatalogRegistry *agent.SlashCatalogRegistry
	// modeRegistry 缓存 plugin 上报的模式清单(AGENT_MODES 事件写入,
	// REST /api/agents/:id/modes 读取)。能力上报管线第四成员。
	modeRegistry *agent.ModeRegistry
	// presetRegistry 缓存 plugin 上报的预设清单(AGENT_PRESETS 事件写入,
	// REST /api/agents/:id/presets 读取)。能力上报管线第五成员。
	presetRegistry *agent.PresetRegistry
	// capabilityRegistry 缓存 plugin 上报的 RPC 方法清单(PLUGIN_CAPABILITIES 事件写入,
	// RPC 路由层 + REST 读取)。server 重启清空,plugin 重连后重报。
	capabilityRegistry *agent.CapabilityRegistry
	// seq 字段已删除 — 统一走 p.hub.NextSeq(),避免与 hub 双计数器各自从 1 起步重叠
}

// NewProcessor 创建新的消息处理器。
// 调用方(main.go)负责提前实例化所有 repo 并注入。
// 各 registry 放在最后,避免破坏现有调用方的位置参数。
func NewProcessor(
	h *hub.Hub,
	convRepo *repository.ConversationRepo,
	msgRepo *repository.MessageRepo,
	agentRepo *repository.AgentRepo,
	userRepo *repository.UserRepo,
	fileRepo *repository.FileRepo,
	participantRepo *repository.ParticipantRepo,
	deliveryRepo *repository.DeliveryRepo,
	agentRegistry *agent.AgentRegistry,
	slashCatalogRegistry *agent.SlashCatalogRegistry,
	capabilityRegistry *agent.CapabilityRegistry,
	modeRegistry *agent.ModeRegistry,
	presetRegistry *agent.PresetRegistry,
) *Processor {
	return &Processor{
		hub:                  h,
		convRepo:             convRepo,
		msgRepo:              msgRepo,
		agentRepo:            agentRepo,
		userRepo:             userRepo,
		fileRepo:             fileRepo,
		participantRepo:      participantRepo,
		deliveryRepo:         deliveryRepo,
		agentRegistry:        agentRegistry,
		slashCatalogRegistry: slashCatalogRegistry,
		modeRegistry:         modeRegistry,
		presetRegistry:       presetRegistry,
		capabilityRegistry:   capabilityRegistry,
	}
}

// senderDisplayName 查 sender 昵称:
//   - agent → agentRepo.GetByID(...).Name
//   - user   → userRepo.GetByID(...).Nickname || Username
//
// 查询失败返空串(client 端用 fallback 占位),不阻塞 dispatch。
func (p *Processor) senderDisplayName(ctx context.Context, senderID, senderType string) string {
	if senderType == "agent" {
		a, err := p.agentRepo.GetByID(ctx, senderID)
		if err != nil || a == nil {
			return ""
		}
		return a.Name
	}
	u, err := p.userRepo.GetByID(ctx, senderID)
	if err != nil || u == nil {
		return ""
	}
	if u.Nickname != nil && *u.Nickname != "" {
		return *u.Nickname
	}
	return u.Username
}

// senderAvatarURL 查 sender 头像 URL,填到 dispatch payload.sender_avatar_url。
//
// bg-service 收到 MESSAGE_CREATE 时直接读此字段加载通知大头像,
// 不再依赖 UI 经 IPC syncAgentAvatar 同步(后者首次接收消息 / conv 列表未 load 时拿不到,
// 导致 user-user 场景通知头像是色块)。
//
// 查询失败返空串,client 端走首字母色块兜底。
func (p *Processor) senderAvatarURL(ctx context.Context, senderID, senderType string) string {
	if senderType == "agent" {
		a, err := p.agentRepo.GetByID(ctx, senderID)
		if err != nil || a == nil {
			return ""
		}
		return a.AvatarURL
	}
	u, err := p.userRepo.GetByID(ctx, senderID)
	if err != nil || u == nil {
		return ""
	}
	return u.AvatarURL
}

// conversationMeta 查会话 type / title,填到 dispatch payload。
//
// bg-service 据此切换通知格式:
//   - 群聊(group_user/group_mixed)→ title=群名,body=「${sender}：${内容}」
//   - 单聊(dm_user_user/dm_user_agent)→ title=sender 名,body=内容
//
// 查询失败返两个空串,bg-service 端按单聊格式 fallback,不阻塞 dispatch。
// 事务外查询(commit 之后),会话刚改 type/title 极端 race 下可能拿旧值,
// 影响仅限通知样式,不影响消息正确性。
func (p *Processor) conversationMeta(ctx context.Context, convID string) (convType, convTitle string) {
	c, err := p.convRepo.GetByID(ctx, convID)
	if err != nil || c == nil {
		return "", ""
	}
	return c.Type, c.Title
}

// HandleIncoming 处理收到的 WebSocket 消息。
//
// ctx 为 WS 连接的 per-conn ctx(由 ws_handler 从 r.Context 派生,client 断开自动 cancel)。
// 后续所有 repo 调用(查会话 / 写消息 / 查 participants / 查 sender 资料)都消费此 ctx,
// 让 client 断开时进行中的查询中止,不浪费 DB 连接。
//
// 协议:wsMsg.D 必须含 {conversation_id, content}。user_id/agent_id 路由已废弃。
// 会话建立走显式 POST /api/agents/me/conversations 或 agent_handler.Create 兜底,
// processor 不再做 FindOrCreateDM(自动建会话能力移除)。
//
// TYPING_START 走 conversation_id 路径,server 查 participants 转发给该 conv 所有 user。
func (p *Processor) HandleIncoming(ctx context.Context, senderType, senderID string, wsMsg *model.WSMessage) {
	// TYPING_START：agent → 该 conv 所有 user participants 透传,不持久化。
	if wsMsg.T == "TYPING_START" {
		var payload struct {
			ConversationID string `json:"conversation_id"`
		}
		if err := json.Unmarshal(wsMsg.D, &payload); err != nil {
			logpkg.FromCtx(ctx).WarnContext(ctx, "解析 TYPING_START 失败",
				"sender_type", senderType, "sender_id", senderID, "err", err)
			return
		}
		if payload.ConversationID == "" || senderType != "agent" {
			return
		}
		participants, err := p.participantRepo.ListByConversation(ctx, payload.ConversationID)
		if err != nil {
			logpkg.FromCtx(ctx).WarnContext(ctx, "TYPING_START 查 participants 失败",
				"conv_id", payload.ConversationID, "err", err)
			return
		}
		for _, pt := range participants {
			if pt.MemberID == senderID && pt.MemberType == senderType {
				continue
			}
			if pt.MemberType == "user" {
				p.hub.SendToUser(pt.MemberID, wsMsg)
			}
		}
		return
	}

	// SESSION_STATUS：agent → 该 conv 所有 user participants 透传,不持久化。
	// 与 TYPING_START 完全对称:不建消息记录、不增未读。
	// payload 原样透传(含 attempt/message 等可选字段),client 端按 status 渲染会话状态指示。
	if wsMsg.T == "SESSION_STATUS" {
		var payload struct {
			ConversationID string `json:"conversation_id"`
			Status         string `json:"status"`
			Attempt        int    `json:"attempt,omitempty"`
			Message        string `json:"message,omitempty"`
		}
		if err := json.Unmarshal(wsMsg.D, &payload); err != nil {
			logpkg.FromCtx(ctx).WarnContext(ctx, "解析 SESSION_STATUS 失败",
				"sender_type", senderType, "sender_id", senderID, "err", err)
			return
		}
		if payload.ConversationID == "" || senderType != "agent" {
			return
		}
		participants, err := p.participantRepo.ListByConversation(ctx, payload.ConversationID)
		if err != nil {
			logpkg.FromCtx(ctx).WarnContext(ctx, "SESSION_STATUS 查 participants 失败",
				"conv_id", payload.ConversationID, "err", err)
			return
		}
		for _, pt := range participants {
			if pt.MemberID == senderID && pt.MemberType == senderType {
				continue
			}
			if pt.MemberType == "user" {
				p.hub.SendToUser(pt.MemberID, wsMsg)
			}
		}
		return
	}

	// AGENT_MODELS:plugin 上报该 agent 的可选模型清单(APP 更换模型功能)。
	// 仅 agent 角色允许(user 角色无权上报),解析后写 AgentRegistry 内存缓存。
	// 不广播给其他 client(APP 通过 REST 拉取,不走 WS 推送)。
	//
	// 安全守卫(顺序敏感):
	//  1. senderType 必须 == "agent"(防 user 越权刷脏数据)
	//  2. payload.agent_id 必须 == WS 鉴权的 sender_id(防 plugin A 冒充上报 plugin B 的清单)
	//
	// sender_id 来自 JWT WS 鉴权,plugin 无法伪造;payload.agent_id 是 client 自填,
	// 不校验则 plugin A 能覆盖 plugin B 的 registry 条目,诱导 APP 显示伪造清单。
	if wsMsg.T == model.EventAgentModels {
		if senderType != "agent" {
			logpkg.FromCtx(ctx).WarnContext(ctx, "AGENT_MODELS 拒绝非 agent 角色",
				"sender_type", senderType, "sender_id", senderID)
			return
		}
		var payload struct {
			AgentID string            `json:"agent_id"`
			Models  []model.ModelInfo `json:"models"`
		}
		if err := json.Unmarshal(wsMsg.D, &payload); err != nil {
			logpkg.FromCtx(ctx).WarnContext(ctx, "解析 AGENT_MODELS 失败",
				"sender_id", senderID, "err", err)
			return
		}
		// 一致性校验:WS 鉴权的 sender_id 必须与 payload.agent_id 一致,
		// 防 plugin A 冒充上报 plugin B 的模型清单。空串一并拒绝。
		if payload.AgentID == "" || payload.AgentID != senderID {
			logpkg.FromCtx(ctx).WarnContext(ctx, "AGENT_MODELS agent_id 不一致",
				"sender_id", senderID, "payload_agent_id", payload.AgentID)
			return
		}
		p.agentRegistry.Update(payload.AgentID, payload.Models)
		logpkg.FromCtx(ctx).InfoContext(ctx, "AGENT_MODELS 已缓存",
			"agent_id", payload.AgentID, "count", len(payload.Models))
		return
	}

	// AGENT_SLASH_CATALOG:plugin 上报该 agent 的命令清单(APP 斜杠命令功能)。
	// 与 AGENT_MODELS 完全同构:仅 agent 角色允许,payload.agent_id 必须与
	// WS 鉴权的 sender_id 一致(防 plugin A 冒充上报 plugin B 的清单)。
	if wsMsg.T == model.EventAgentSlashCatalog {
		if senderType != "agent" {
			logpkg.FromCtx(ctx).WarnContext(ctx, "AGENT_SLASH_CATALOG 拒绝非 agent 角色",
				"sender_type", senderType, "sender_id", senderID)
			return
		}
		var payload struct {
			AgentID  string                   `json:"agent_id"`
			Commands []model.SlashCommandInfo `json:"commands"`
		}
		if err := json.Unmarshal(wsMsg.D, &payload); err != nil {
			logpkg.FromCtx(ctx).WarnContext(ctx, "解析 AGENT_SLASH_CATALOG 失败",
				"sender_id", senderID, "err", err)
			return
		}
		// 一致性校验:WS 鉴权的 sender_id 必须与 payload.agent_id 一致,
		// 防 plugin A 冒充上报 plugin B 的命令清单。空串一并拒绝。
		if payload.AgentID == "" || payload.AgentID != senderID {
			logpkg.FromCtx(ctx).WarnContext(ctx, "AGENT_SLASH_CATALOG agent_id 不一致",
				"sender_id", senderID, "payload_agent_id", payload.AgentID)
			return
		}
		p.slashCatalogRegistry.Update(payload.AgentID, payload.Commands)
		logpkg.FromCtx(ctx).InfoContext(ctx, "AGENT_SLASH_CATALOG 已缓存",
			"agent_id", payload.AgentID, "count", len(payload.Commands))
		return
	}

	// AGENT_MODES:plugin 上报该 agent 的模式清单(能力上报管线第四成员)。
	// 与 AGENT_MODELS / AGENT_SLASH_CATALOG 完全同构:仅 agent 角色允许,
	// payload.agent_id 必须与 WS 鉴权的 sender_id 一致(防 plugin A 冒充上报
	// plugin B 的清单)。APP 渲染模式色条时按清单取 label/style,不再硬编码。
	if wsMsg.T == model.EventAgentModes {
		if senderType != "agent" {
			logpkg.FromCtx(ctx).WarnContext(ctx, "AGENT_MODES 拒绝非 agent 角色",
				"sender_type", senderType, "sender_id", senderID)
			return
		}
		var payload struct {
			AgentID string               `json:"agent_id"`
			Modes   []model.AgentModeInfo `json:"modes"`
		}
		if err := json.Unmarshal(wsMsg.D, &payload); err != nil {
			logpkg.FromCtx(ctx).WarnContext(ctx, "解析 AGENT_MODES 失败",
				"sender_id", senderID, "err", err)
			return
		}
		if payload.AgentID == "" || payload.AgentID != senderID {
			logpkg.FromCtx(ctx).WarnContext(ctx, "AGENT_MODES agent_id 不一致",
				"sender_id", senderID, "payload_agent_id", payload.AgentID)
			return
		}
		p.modeRegistry.Update(payload.AgentID, payload.Modes)
		logpkg.FromCtx(ctx).InfoContext(ctx, "AGENT_MODES 已缓存",
			"agent_id", payload.AgentID, "count", len(payload.Modes))
		return
	}

	// AGENT_PRESETS:plugin 上报该 agent 的预设清单(能力上报管线第五成员)。
	// 同构守卫。无预设概念的 plugin(hermes 等)不上报,APP 隐藏选择步骤。
	if wsMsg.T == model.EventAgentPresets {
		if senderType != "agent" {
			logpkg.FromCtx(ctx).WarnContext(ctx, "AGENT_PRESETS 拒绝非 agent 角色",
				"sender_type", senderType, "sender_id", senderID)
			return
		}
		var payload struct {
			AgentID string                  `json:"agent_id"`
			Presets []model.AgentPresetInfo `json:"presets"`
		}
		if err := json.Unmarshal(wsMsg.D, &payload); err != nil {
			logpkg.FromCtx(ctx).WarnContext(ctx, "解析 AGENT_PRESETS 失败",
				"sender_id", senderID, "err", err)
			return
		}
		if payload.AgentID == "" || payload.AgentID != senderID {
			logpkg.FromCtx(ctx).WarnContext(ctx, "AGENT_PRESETS agent_id 不一致",
				"sender_id", senderID, "payload_agent_id", payload.AgentID)
			return
		}
		p.presetRegistry.Update(payload.AgentID, payload.Presets)
		logpkg.FromCtx(ctx).InfoContext(ctx, "AGENT_PRESETS 已缓存",
			"agent_id", payload.AgentID, "count", len(payload.Presets))
		return
	}

	// PLUGIN_CAPABILITIES:plugin 上报该 agent 支持的 RPC 方法清单。
	// 与 AGENT_MODELS / AGENT_SLASH_CATALOG 完全同构:仅 agent 角色允许,
	// payload.agent_id 必须与 WS 鉴权的 sender_id 一致(防 plugin A 冒充上报 plugin B 的清单)。
	// 空 methods 合法(plugin 临时无 RPC 方法),registry 缓存空切片 + updatedAt 标记已上报。
	if wsMsg.T == model.EventPluginCapabilities {
		if senderType != "agent" {
			logpkg.FromCtx(ctx).WarnContext(ctx, "PLUGIN_CAPABILITIES 拒绝非 agent 角色",
				"sender_type", senderType, "sender_id", senderID)
			return
		}
		var payload struct {
			AgentID string            `json:"agent_id"`
			Methods []model.RpcMethod `json:"methods"`
		}
		if err := json.Unmarshal(wsMsg.D, &payload); err != nil {
			logpkg.FromCtx(ctx).WarnContext(ctx, "解析 PLUGIN_CAPABILITIES 失败",
				"sender_id", senderID, "err", err)
			return
		}
		// 一致性校验:WS 鉴权的 sender_id 必须与 payload.agent_id 一致,
		// 防 plugin A 冒充上报 plugin B 的 RPC 方法清单。空串一并拒绝。
		if payload.AgentID == "" || payload.AgentID != senderID {
			logpkg.FromCtx(ctx).WarnContext(ctx, "PLUGIN_CAPABILITIES agent_id 不一致",
				"sender_id", senderID, "payload_agent_id", payload.AgentID)
			return
		}
		p.capabilityRegistry.Update(payload.AgentID, payload.Methods)
		logpkg.FromCtx(ctx).InfoContext(ctx, "PLUGIN_CAPABILITIES 已缓存",
			"agent_id", payload.AgentID, "count", len(payload.Methods))
		return
	}

	if wsMsg.T != model.EventMessageCreate {
		return
	}

	// payload 必须含 conversation_id(新协议唯一路由键)。
	// 旧协议(user_id/agent_id 路由)已废弃,server 不再 FindOrCreateDM 兜底。
	var payload struct {
		ConversationID string          `json:"conversation_id"`
		Content        json.RawMessage `json:"content"`
	}
	if err := json.Unmarshal(wsMsg.D, &payload); err != nil {
		logpkg.FromCtx(ctx).WarnContext(ctx, "解析消息失败",
			"sender_type", senderType, "sender_id", senderID, "err", err)
		return
	}
	if payload.ConversationID == "" {
		logpkg.FromCtx(ctx).WarnContext(ctx, "消息缺 conversation_id",
			"sender_type", senderType, "sender_id", senderID)
		return
	}

	// 从 content 提取 parent_msg_id / root_msg_id(plugin WS 路径透传,子 agent 事件用)。
	// 提取后从 content 删除,避免残留在 content JSON 里(有独立 DB 列)。
	// 仅 agent 允许透传 parent/root(user 路径强制 nil,与 SendHandler 对齐)。
	// 否则 user 经 WS 塞 parent_msg_id 即可发「幽灵消息」:不进主列表、不给对方未读。
	var parentMsgID, rootMsgID *string
	if senderType == "agent" {
		parentMsgID, rootMsgID, payload.Content = ExtractParentRoot(payload.Content)
	}

	// convID 已确定,复用 PersistAndDispatch(HTTP send_handler 也走同一方法)。
	// participant 校验在 PersistAndDispatch 内,非法 sender 在此处被挡掉,fire-and-forget log + return。
	if _, err := p.PersistAndDispatch(ctx, payload.ConversationID, senderType, senderID, payload.Content, parentMsgID, rootMsgID); err != nil {
		if errors.Is(err, ErrNotParticipant) {
			logpkg.FromCtx(ctx).WarnContext(ctx, "sender 不在会话 participants 中",
				"conv_id", payload.ConversationID, "sender_type", senderType, "sender_id", senderID)
		} else {
			logpkg.FromCtx(ctx).ErrorContext(ctx, "持久化失败",
				"conv_id", payload.ConversationID, "sender_type", senderType, "sender_id", senderID, "err", err)
		}
		return
	}
}

// PersistAndDispatch 在已确定的 convID 上做持久化 + dispatch,自动重试 PG 死锁。
// convID 必须是已存在的会话(调用方负责 FindOrCreateDM 或直接传 conv_id)。
// sender 必须是 convID 的 participant,否则返 ErrNotParticipant。
// 返回创建的 Message(含 server 生成的 ID + CreatedAt)。
//
// 重试:仅对 PostgreSQL deadlock(40P01)重试(最多 3 次),其他错误立即返回。
// 多 agent 并发发审批卡时,participants 行锁竞争会触发死锁,PG kill 其中一条事务;
// 40P01 是瞬态,重试几乎必成功。每轮重试前短暂退避(指数 10ms/20ms/40ms)。
//
// ctx 透传到所有 repo 调用(Exists / BeginTx / *Tx 系列 / sender 资料);
// HTTP 路径来自 c.Request.Context,WS 路径来自 client connCtx。
// 中止时进行中的查询会被驱动层取消,不浪费 DB 连接。
//
// 失败场景:
//   - sender 不是 participant → ErrNotParticipant
//   - DB/事务失败 → 包装的 error(具体原因)
//   - 死锁重试耗尽(3 次仍 40P01)→ 包装的 deadlock error
//
// 调用方:
//   - HTTP send_handler: 拿 msg.ID / msg.CreatedAt 返给 client;权限错 → 403,其他 → 500
//   - WS HandleIncoming: 复用本方法,error 时 log + return(保持 fire-and-forget)
func (p *Processor) PersistAndDispatch(ctx context.Context, convID, senderType, senderID string, content json.RawMessage, parentMsgID *string, rootMsgID *string) (*model.Message, error) {
	const maxRetries = 3
	var lastErr error
	for attempt := 0; attempt < maxRetries; attempt++ {
		msg, err := p.persistAndDispatchOnce(ctx, convID, senderType, senderID, content, parentMsgID, rootMsgID)
		if err == nil {
			return msg, nil
		}
		lastErr = err
		if !isDeadlock(err) {
			return nil, err
		}
		logpkg.FromCtx(ctx).WarnContext(ctx, "消息持久化遇 PG 死锁,准备重试",
			"conv_id", convID, "attempt", attempt+1, "err", err)
		backoff := time.Duration(1<<attempt) * 10 * time.Millisecond
		select {
		case <-time.After(backoff):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return nil, fmt.Errorf("消息持久化死锁重试耗尽(%d 次): %w", maxRetries, lastErr)
}

// persistAndDispatchOnce 执行一次持久化 + dispatch(不含重试)。
// 被 PersistAndDispatch 调用,死锁时整轮重试(事务已回滚,无副作用残留)。
func (p *Processor) persistAndDispatchOnce(ctx context.Context, convID, senderType, senderID string, content json.RawMessage, parentMsgID *string, rootMsgID *string) (*model.Message, error) {
	// 1. 校验 sender 是 participant(fail fast 防伪造 conv_id)
	ok, err := p.participantRepo.Exists(ctx, convID, senderID, senderType)
	if err != nil {
		return nil, fmt.Errorf("校验 participant 失败: %w", err)
	}
	if !ok {
		return nil, ErrNotParticipant
	}

	// 1.5 quote 校验 + 富化(Task 2/3):
	//   - validateQuote:校验 message_id 存在 + 属本会话(IDOR 防护,
	//     防 sender 伪造 quote.message_id 引用其他会话消息,泄漏 sender_name / preview)
	//   - enrichQuote:用 server 权威值覆盖 client 传入的 quote snapshot
	//     (防伪造 sender_name / msg_type / preview 等)
	// 必须在事务前完成,失败 fail-fast。
	if err := p.validateQuote(ctx, convID, content); err != nil {
		return nil, err
	}

	// 1.6 parent/root IDOR 校验(对称 validateQuote):防 sender 伪造 parent_msg_id / root_msg_id
	//   指向其他会话的消息。FK 只校验目标消息存在,不校验归属。
	//   - parent 必须存在 + 属本会话
	//   - root 必须存在 + 属本会话 + 必须是顶层(parent_msg_id IS NULL,根节点身份校验)
	// 缺一即 fail-fast,不落 messages 行。
	if err := p.validateParentRoot(ctx, convID, parentMsgID, rootMsgID); err != nil {
		return nil, err
	}
	// enrichQuote 返回的 content 是覆盖了 quote 字段的新 JSON,后续走 enhanceContentFromFile
	// 与 CreateTx 用同一个变量(参数 reassign,与 enhanceContentFromFile 的处理路径一致)。
	content, err = p.enrichQuote(ctx, convID, content)
	if err != nil {
		return nil, err
	}

	// 2. seq 序号(dispatch 用,事务外,避免事务内提序列号在回滚时漏号)
	//    统一走 hub.NextSeq,让 hub 直发事件(agent status / SendToUser 单播等)与消息事件
	//    共享同一计数器,保证单个 client 收到的所有 dispatch seq 单调递增,
	//    Resume 时按 per-client seq 比对不会漏推 / 重推(M10 bug 修复)。
	newSeq := p.hub.NextSeq()

	// 3. image/file 消息增强(从 files 表补字段)
	//    image: 补 width/height(防加载跳动)
	//    file: 补 file_size, mime_type(前端文件卡片展示用)
	enhancedContent := p.enhanceContentFromFile(ctx, content)

	// 3.5 落库前剥离 _stream_id(瞬态控制字段,让 APP 关联流式占位与终态,不应落历史库)。
	//     剥离后的 streamID 存到 streamIDForBroadcast,广播 dispatchData 时 injectStreamID 注入回去。
	//     放在 enhanceContentFromFile 之后(增强字段已补齐)、CreateTx 之前(落库的是剥离后的 content)。
	//     contentMeta 后续解析(只读 MsgType/Silent 顶层字段)不受影响:_stream_id 在 data 内层。
	enhancedContent, streamIDForBroadcast := stripStreamID(enhancedContent)
	if streamIDForBroadcast != "" {
		var dbg struct {
			MT string `json:"msg_type"`
			D  struct {
				T string `json:"text"`
			} `json:"data"`
		}
		_ = json.Unmarshal(enhancedContent, &dbg)
		logpkg.FromCtx(ctx).InfoContext(ctx,
			"[SSE-DBG] stripStreamID 落库前剥离",
			"sid", streamIDForBroadcast, "msg_type", dbg.MT, "text_len", len(dbg.D.T))
	}

	// 4. 事务:CreateTx → ListByConversationTx → CreateBatchTx → IncrUnreadTx → Commit
	//    3 个写操作(message + deliveries + participants)原子提交,保证「消息可见 ⟺
	//    未读计数对齐 ⟺ 投递状态对齐」,crash / 并发不会出现半提交不一致。
	tx, err := p.convRepo.BeginTx(ctx)
	if err != nil {
		return nil, fmt.Errorf("开启事务失败: %w", err)
	}
	defer tx.Rollback() // commit 后调用为 no-op(database/sql 保证)

	// 4.1 创建 message(已无 is_read 字段,per-recipient 状态走 deliveries 表)
	//     带 parent/root(子 agent 子树事件)走 CreateWithParentTx,否则走 CreateTx。
	var msg *model.Message
	if parentMsgID != nil && rootMsgID != nil {
		msg, err = p.msgRepo.CreateWithParentTx(ctx, tx, convID, senderType, senderID, enhancedContent, *parentMsgID, *rootMsgID)
	} else {
		msg, err = p.msgRepo.CreateTx(ctx, tx, convID, senderType, senderID, enhancedContent)
	}
	if err != nil {
		return nil, fmt.Errorf("创建消息失败: %w", err)
	}

	// 4.2 同事务查 participants(避免并发邀请 / 退群脏读)
	participants, err := p.participantRepo.ListByConversationTx(ctx, tx, convID)
	if err != nil {
		return nil, fmt.Errorf("查 participants 失败: %w", err)
	}

	// 4.3 过滤 sender 得 recipients(deliveries + unread 都不含 sender)
	recipients := make([]model.ConversationParticipant, 0, len(participants))
	senderRole := "member" // fallback:sender 不在 participants 时(理论不应发生,上面 Exists 已挡)
	for _, pt := range participants {
		if pt.MemberID == senderID && pt.MemberType == senderType {
			senderRole = pt.Role
			continue
		}
		recipients = append(recipients, pt)
	}

	// 审批卡(permission_card/question_card)是需用户立即操作的交互卡,即使由子 agent
	// 发出(parent/root != nil)也必须浮到主对话流:正常未读 + 可见 + 计入待办角标。
	// 因此 isChildEvent 排除审批卡,让其走顶层消息的 delivery/unread 路径。
	// 生成列 is_main_stream(migration 008)在 SQL 层做同样豁免(主列表/pending_count 可见)。
	var contentMeta model.MessageContent
	_ = json.Unmarshal(enhancedContent, &contentMeta) // 解析失败留零值,按非交互卡处理
	isInteractiveCard := contentMeta.MsgType == model.MsgTypePermissionCard || contentMeta.MsgType == model.MsgTypeQuestionCard
	isChildEvent := parentMsgID != nil && !isInteractiveCard

	// 4.4 批量插 deliveries(每 recipient 一行)。
	//     顶层消息 read_at=NULL(正常未读流程);子事件 read_at=NOW()(已读态,见上)。
	if isChildEvent {
		if err := p.deliveryRepo.CreateBatchReadTx(ctx, tx, msg.ID, recipients); err != nil {
			return nil, fmt.Errorf("插子事件 deliveries 失败: %w", err)
		}
	} else if err := p.deliveryRepo.CreateBatchTx(ctx, tx, msg.ID, recipients); err != nil {
		return nil, fmt.Errorf("插 deliveries 失败: %w", err)
	}

	// 4.5 全员 unread_count+1(除 sender) — silent 消息跳过(过程类消息不打扰用户)
	//     IncrUnreadTx 无条件给非 sender 全员 +1,与「是否在看会话」无关。
	//     client 端 chat_page.dart 在底部时收到消息立即 _markRead() 归零,
	//     不在底部时本地 +1(显示浮标)。这是 N 方模型的标准口径。
	//     子 agent 事件(parentMsgID != nil 且非审批卡)强制跳过(见 4.4,主列表不展示)。
	//     审批卡 plugin 端传 silent=false(sendCardByState),此处正常 IncrUnread。
	if isChildEvent {
		// 子 agent 事件不增未读计数(read_at 已标 NOW())。
	} else if contentMeta.Silent {
		// silent 消息仍创建 delivery 记录(追踪用),但不增未读计数
	} else if err := p.participantRepo.IncrUnreadTx(ctx, tx, convID, senderID, senderType); err != nil {
		return nil, fmt.Errorf("未读计数失败: %w", err)
	}

	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("提交事务失败: %w", err)
	}

	// 4.6 新消息自动取消全员隐藏(commit 之后的 best-effort 清理)。
	//     原在事务内与 IncrUnreadTx 对同一批 participant 行交叉锁,多 agent 并发
	//     触发 PG deadlock(40P01)→ 整条消息回滚丢失。Unhide 幂等(SET NULL),
	//     不要求与消息创建原子(消息已 commit 即可见,列表恢复显示延迟无影响),
	//     故移出事务,失败只 log 不阻塞消息投递。
	//     语义对齐 migration 004「新消息来时置空(自动恢复显示)」。
	if err := p.participantRepo.Unhide(ctx, convID); err != nil {
		logpkg.FromCtx(ctx).WarnContext(ctx, "取消会话隐藏失败(不阻塞消息投递)",
			"conv_id", convID, "err", err)
	}

	// 5. dispatch(commit 之后):遍历 participants 按 member_type 路由
	//    必须在 commit 之后才 dispatch,否则 dispatch 了的消息可能因 rollback 没真存。
	//    payload 加 sender_role 字段(spec §5.2):client 不破坏(忽略未知字段),新版 APP
	//    可用于权限按钮显隐(owner/admin/member 显示不同的会话操作)。
	//
	//    dispatch 给所有 participants(含 sender),让 sender 也收到自己的 MESSAGE_CREATE echo。
	//    用于多端同步(同一 user 多设备)和单端 HTTP 发送的去重(S2.x 客户端按 message_id 去重)。
	//    deliveries / unread_count 仍按 recipients(不含 sender)维护,不影响数据层语义。
	dispatch := model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageCreate,
		S:  newSeq,
	}
	// sender_name 用于 client 端通知显示(user-user 场景 bg-service 取此字段)。
	// sender_avatar_url 用于 bg-service 通知大头像(替代原依赖 UI IPC 同步的链路,
	// 让首次接收消息时通知也能拿到正确头像)。查询失败返空串,client fallback 色块。
	// conversation_type / conversation_title 用于 bg-service 群聊通知格式化
	// (群聊场景 title=群名,body=「${sender}：${内容}」;单聊维持 sender 作 title)。
	// 查询失败返空串,bg-service fallback 单聊格式,不阻塞 dispatch。
	senderName := p.senderDisplayName(ctx, senderID, senderType)
	senderAvatarURL := p.senderAvatarURL(ctx, senderID, senderType)
	convType, convTitle := p.conversationMeta(ctx, convID)
	// 广播 content:落库已剥离 _stream_id,此处注入回去,让 APP 据此同位置替换流式占位为终态。
	// msg.Content 是落库后的值(无 _stream_id),injectStreamID 不改动其他字段,只补 data._stream_id。
	broadcastContent := msg.Content
	if streamIDForBroadcast != "" {
		broadcastContent = injectStreamID(msg.Content, streamIDForBroadcast)
	}
	dispatchData, _ := json.Marshal(map[string]interface{}{
		"id":                 msg.ID,
		"conversation_id":    convID,
		"sender_type":        senderType,
		"sender_id":          senderID,
		"sender_role":        senderRole,
		"sender_name":        senderName,
		"sender_avatar_url":  senderAvatarURL,
		"conversation_type":  convType,
		"conversation_title": convTitle,
		"content":            broadcastContent,
		"parent_msg_id":      msg.ParentMsgID,
		"root_msg_id":        msg.RootMsgID,
		"created_at":         msg.CreatedAt,
	})
	dispatch.D = dispatchData

	for _, r := range participants {
		if r.MemberType == "user" {
			p.hub.SendToUser(r.MemberID, &dispatch)
		} else {
			p.hub.SendToAgent(r.MemberID, &dispatch)
		}
	}

	return msg, nil
}

// validateQuote 校验 content.data.quote.message_id 存在且属于本会话。
//
// IDOR 防护:防止 sender 伪造 quote.message_id 引用其他会话的消息
// (富化后会带 sender_name / preview 等快照字段,泄漏被引用消息内容)。
// 校验失败 fail-fast,不进入持久化事务,不广播。
//
// 本方法只做校验,不改 content。富化(覆盖客户端提供的 quote 字段为 server 权威值)
// 由后续 enrichQuote 在持久化前完成。
//
// 校验规则:
//   - content.data 缺 quote / quote 为 null → 静默通过(向后兼容)
//   - quote 不是 object → error
//   - quote.message_id 缺失 / null → error("必填")
//   - quote.message_id 类型错(非 string) → error("必须是字符串")
//   - quote.message_id 空串 → error("不能为空")
//   - msgRepo.Get 找不到该 id → error
//   - 被引用消息 conversation_id 与当前 convID 不一致 → error
func (p *Processor) validateQuote(ctx context.Context, convID string, raw json.RawMessage) error {
	var content struct {
		Data map[string]any `json:"data"`
	}
	if err := json.Unmarshal(raw, &content); err != nil {
		// content 整体不是合法 JSON 是更早的校验责任,
		// 此处静默跳过(保持与 enhanceContentFromFile 一致的 fail-soft 风格,
		// 真正的失败会在 CreateTx JSONB 写库时报错)。
		return nil
	}
	if content.Data == nil {
		return nil
	}
	rawQuote, ok := content.Data["quote"]
	if !ok || rawQuote == nil {
		return nil
	}
	quoteMap, ok := rawQuote.(map[string]any)
	if !ok {
		return fmt.Errorf("quote 必须是对象")
	}
	// M5 fix:区分 "缺失" 和 "类型错",给 client 更清晰的报错信号
	rawMsgID, exists := quoteMap["message_id"]
	if !exists || rawMsgID == nil {
		return fmt.Errorf("quote.message_id 必填")
	}
	msgID, ok := rawMsgID.(string)
	if !ok {
		return fmt.Errorf("quote.message_id 必须是字符串")
	}
	if msgID == "" {
		return fmt.Errorf("quote.message_id 不能为空")
	}
	quoted, err := p.msgRepo.Get(ctx, msgID)
	if err != nil {
		return fmt.Errorf("查 quote 目标消息失败: %w", err)
	}
	if quoted == nil {
		return fmt.Errorf("quote 目标消息不存在: %s", msgID)
	}
	if quoted.ConversationID != convID {
		return fmt.Errorf("quote 目标消息不属于该会话")
	}
	return nil
}

// validateParentRoot 校验 parent_msg_id / root_msg_id 归属,防 IDOR 跨会话伪造。
//
// 与 validateQuote 对称的安全校验,处理 parent/root 元字段:
//   - parentMsgID / rootMsgID 同时为 nil → 静默通过(普通主对话流消息)
//   - 任一非 nil 时,两个都必须非 nil(子 agent 事件必须同时带 parent + root)
//   - parent 消息必须存在 + ConversationID == convID
//   - root 消息必须存在 + ConversationID == convID
//   - root 必须是顶层(ParentMsgID IS NULL),防把中层消息冒充 root 拼错树
//
// FK 约束只挡「目标消息不存在」,不挡「目标消息属其他会话」;此处补齐归属校验。
// 任何 fail 都立即返 error,不落 messages 行(与 quote 跨会话拒绝一致口径)。
func (p *Processor) validateParentRoot(ctx context.Context, convID string, parentMsgID, rootMsgID *string) error {
	if parentMsgID == nil && rootMsgID == nil {
		return nil
	}
	if parentMsgID == nil || rootMsgID == nil {
		return fmt.Errorf("parent_msg_id 与 root_msg_id 必须同时存在或同时缺失")
	}
	// uuid 入口校验(fail-fast):非法 UUID 直接返清晰错误,
	// 避免落到 msgRepo.Get 触发 PG "invalid input syntax for type uuid" → 500。
	if _, err := uuid.Parse(*parentMsgID); err != nil {
		return fmt.Errorf("parent_msg_id 非合法 UUID: %w", err)
	}
	if _, err := uuid.Parse(*rootMsgID); err != nil {
		return fmt.Errorf("root_msg_id 非合法 UUID: %w", err)
	}
	parent, err := p.msgRepo.Get(ctx, *parentMsgID)
	if err != nil {
		return fmt.Errorf("查 parent 消息失败: %w", err)
	}
	if parent == nil {
		return fmt.Errorf("parent 消息不存在: %s", *parentMsgID)
	}
	if parent.ConversationID != convID {
		return fmt.Errorf("parent 消息不属于该会话")
	}
	root, err := p.msgRepo.Get(ctx, *rootMsgID)
	if err != nil {
		return fmt.Errorf("查 root 消息失败: %w", err)
	}
	if root == nil {
		return fmt.Errorf("root 消息不存在: %s", *rootMsgID)
	}
	if root.ConversationID != convID {
		return fmt.Errorf("root 消息不属于该会话")
	}
	if root.ParentMsgID != nil {
		// root 必须是顶层 task 卡片(parent_msg_id IS NULL)。
		// 中层消息冒充 root 会让消息树错乱。
		return fmt.Errorf("root 消息必须是顶层(parent_msg_id 为空)")
	}
	// 树链一致性(防拼出非法树):parent 必须挂在 root 子树下。
	//   - parent == root(一层嵌套): parent 自己就是 root,上面 root.ParentMsgID==nil 已挡。
	//   - parent != root(多层嵌套): parent 是 root 子树中的某条消息,
	//     其 root_msg_id 必须指向同一 root(防止 sender 拿同会话两个顶层拼出断裂的树)。
	if parent.ID != root.ID {
		if parent.RootMsgID == nil {
			return fmt.Errorf("parent 不是 root 子树成员(parent_msg_id 非空但自身 root_msg_id 为空)")
		}
		if *parent.RootMsgID != *rootMsgID {
			return fmt.Errorf("parent 不属于该 root 子树(parent.root_msg_id 与 root_msg_id 不一致)")
		}
	}
	return nil
}

// 调用方必须先调用 validateQuote 确认 quote 合法(message_id 存在 + 属本会话)。
// 富化的字段全部取自被引用消息(server 端权威源):
//   - sender_type / sender_id: 从被引用消息顶层字段取
//   - sender_name: 通过 senderDisplayName 查 users / agents 表(与 dispatch payload 一致口径)
//   - msg_type: 从被引用消息的 content JSONB 解析
//   - preview: 按 msg_type 抽取的单行预览(详见 extractPreview)
//
// message_id 字段保留 client 传入值(就是被引用消息 id)。
//
// 幂等性:重复调同 content 没有副作用(每次都重新查被引用消息 + 覆盖)。
// fail-soft:content 不是合法 JSON / data 缺失 / quote 缺失,均静默返回(后续 CreateTx 会兜底报错)。
func (p *Processor) enrichQuote(ctx context.Context, convID string, raw json.RawMessage) (json.RawMessage, error) {
	// 先解到 generic map,改完再 marshal 回去(参考 enhanceContentFromFile 模式)
	var generic map[string]interface{}
	if err := json.Unmarshal(raw, &generic); err != nil {
		// 非法 JSON 由更早的校验/写库兜底,此处静默不改
		return raw, nil
	}
	data, ok := generic["data"].(map[string]interface{})
	if !ok {
		return raw, nil // 非 object data,不是 quote 能处理的形态
	}
	rawQuote, exists := data["quote"]
	if !exists || rawQuote == nil {
		return raw, nil // 无 quote,跳过
	}
	quoteMap, ok := rawQuote.(map[string]interface{})
	if !ok {
		return raw, nil // validateQuote 已挡,保守处理
	}
	msgID, _ := quoteMap["message_id"].(string)
	if msgID == "" {
		return raw, nil // validateQuote 已挡
	}

	quoted, err := p.msgRepo.Get(ctx, msgID)
	if err != nil {
		return raw, fmt.Errorf("富化时查 quote 目标消息失败: %w", err)
	}
	if quoted == nil {
		// 不应该发生(validateQuote 已挡),保守不改
		return raw, nil
	}

	// I1 安全修复:被引用消息已撤回(deleted_at != nil)时不泄漏原文 preview。
	// 注意 MessageRepo.Get 不过滤 deleted_at(权限校验需要知道消息是否存在),
	// 因此 enrichQuote 必须自己挡:撤回语义下 preview 改用占位,
	// sender_* / msg_type 仍按真实值填,让 client 渲染「${name} 的消息已被撤回」占位。
	// 仍允许 quote(fail-soft,UX:不要因被引用的消息被撤回就阻塞整条消息发送)。
	recalled := quoted.DeletedAt.Valid

	// 从被引用消息 content JSONB 解出 msg_type + data(用于 preview 抽取)
	var wrapper struct {
		MsgType string         `json:"msg_type"`
		Data    map[string]any `json:"data"`
	}
	_ = json.Unmarshal(quoted.Content, &wrapper)

	// sender_name 通过 senderDisplayName 查表(MessageRepo.Get 不带 JOIN,
	// 这里复用 dispatch payload 用的同一口径)
	senderName := p.senderDisplayName(ctx, quoted.SenderID, quoted.SenderType)

	preview := "[消息已撤回]"
	if !recalled {
		preview = p.extractPreview(wrapper.MsgType, wrapper.Data)
	}

	enriched := model.Quote{
		MessageID:  msgID,
		SenderType: quoted.SenderType,
		SenderID:   quoted.SenderID,
		SenderName: senderName,
		MsgType:    wrapper.MsgType,
		Preview:    preview,
	}
	data["quote"] = enriched

	enhanced, err := json.Marshal(generic)
	if err != nil {
		// marshal 失败保守返回原 content(几乎不会触发,generic 来自原 raw 解析)
		return raw, nil
	}
	return enhanced, nil
}

// extractPreview 按被引用消息的 msg_type 抽取单行预览。
//
// 规则:
//   - text:        首行前 50 字符(换行折叠成空格,避免预览换行)
//   - markdown:    剥除 markdown 语法后折叠换行的前 50 字符
//   - image:       "[图片]"(无内容信息可抽,固定占位)
//   - file:        "[文件] <filename>"(若 filename 缺失则只占位)
//   - mixed:       data.text 前 50 字符(无文本时 fallback "[图文]")
//   - card:        "[卡片] <title>"(审批/扩展卡片标题)
//   - 其他/未知:   "[消息]"(默认占位,不暴露原文)
//
// 嵌套剥除:被引用消息本身是「带 quote 的回复」时,本方法只看它的 msg_type + data.text,
// 不递归它的 data.quote(不会出现「引用的引用」预览)。
func (p *Processor) extractPreview(msgType string, data map[string]any) string {
	switch msgType {
	case "text":
		text, _ := data["text"].(string)
		return truncate(strings.ReplaceAll(text, "\n", " "), 50)
	case "markdown":
		md, _ := data["text"].(string)
		// M1: 折叠换行(符合 extractPreview 文档「单行预览」约束,与 text case 对称)
		return truncate(strings.ReplaceAll(stripMarkdown(md), "\n", " "), 50)
	case "image":
		return "[图片]"
	case "file":
		name, _ := data["filename"].(string)
		if name == "" {
			return "[文件]"
		}
		return "[文件] " + name
	case "mixed":
		// I2: mixed 有 data.text 时抽前 50 字(与 text/markdown 对称),空串 fallback 占位
		text, _ := data["text"].(string)
		if text == "" {
			return "[图文]"
		}
		return truncate(strings.ReplaceAll(text, "\n", " "), 50)
	case "card":
		title, _ := data["title"].(string)
		if title == "" {
			return "[卡片]"
		}
		return "[卡片] " + title
	default:
		return "[消息]"
	}
}

// markdownSyntax 匹配常见 markdown 语法字符(行内标记,不剥整段代码块语法以外的结构)。
// 刻意简化:不剥 #、> 这类段落开头的语法(它们也常出现在引用回复正文里,剥掉会丢义),
// 只剥行内强调 / 代码 / 删除线等纯装饰符号。
var markdownSyntax = regexp.MustCompile("`{1,3}|[*_~|]")

// stripMarkdown 剥除 markdown 行内语法符号,返纯文本(供预览用)。
func stripMarkdown(s string) string {
	return markdownSyntax.ReplaceAllString(s, "")
}

// truncate 按 rune 截断字符串到 n 个字符,超出加 "..."。
// rune 感知(避免中文按字节切到一半乱码)。
func truncate(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n]) + "..."
}

// enhanceContentFromFile 对 image/file 消息从 files 表补字段。
// image: 补 width/height(防加载跳动,前端发图时只带 file_id,server 持久化前从
//
//	files 表查权威宽高,补完后存库 + dispatch 两处都带,前端按真实尺寸渲染无跳动)
//
// file: 补 file_size, mime_type(前端文件卡片展示用)
//
// 幂等:data 已有非 0 值则跳过,避免每条消息多一次 DB 查询。
// fail-soft:非 image/file / file_id 缺失 / files 表查不到 / 字段为 NULL / json 解析失败,
// 均静默返回原 content 不阻断发送。
func (p *Processor) enhanceContentFromFile(ctx context.Context, raw json.RawMessage) json.RawMessage {
	var content struct {
		MsgType string `json:"msg_type"`
		Data    struct {
			FileID   string `json:"file_id"`
			Width    *int   `json:"width"`
			Height   *int   `json:"height"`
			FileSize *int64 `json:"file_size"`
			MimeType string `json:"mime_type"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &content); err != nil {
		return raw
	}
	if content.MsgType != "image" && content.MsgType != "file" {
		return raw
	}
	if content.Data.FileID == "" {
		return raw
	}

	f, err := p.fileRepo.GetByID(ctx, content.Data.FileID)
	if err != nil || f == nil {
		return raw
	}

	var generic map[string]interface{}
	if err := json.Unmarshal(raw, &generic); err != nil {
		return raw
	}
	data, ok := generic["data"].(map[string]interface{})
	if !ok {
		return raw
	}

	if content.MsgType == "image" {
		if (content.Data.Width == nil || *content.Data.Width <= 0) &&
			f.Width != nil && f.Height != nil {
			data["width"] = *f.Width
			data["height"] = *f.Height
		}
	}
	if content.MsgType == "file" {
		if content.Data.FileSize == nil || *content.Data.FileSize <= 0 {
			data["file_size"] = f.Size
		}
		if content.Data.MimeType == "" {
			data["mime_type"] = f.MimeType
		}
	}

	enhanced, err := json.Marshal(generic)
	if err != nil {
		return raw
	}
	return enhanced
}
