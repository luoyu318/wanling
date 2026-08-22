export interface WSMessage {
  op: number
  d?: Record<string, unknown>
  t?: string
  s?: number
}

export interface HelloPayload {
  heartbeat_interval: number
}

export interface MessageContent {
  msg_type: string
  data: Record<string, unknown>
  silent?: boolean
  parent_msg_id?: string
  root_msg_id?: string
}

export interface MessageCreatePayload {
  id: string
  conversation_id: string
  sender_type: "user" | "agent"
  sender_id: string
  sender_name?: string
  sender_avatar_url?: string
  conversation_type?: string
  conversation_title?: string
  content: MessageContent
  created_at: string
}

export interface TypingStartPayload {
  conversation_id: string
}

export interface GenerationAbortPayload {
  conversation_id: string
}

export interface ConvUpdatePayload {
  conv_id: string
  title: string
  avatar_url: string
}

export interface OutboundMessage {
  conversation_id: string
  content: MessageContent
}

/** question 选项。 */
export interface ApprovalOption { id: string; label: string }

/** approvals.ask 入参（command/tool/file/slash_confirm/question 通用）。 */
export interface AskOptions {
  cardType: "command" | "tool" | "file" | "slash_confirm" | "question"
  title: string
  preview?: string
  toolName?: string
  sessionKey: string
  /** question 专用 */
  options?: ApprovalOption[]
  multiSelect?: boolean
  /** command 白名单 glob（* % 差异由 server 转换，这里传 glob） */
  allowPattern?: string
  /** slash_confirm 专用 */
  confirmId?: string
  timeoutSec?: number
}

/** approvals.ask 结果。 */
export type AskResult =
  | { state: "approved"; decision: string; answers?: string[]; decidedBy?: string; reason?: string }
  | { state: "denied"; decision: string; decidedBy?: string; reason?: string }
  | { state: "expired" }
