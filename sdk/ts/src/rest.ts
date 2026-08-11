import { readFileSync, statSync } from "node:fs"
import type { MessageContent } from "./types.js"

export class ApiError extends Error {
  status: number
  constructor(status: number, message: string) {
    super(message)
    this.status = status
  }
}

export type SessionMeta = {
  mode: string
  modelId: string
  providerId: string
  variant?: string
  modelName?: string
  providerName?: string
  gitBranch?: string
  tokensTotal?: number
  contextUsed?: number
  contextLimit?: number
}

export type ApprovalCardType = "command" | "tool" | "file" | "slash_confirm"

export type CreateApprovalBody = {
  card_type: ApprovalCardType
  title: string
  preview?: string
  preview_language?: string
  tool_name?: string
  file?: { id: string }
  meta?: Array<{ icon?: string; text?: string; warn?: boolean }>
  session_key: string
  allow_pattern?: string
  confirm_id?: string
  timeout_sec?: number
}

export type CreateApprovalResult = {
  approval_id?: string
  state?: string
  auto_approved?: boolean
  matched_pattern?: string
}

// 聚合卡增量 op,对齐 docs/ai-handbook/aggregate-card.md。
// 与 updateMessageContent(全量替换)互补:聚合卡流式增量用本方法,避免全量替换
// 触发 server mergePreservedSilent 保留 silent 造成翻转不生效。
export type AggregateElement = {
  type: string
  element_id: string
  data: Record<string, unknown>
}

export type AggregatePatchOp =
  | { op: "append"; element: AggregateElement }
  | { op: "update"; element_id: string; data: Record<string, unknown> }
  | { op: "remove"; element_id: string }
  | { op: "reorder"; order: string[] }
  | { op: "set_state"; state: "generating" | "done" }
  | { op: "set_segment"; segment: "first" | "middle" | "last" }
  | { op: "set_silent"; silent: boolean }

export class WanlingRestClient {
  private serverUrl: string
  private tokenProvider: () => Promise<string>
  private maxUploadBytes: number

  constructor(
    serverUrl: string,
    tokenProvider: () => Promise<string>,
    opts?: { maxUploadBytes?: number },
  ) {
    this.serverUrl = serverUrl.replace(/\/+$/, "")
    this.tokenProvider = tokenProvider
    // 上传上限默认对齐 server UPLOAD_MAX_BYTES(32MB),可由调用方收紧/放宽。
    this.maxUploadBytes = opts?.maxUploadBytes ?? 32 * 1024 * 1024
  }

  private apiUrl(p: string): string {
    return `${this.serverUrl}${p}`
  }

