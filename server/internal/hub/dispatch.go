package hub

import (
	"encoding/json"
	"time"

	"github.com/wanling/server/internal/model"
)

// BroadcastMessageUpdate 给会话全员发 MESSAGE_UPDATE。
// content 是更新后的完整 messages.content（json.RawMessage）。
// 按 participants 遍历路由(N 方模型),不再要求调用方显式传 userID/agentID。
func (h *Hub) BroadcastMessageUpdate(convID, messageID string, content json.RawMessage) {
	payload, _ := json.Marshal(map[string]any{
		"message_id":      messageID,
		"conversation_id": convID,
		"content":         content,
	})
	msg := &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageUpdate,
		S:  h.NextSeq(),
		D:  payload,
	}
	h.SendToConv(convID, msg)
}

// SendApprovalDecided 给 agent 发 APPROVAL_DECIDED。agent 用 session_key 路由到等待中的协程。
func (h *Hub) SendApprovalDecided(agentID string, payload map[string]any) {
	data, _ := json.Marshal(payload)
	msg := &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventApprovalDecided,
		S:  h.NextSeq(),
		D:  data,
	}
	h.SendToAgent(agentID, msg)
}

// SendApprovalExpired 给 agent 发 APPROVAL_EXPIRED。
func (h *Hub) SendApprovalExpired(agentID string, payload map[string]any) {
	data, _ := json.Marshal(payload)
	msg := &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventApprovalExpired,
		S:  h.NextSeq(),
		D:  data,
	}
	h.SendToAgent(agentID, msg)
}

// BroadcastParticipantJoin 邀请/加群通知(该会话全员)。
// memberType: user / agent;role: owner / admin / member;addedBy: 操作者 member_id。
func (h *Hub) BroadcastParticipantJoin(convID, memberID, memberType, role, addedBy string) {
	data, _ := json.Marshal(map[string]string{
		"conv_id":     convID,
		"member_id":   memberID,
		"member_type": memberType,
		"role":        role,
		"added_by":    addedBy,
	})
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
	data, _ := json.Marshal(map[string]string{
		"conv_id":     convID,
		"member_id":   memberID,
		"member_type": memberType,
		"reason":      reason,
	})
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
	data, _ := json.Marshal(map[string]string{
		"conv_id":    convID,
		"title":      title,
		"avatar_url": avatarURL,
	})
	h.SendToConv(convID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventConversationUpdate,
		S:  h.NextSeq(),
		D:  data,
	})
}

// SendFriendRequestReceived 好友请求通知(仅接收方 toUserID)。
// fromUser 字段聚合发起方摘要,避免接收方再查库。
func (h *Hub) SendFriendRequestReceived(toUserID, requestID, fromUserID, fromUsername, fromNickname, fromAvatarURL string, createdAt time.Time) {
	data, _ := json.Marshal(map[string]any{
		"request_id": requestID,
		"from_user": map[string]string{
			"id":         fromUserID,
			"username":   fromUsername,
			"nickname":   fromNickname,
			"avatar_url": fromAvatarURL,
		},
		"created_at": createdAt,
	})
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
	data, _ := json.Marshal(map[string]string{
		"request_id": requestID,
		"decision":   decision,
		"by_user":    byUserID,
	})
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
	data, _ := json.Marshal(map[string]string{
		"by_user": byUserID,
	})
	h.SendToUser(toUserID, &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventFriendRemoved,
		S:  h.NextSeq(),
		D:  data,
	})
}
