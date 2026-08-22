export const OP_HELLO = 10
export const OP_IDENTIFY = 2
export const OP_HEARTBEAT = 1
export const OP_HEARTBEAT_ACK = 11
export const OP_DISPATCH = 0
export const OP_RESUME = 6
export const OP_RECONNECT = 7

export const EVENT_MESSAGE_CREATE = "MESSAGE_CREATE"
export const EVENT_TYPING_START = "TYPING_START"
export const EVENT_GENERATION_ABORT = "GENERATION_ABORT"
export const EVENT_CONVERSATION_UPDATE = "CONVERSATION_UPDATE"
export const EVENT_AGENT_MODELS = "AGENT_MODELS"
export const EVENT_AGENT_SLASH_CATALOG = "AGENT_SLASH_CATALOG"
export const EVENT_APPROVAL_DECIDED = "APPROVAL_DECIDED"
export const EVENT_APPROVAL_EXPIRED = "APPROVAL_EXPIRED"

export const OP_PLUGIN_CALL = 12
export const OP_PLUGIN_RESULT = 13

// 流式输出(plugin → server → 正在观看的 user)。绕过 dispatchBuffer/Resume,
// 不带 seq、不落库、不计未读。终态仍走 OP_DISPATCH MESSAGE_CREATE。
export const OP_STREAM = 14

export const EVENT_PLUGIN_CAPABILITIES = "PLUGIN_CAPABILITIES"
