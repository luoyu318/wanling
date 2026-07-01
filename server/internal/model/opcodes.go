package model

import "encoding/json"

const (
	OpDispatch      = 0
	OpHeartbeat     = 1
	OpIdentify      = 2
	OpSetActiveConv = 3 // client 上报当前正在看的会话（服务端记录 activeConv 状态,不再用于跳过未读计数;client 端 conversationProvider 据此避免徽章闪烁）
	OpResume        = 6
	OpReconnect     = 7
	OpHello         = 10
	OpHeartbeatACK  = 11
)

type WSMessage struct {
	Op int             `json:"op"`
	D  json.RawMessage `json:"d,omitempty"`
	T  string          `json:"t,omitempty"`
	S  int64           `json:"s,omitempty"`
}

const (
	EventMessageCreate   = "MESSAGE_CREATE"
	EventMessageDelete   = "MESSAGE_DELETE"
	EventAgentOnline     = "AGENT_ONLINE"
	EventAgentOffline    = "AGENT_OFFLINE"
	EventMessageUpdate   = "MESSAGE_UPDATE"
	EventApprovalDecided = "APPROVAL_DECIDED"
	EventApprovalExpired = "APPROVAL_EXPIRED"

	// 会话管理(N 方 participants 模型,Task 2.2 引入)
	EventConversationParticipantJoin  = "CONVERSATION_PARTICIPANT_JOIN"
	EventConversationParticipantLeave = "CONVERSATION_PARTICIPANT_LEAVE"
	EventConversationUpdate           = "CONVERSATION_UPDATE"

	// 好友系统(Task 2.2 引入,handler 在 Task 2.5)
	EventFriendRequestReceived = "FRIEND_REQUEST_RECEIVED"
	EventFriendRequestDecided  = "FRIEND_REQUEST_DECIDED"
	EventFriendRemoved         = "FRIEND_REMOVED"
)
