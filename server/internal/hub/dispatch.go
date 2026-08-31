package hub

import (
	"context"
	"encoding/json"
	"time"

	logpkg "github.com/wanling/server/internal/log"
	"github.com/wanling/server/internal/model"
)

// marshalOrWarn 序列化 dispatch payload，失败时记 warn 日志并返回 nil。
// 调用方应在返回 nil 时跳过发送。
func marshalOrWarn(v any) json.RawMessage {
	data, err := json.Marshal(v)
	if err != nil {
		logpkg.FromCtx(context.Background()).WarnContext(context.Background(), "dispatch json.Marshal 失败", "err", err)
		return nil
	}
	return data
}

// BroadcastMessageUpdate 给会话全员发 MESSAGE_UPDATE。
// content 是更新后的完整 messages.content（json.RawMessage）。
// 按 participants 遍历路由(N 方模型),不再要求调用方显式传 userID/agentID。
// 不含会话元信息(convType/convTitle 为空),调用方需 title/type 时用
// BroadcastMessageUpdateWithConvMeta。
func (h *Hub) BroadcastMessageUpdate(convID, messageID string, content json.RawMessage) {
	h.broadcastMessageUpdate(convID, messageID, content, MessageUpdateMeta{})
}

// MessageUpdateMeta 翻转广播附带的会话与 sender 元信息。
// 空字段照常下发(client 按 falsy 处理,兼容旧 client 忽略未知字段)。
type MessageUpdateMeta struct {
	ConvType        string
	ConvTitle       string
	SenderID        string
	SenderName      string
	SenderAvatarURL string
}

// BroadcastMessageUpdateWithConvMeta 同 BroadcastMessageUpdate,附带会话
// 元信息与 sender 三件套。聚合卡回合结束翻转(set_silent→false)广播用:
//   - conversation_type/title:bg-service 判断 agent_session → 通知 title=会话标题
//   - sender_id/name/avatar_url:bg-service 弹通知直接消费,不再依赖
//     MESSAGE_CREATE 阶段的内存回查(bg 重启后回查必失败,曾导致通知
//     title fallback 'Agent' + 头像色块)
func (h *Hub) BroadcastMessageUpdateWithConvMeta(convID, messageID string, content json.RawMessage, meta MessageUpdateMeta) {
	h.broadcastMessageUpdate(convID, messageID, content, meta)
}

func (h *Hub) broadcastMessageUpdate(convID, messageID string, content json.RawMessage, meta MessageUpdateMeta) {
	payload := marshalOrWarn(map[string]any{
		"message_id":         messageID,
		"conversation_id":    convID,
		"content":            content,
		"conversation_type":  meta.ConvType,
		"conversation_title": meta.ConvTitle,
		"sender_id":          meta.SenderID,
		"sender_name":        meta.SenderName,
		"sender_avatar_url":  meta.SenderAvatarURL,
	})
	if payload == nil {
		return
	}
	msg := &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageUpdate,
		S:  h.NextSeq(),
		D:  payload,
	}
	h.SendToConv(convID, msg)
}

// SendApprovalDecided 给审批发起方发 APPROVAL_DECIDED。发起方用 session_key 路由到等待中的协程。
// 参数名 initiatorID 对齐 approvals.initiator_id 字段语义;当前 initiator_type 固定 agent,
// 内部用 SendToAgent 路由 — 未来若扩展 user 发起审批,需改路由逻辑。
func (h *Hub) SendApprovalDecided(initiatorID string, payload map[string]any) {
	data := marshalOrWarn(payload)
	if data == nil {
		return
	}
	msg := &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventApprovalDecided,
		S:  h.NextSeq(),
		D:  data,
	}
	h.SendToAgent(initiatorID, msg)
}

// SendApprovalExpired 给审批发起方发 APPROVAL_EXPIRED。发起方用 session_key 路由到等待中的协程。
// 参数名 initiatorID 对齐 approvals.initiator_id 字段语义;当前 initiator_type 固定 agent,
// 内部用 SendToAgent 路由 — 未来若扩展 user 发起审批,需改路由逻辑。
func (h *Hub) SendApprovalExpired(initiatorID string, payload map[string]any) {
	data := marshalOrWarn(payload)
	if data == nil {
		return
	}
	msg := &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventApprovalExpired,
		S:  h.NextSeq(),
		D:  data,
	}
	h.SendToAgent(initiatorID, msg)
}

// BroadcastParticipantJoin 邀请/加群通知(该会话全员)。
// memberType: user / agent;role: owner / admin / member;addedBy: 操作者 member_id。
func (h *Hub) BroadcastParticipantJoin(convID, memberID, memberType, role, addedBy string) {
	data := marshalOrWarn(map[string]string{
		"conv_id":     convID,
		"member_id":   memberID,
		"member_type": memberType,
		"role":        role,
		"added_by":    addedBy,
	})
	if data == nil {
		return
	}
	h.SendToConv(convID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventConversationParticipantJoin,
		S:  h.NextSeq(),
		D:  data,
	})
}

