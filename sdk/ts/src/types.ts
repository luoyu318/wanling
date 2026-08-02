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
