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

	// RPC 请求-响应通道(Phase 1 引入,详见 docs/superpowers/specs/2026-07-19-rpc-protocol-design.md)。
	// OpPluginCall/Result 绕过 dispatchBuffer:hub.bufferedSend 仅对 Op==OpDispatch 进 buffer,
	// 这两个 opcode 天然不缓存,断线 Resume 不会补发已过期的 RPC 响应。
	OpPluginCall   = 12 // S→C, server → plugin RPC 请求
	OpPluginResult = 13 // C→S, plugin → server RPC 响应

	// 流式输出(plugin → server → 正在观看的 user）。携带生成中的文本全量快照，
	// 让 APP 逐段渲染 reasoning/text。绕过 dispatchBuffer(bufferedSend 仅缓存 OpDispatch)、
	// 不落库、不带 seq、不计未读、不触发离线推送。终态仍走 OpDispatch MESSAGE_CREATE。
	OpStream = 14
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

	// agent_session 元数据(mode/model/cwd/git_branch)更新通知。
	// plugin 通过 UpdateSessionMetaAsAgent PATCH server 后,server 写库 + 广播给本会话 user 端,
	// APP chatProvider 监听刷新 SessionMetaStrip / EnvMetaStrip。仅推 user(跳过 agent),
	// 与 BroadcastConversationUpdateToUsers 同口径,断回环 plugin 收到又触发改 OC。
	EventSessionMetaUpdate = "SESSION_META_UPDATE"

	// 好友系统(Task 2.2 引入,handler 在 Task 2.5)
	EventFriendRequestReceived = "FRIEND_REQUEST_RECEIVED"
	EventFriendRequestDecided  = "FRIEND_REQUEST_DECIDED"
	EventFriendRemoved         = "FRIEND_REMOVED"

	// 多端同步:某 user 在某端 markRead 后,server 广播给该 user 全部 WS 连接,
	// 让其他端立即同步已读状态(徽章归零 + 当前 ChatPage 刷 firstUnread)。
	// 不广播给其他 user / agent(已读是个人维度)。
	EventMessageRead = "MESSAGE_READ"

	// 停止生成:user 点击停止按钮 → server 转发给会话内的 agent(plugin)。
	// plugin 收到后调 OpenCode SDK abort API 中止当前生成。
	EventGenerationAbort = "GENERATION_ABORT"

	// plugin 上报 agent 可选模型清单(APP 更换模型功能)。
	// plugin 启动/重连时拉 opencode providers,全量上报给 server 内存缓存。
	// APP 通过 REST 拉取本清单渲染模型选择器,选模型后随消息下发。
	EventAgentModels = "AGENT_MODELS"

	// plugin 上报 agent 命令清单(APP 斜杠命令功能)。
	// plugin 启动/重连时拉 opencode command.list,全量上报给 server 内存缓存。
	// APP 通过 REST 拉取本清单渲染斜杠命令选择器,选中后调 plugin 执行。
	EventAgentSlashCatalog = "AGENT_SLASH_CATALOG"

	EventPluginCapabilities = "PLUGIN_CAPABILITIES"

	// 流式输出事件(op=14 STREAM)。
	// payload: {conversation_id, stream_id, msg_type, text}。text 为累积全量快照。
	EventStream = "STREAM"
)
