import { readFileSync, statSync } from "node:fs"
import type { ApprovalMetaRow, MessageContent } from "./types.js"

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

export type ApprovalCardType = "command" | "tool" | "file" | "slash_confirm" | "question"

export type CreateApprovalBody = {
  card_type: ApprovalCardType
  title: string
  preview?: string
  preview_language?: string
  tool_name?: string
  file?: { id: string }
  meta?: ApprovalMetaRow[]
  session_key: string
  allow_pattern?: string
  confirm_id?: string
  timeout_sec?: number
  /** question 专用：选项列表 */
  options?: Array<{ id: string; label: string }>
  /** question 专用：是否多选 */
  multi_select?: boolean
}

export type CreateApprovalResult = {
  approval_id?: string
  state?: string
  auto_approved?: boolean
  matched_pattern?: string
}

/** GET /api/approvals/:id 的 data（model.Approval 子集，agent 侧只关心决议字段）。 */
export type ApprovalDetail = {
  state?: string
  decided_action?: string
  decided_by?: string
  decided_reason?: string
  decided_answers?: string[]
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

  // 发一条卡片消息(HTTP 通道,agent 视角)。
  //
  // ⚠️ silent 默认 true:静默、不计未读、不弹通知 —— 适合工具卡/过程消息。
  //    发普通文本回复请改用 client.sendTypedMessage(WS,默认非 silent)
  //    或本方法显式传 silent=false,否则 APP 端不响铃也不计未读。
  // 对齐 server POST /api/conversations/:id/messages(SendAsAgent)。
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

  // 撤回自己发的消息(scope=recall:全局软删,双向不可见;server 限 5 分钟内)。
  // 聚合卡空卡清理(aggregate_card recallEmpty)用,对齐 server
  // DELETE /api/messages/:id?scope=recall。
  async recallMessage(msgId: string): Promise<void> {
    const resp = await this.request<{ ok: boolean }>("DELETE", `/api/messages/${msgId}?scope=recall`, undefined)
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

  // 查审批详情（GET /api/approvals/:id，双角色鉴权）。
  // agent 断线重连错过 APPROVAL_DECIDED/EXPIRED 推送时主动查（Approvals.resync 用）。
  // question 决议含 decided_answers（option id 列表），其余类型该字段缺省。
  async getApproval(id: string): Promise<ApprovalDetail> {
    const resp = await this.request<{ ok: boolean; data?: ApprovalDetail }>(
      "GET", `/api/approvals/${id}`, undefined,
    )
    this.envelopeOk(resp)
    return resp.data ?? {}
  }

  // agent 视角列自己的会话（GET /api/agents/me/conversations，agentAuth）。
  // envelope data 直接是数组（server ListAsAgent 返 []model.Conversation）。
  // type 可选过滤（如 "agent_session"，SessionMapping 恢复映射用）。
  async listAgentConversations(type?: string): Promise<Array<{ id: string; type: string; title?: string }>> {
    const query = type ? `?type=${encodeURIComponent(type)}` : ""
    const resp = await this.request<{ ok: boolean; data?: Array<{ id: string; type: string; title?: string }> }>(
      "GET", `/api/agents/me/conversations${query}`, undefined,
    )
    this.envelopeOk(resp)
    return resp.data ?? []
  }

  // 列某 agent 的 agent_session 会话（GET /api/agents/:id/sessions）。
  // envelope data 直接是数组（server ListAgentSessions 返 []ConversationListItem，
  // 主键是会话 id，无独立 session_id 字段）。
  // ⚠️ server 该路由当前挂 userAuth（仅 user JWT 可调）；agent 侧对账请用
  // listAgentConversations("agent_session")。
  async listAgentSessions(agentId: string): Promise<Array<{ id: string; type: string; title?: string }>> {
    const resp = await this.request<{ ok: boolean; data?: Array<{ id: string; type: string; title?: string }> }>(
      "GET", `/api/agents/${agentId}/sessions`, undefined,
    )
    this.envelopeOk(resp)
    return resp.data ?? []
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
