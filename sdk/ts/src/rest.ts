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

export class WanlingRestClient {
  private serverUrl: string
  private tokenProvider: () => Promise<string>

  constructor(serverUrl: string, tokenProvider: () => Promise<string>) {
    this.serverUrl = serverUrl.replace(/\/+$/, "")
    this.tokenProvider = tokenProvider
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

  async updateMessageContent(msgId: string, content: MessageContent): Promise<void> {
    const resp = await this.request<{ ok: boolean }>("PATCH", `/api/messages/${msgId}`, { content })
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
    if (size > 20 * 1024 * 1024) {
      throw new ApiError(0, `upload: ${filePath} too large (${size} bytes > 20MB)`)
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
