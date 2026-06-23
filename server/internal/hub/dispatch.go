package hub

import (
	"encoding/json"

	"github.com/wanling/server/internal/model"
)

// BroadcastMessageUpdate 给会话双端（user+agent）发 MESSAGE_UPDATE。
// content 是更新后的完整 messages.content（json.RawMessage）。
func (h *Hub) BroadcastMessageUpdate(userID, agentID, messageID, conversationID string, content json.RawMessage) {
	payload, _ := json.Marshal(map[string]any{
		"message_id":      messageID,
		"conversation_id": conversationID,
		"content":         content,
	})
	msg := &model.WSMessage{
		Op: model.OpDispatch,
		T:  model.EventMessageUpdate,
		S:  h.NextSeq(),
		D:  payload,
	}
	h.SendToConv(userID, agentID, msg)
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