// BroadcastParticipantLeave 退群/踢人通知(该会话全员)。
// reason: left(主动退) / kicked(被踢)。
func (h *Hub) BroadcastParticipantLeave(convID, memberID, memberType, reason string) {
	data := marshalOrWarn(map[string]string{
		"conv_id":     convID,
		"member_id":   memberID,
		"member_type": memberType,
		"reason":      reason,
	})
	if data == nil {
		return
	}
	h.SendToConv(convID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventConversationParticipantLeave,
		S:  h.NextSeq(),
		D:  data,
	})
}

// BroadcastConversationUpdate 群名/头像变更通知(该会话全员)。
// title/avatarURL 为空字符串时客户端应保留原值(payload 字段存在但空)。
func (h *Hub) BroadcastConversationUpdate(convID, title, avatarURL string) {
	data := marshalOrWarn(map[string]string{
		"conv_id":    convID,
		"title":      title,
		"avatar_url": avatarURL,
	})
	if data == nil {
		return
	}
	h.SendToConv(convID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventConversationUpdate,
		S:  h.NextSeq(),
		D:  data,
	})
}

// BroadcastConversationUpdateToUsers 群名/头像变更通知(仅 user 端,跳过 agent)。
// 用于 agent 触发的改名(UpdateTitleAsAgent):广播给 user 让 APP 实时刷新,
// 但不回传给 agent —— 否则插件(agent 连接)会收到自己刚写的标题,
// 又调 OC PATCH 改 OC,OC 又回 session.updated,形成回声循环。
// 单向同步的物理断环点。
func (h *Hub) BroadcastConversationUpdateToUsers(convID, title, avatarURL string) {
	data := marshalOrWarn(map[string]string{
		"conv_id":    convID,
		"title":      title,
		"avatar_url": avatarURL,
	})
	if data == nil {
		return
	}
	msg := &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventConversationUpdate,
		S:  h.NextSeq(),
		D:  data,
	}
	h.SendToConvFiltered(convID, msg, func(memberType string) bool {
		return memberType != "agent"
	})
}

// BroadcastSessionMetaUpdateToUsers agent_session 元数据更新通知(仅 user 端,跳过 agent)。
// plugin 调 UpdateSessionMetaAsAgent 写库后触发,APP 收到 SESSION_META_UPDATE 后
// 实时刷新 SessionMetaStrip(mode/model) 和 EnvMetaStrip(cwd/git_branch)。
// 与 BroadcastConversationUpdateToUsers 同口径:仅推 user,断回环 plugin→OC。
// sessionMeta 为完整的 JSONB 内容(json.RawMessage),直接透传给 APP 解析。
func (h *Hub) BroadcastSessionMetaUpdateToUsers(convID string, sessionMeta json.RawMessage) {
	data := marshalOrWarn(map[string]any{
		"conv_id":      convID,
		"session_meta": sessionMeta,
	})
	if data == nil {
		return
	}
	msg := &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventSessionMetaUpdate,
		S:  h.NextSeq(),
		D:  data,
	}
	h.SendToConvFiltered(convID, msg, func(memberType string) bool {
		return memberType != "agent"
	})
}

// SendFriendRequestReceived 好友请求通知(仅接收方 toUserID)。
// fromUser 字段聚合发起方摘要,避免接收方再查库。
func (h *Hub) SendFriendRequestReceived(toUserID, requestID, fromUserID, fromUsername, fromNickname, fromAvatarURL string, createdAt time.Time) {
	data := marshalOrWarn(map[string]any{
		"request_id": requestID,
		"from_user": map[string]string{
			"id":         fromUserID,
			"username":   fromUsername,
			"nickname":   fromNickname,
			"avatar_url": fromAvatarURL,
		},
		"created_at": createdAt,
	})
	if data == nil {
		return
	}
	h.SendToUser(toUserID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventFriendRequestReceived,
		S:  h.NextSeq(),
		D:  data,
	})
}

// SendFriendRequestDecided 好友请求决策通知(仅发起方 toUserID)。
// decision: accepted / rejected / canceled。
func (h *Hub) SendFriendRequestDecided(toUserID, requestID, decision, byUserID string) {
	data := marshalOrWarn(map[string]string{
		"request_id": requestID,
		"decision":   decision,
		"by_user":    byUserID,
	})
	if data == nil {
		return
	}
	h.SendToUser(toUserID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventFriendRequestDecided,
		S:  h.NextSeq(),
		D:  data,
	})
}

// SendFriendRemoved 删除好友通知(仅对方 toUserID)。
// payload 只带操作者 id,接收方据此从本地好友列表移除。
func (h *Hub) SendFriendRemoved(toUserID, byUserID string) {
	data := marshalOrWarn(map[string]string{
		"by_user": byUserID,
	})
	if data == nil {
		return
	}
	h.SendToUser(toUserID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventFriendRemoved,
		S:  h.NextSeq(),
		D:  data,
	})
}