  private async request<T = Record<string, unknown>>(
    method: string,
    path: string,
    body?: unknown,
    timeoutMs = 10000,
  ): Promise<T> {
    const token = await this.tokenProvider()
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), timeoutMs)
    let resp: Response
    try {
      resp = await fetch(this.apiUrl(path), {
        method,
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${token}`,
        },
        ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
        signal: controller.signal,
      })
    } catch (err) {
      throw new ApiError(0, `request failed: ${err instanceof Error ? err.message : err}`)
    } finally {
      clearTimeout(timer)
    }
    if (!resp.ok) {
      throw new ApiError(resp.status, `HTTP ${resp.status}`)
    }
    return (await resp.json()) as T
  }

  private envelopeOk(resp: { ok?: boolean; data?: unknown }): void {
    if (!resp?.ok) {
      throw new ApiError(0, "envelope not ok")
    }
  }

  async sendCardMessage(
    convId: string,
    msgType: string,
    data: Record<string, unknown>,
    silent = true,
  ): Promise<string> {
    const content: MessageContent = { msg_type: msgType, data, silent }
    const resp = await this.request<{ ok: boolean; data?: { message_id: string } }>(
      "POST", `/api/conversations/${convId}/messages`, { content },
    )
    this.envelopeOk(resp)
    if (!resp.data?.message_id) throw new ApiError(0, "sendCardMessage: missing message_id")
    return resp.data.message_id
  }

  // 发起审批卡(approvals 状态机通道,含 allow_pattern 会话白名单)。
  // 对齐 server POST /api/conversations/:id/approvals(CreateApproval):
  // - card_type=slash_confirm 必带 confirm_id
  // - allow_pattern 仅 command 生效,命中白名单服务端返 auto_approved=true(不再发卡)
  // 响应 data 正常含 approval_id;白名单命中含 state/auto_approved/matched_pattern。
  async createApproval(convId: string, body: CreateApprovalBody): Promise<CreateApprovalResult> {
    const resp = await this.request<{ ok: boolean; data?: CreateApprovalResult }>(
      "POST", `/api/conversations/${convId}/approvals`, body,
    )
    this.envelopeOk(resp)
    return resp.data ?? {}
  }

  async updateMessageContent(msgId: string, content: MessageContent): Promise<void> {
    const resp = await this.request<{ ok: boolean }>("PATCH", `/api/messages/${msgId}`, { content })
    this.envelopeOk(resp)
  }

  // 聚合卡增量 PATCH(data.op 走 server applyContentOp 增量合并)。
  // 语义对齐 aggregate-card.md 的增量协议:
  // - append/update/remove/reorder 维护 elements
  // - set_state / set_segment / set_silent 改卡状态与 silent(翻转 false 触发未读+通知)
  async patchAggregateMessage(msgId: string, op: AggregatePatchOp): Promise<void> {
    const resp = await this.request<{ ok: boolean }>(
      "PATCH", `/api/messages/${msgId}`,
      { content: { msg_type: "aggregate_card", data: op as unknown as Record<string, unknown> } },
    )
    this.envelopeOk(resp)
  }

  async createGroupAsAgent(
    type: string,
    title: string,
    members: { userId: string; directory?: string },
  ): Promise<string> {
    const resp = await this.request<{ ok: boolean; data?: { id: string } }>(
      "POST", "/api/agents/me/conversations",
      {
        user_id: members.userId,
        type,
        title,
        ...(members.directory ? { directory: members.directory } : {}),
      },
    )
    this.envelopeOk(resp)
    if (!resp.data?.id) throw new ApiError(0, "createGroupAsAgent: missing id")
    return resp.data.id
  }

  async updateConversationTitle(convId: string, title: string): Promise<void> {
    const resp = await this.request<{ ok: boolean }>(
      "PATCH", `/api/agents/me/conversations/${convId}/title`, { title },
    )
    this.envelopeOk(resp)
  }

  async updateSessionMeta(convId: string, meta: SessionMeta): Promise<void> {
    const resp = await this.request<{ ok: boolean }>(
      "PATCH", `/api/agents/me/conversations/${convId}/session-meta`, meta,
    )
    this.envelopeOk(resp)
  }

  async uploadFile(filePath: string, convId?: string): Promise<string> {
    const size = statSync(filePath).size
    if (size > this.maxUploadBytes) {
      throw new ApiError(0, `upload: ${filePath} too large (${size} bytes > ${this.maxUploadBytes})`)
    }
    const token = await this.tokenProvider()
    const fd = new FormData()
    const buf = readFileSync(filePath)
    const name = filePath.split("/").pop() ?? "file"
    fd.append("file", new Blob([buf]), name)
    const query = convId ? `?conversation_id=${encodeURIComponent(convId)}` : ""
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), 30000)
    let resp: Response
    try {
      resp = await fetch(this.apiUrl(`/api/upload${query}`), {
        method: "POST",
        headers: { Authorization: `Bearer ${token}` },
        body: fd,
        signal: controller.signal,
      })
    } catch (err) {
      throw new ApiError(0, `request failed: ${err instanceof Error ? err.message : err}`)
    } finally {
      clearTimeout(timer)
    }
    if (!resp.ok) throw new ApiError(resp.status, `upload failed: HTTP ${resp.status}`)
    const json = (await resp.json()) as { ok: boolean; data?: { id: string } }
    this.envelopeOk(json)
    if (!json.data?.id) throw new ApiError(0, "upload: missing id")
    return json.data.id
  }

  async downloadFile(fileId: string): Promise<Buffer> {
    const token = await this.tokenProvider()
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), 30000)
    let resp: Response
    try {
      resp = await fetch(this.apiUrl(`/api/files/${fileId}`), {
        headers: { Authorization: `Bearer ${token}` },
        signal: controller.signal,
      })
    } catch (err) {
      throw new ApiError(0, `request failed: ${err instanceof Error ? err.message : err}`)
    } finally {
      clearTimeout(timer)
    }
    if (!resp.ok) throw new ApiError(resp.status, `download failed: HTTP ${resp.status}`)
    return Buffer.from(await resp.arrayBuffer())
  }
}
