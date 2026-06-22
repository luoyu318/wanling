package model

import "encoding/json"

const (
	OpDispatch     = 0
	OpHeartbeat    = 1
	OpIdentify     = 2
	OpResume       = 6
	OpReconnect    = 7
	OpHello        = 10
	OpHeartbeatACK = 11
)

type WSMessage struct {
	Op int             `json:"op"`
	D  json.RawMessage `json:"d,omitempty"`
	T  string          `json:"t,omitempty"`
	S  int64           `json:"s,omitempty"`
}

const (
	EventMessageCreate = "MESSAGE_CREATE"
	EventMessageDelete = "MESSAGE_DELETE"
	EventAgentOnline   = "AGENT_ONLINE"
	EventAgentOffline  = "AGENT_OFFLINE"
)
