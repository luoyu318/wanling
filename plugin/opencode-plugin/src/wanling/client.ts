import WebSocket from "ws"
import { EventEmitter } from "events"
import {
  OP_HELLO, OP_IDENTIFY, OP_HEARTBEAT, OP_HEARTBEAT_ACK,
  OP_DISPATCH, OP_RESUME, OP_RECONNECT,
  OP_PLUGIN_CALL, OP_PLUGIN_RESULT, OP_STREAM,
  EVENT_MESSAGE_CREATE, EVENT_TYPING_START, EVENT_GENERATION_ABORT,
  EVENT_CONVERSATION_UPDATE, EVENT_AGENT_MODELS, EVENT_AGENT_SLASH_CATALOG,
  EVENT_PLUGIN_CAPABILITIES,
} from "./opcodes.js"
import type {
  WSMessage, HelloPayload, MessageCreatePayload,
  TypingStartPayload, GenerationAbortPayload, ConvUpdatePayload,
  OutboundMessage,
} from "./types.js"
import { decodeJwtExp } from "./jwt.js"
import { logger } from "../utils/logger.js"
import type { RPCDispatcher, JSONRPCRequest } from "../rpc/dispatcher.js"
import type { AggregatePatchData } from "../sync/domains/aggregate_card.js"

export interface WanlingClientOptions {
  serverUrl: string
  agentId: string
  secretKey: string
  wsConnectTimeoutMs?: number
  requestTimeoutMs?: number
  // 可选 RPCDispatcher:注入后,handleMessage 收到 OpPluginCall 会路由到 dispatcher.dispatch,
  // 并把响应用 OpPluginResult 回发。未注入时 OpPluginCall 安全忽略(防止 plugin 未装 RPC 时崩溃)。
  dispatcher?: RPCDispatcher
}

function wsUrl(httpUrl: string): string {
  const base = httpUrl.replace(/\/+$/, "")
  if (base.startsWith("https://")) {
    return base.replace("https://", "wss://") + "/ws"
  }
  return base.replace("http://", "ws://") + "/ws"
}

interface RetryState {
  backoff: number
  lastSeq: number
  stopping: boolean
}

export class WanlingClient extends EventEmitter {
  private ws: WebSocket | null = null
  private opts: WanlingClientOptions
  private token: string | null = null
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null
  private retry: RetryState = { backoff: 1, lastSeq: 0, stopping: false }
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null
  private refreshTimer: ReturnType<typeof setTimeout> | null = null
  private tokenRefreshPromise: Promise<void> | null = null
  private lastIdentifyAt: number = 0
  private dispatcher?: RPCDispatcher

  constructor(opts: WanlingClientOptions) {
    super()
    this.opts = opts
    this.dispatcher = opts.dispatcher
  }

  // agentId 只读访问器:Streamer 上报 AGENT_MODELS 时读取,
  // 避免在 Streamer 构造函数再加一份 agentId 副本(单一来源 = this.opts.agentId)。
  get agentId(): string {
    return this.opts.agentId
  }

  // downloader 用:GET /api/files/:id 需要 agent JWT。
  // 不暴露 token 字段本身(避免外部代码篡改),只给异步 getter。
  // 未连接时 fail fast,不吞错。
  async getToken(): Promise<string> {
    if (!this.token) throw new Error("client not connected")
    return this.token
  }

  async connect(): Promise<void> {
    if (!this.opts.agentId || !this.opts.secretKey) {
      throw new Error("agentId and secretKey must be configured")
    }
    this.retry.stopping = false

    try {
      this.token = await this.exchangeToken()
    } catch (err) {
      this.emit("fatal", "token_exchange_failed", String(err))
      throw err
    }

    this.scheduleTokenRefresh()
    void this.runReceiveLoop()
  }

  disconnect(): void {
    this.retry.stopping = true
    this.clearReconnectTimer()
    if (this.refreshTimer) {
      clearTimeout(this.refreshTimer)
      this.refreshTimer = null
    }
    this.tokenRefreshPromise = null
    this.clearHeartbeat()
    if (this.ws) {
      try { this.ws.close() } catch { /* 连接已断，忽略 */ }
      this.ws = null
    }
  }

  sendMessage(msg: OutboundMessage): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      this.emit("error", new Error("WS not connected"))
      return
    }
    const payload: WSMessage = {
      op: OP_DISPATCH,
      t: EVENT_MESSAGE_CREATE,
      d: msg as unknown as Record<string, unknown>,
    }
    this.ws.send(JSON.stringify(payload))
  }

  sendTypedMessage(
    convId: string,
    msgType: string,
    data: Record<string, unknown>,
    options?: { silent?: boolean; parentMsgId?: string; rootMsgId?: string },
  ): void {
    const content = {
      msg_type: msgType,
      data,
      ...(options?.silent ? { silent: true } : {}),
      ...(options?.parentMsgId ? { parent_msg_id: options.parentMsgId } : {}),
      ...(options?.rootMsgId ? { root_msg_id: options.rootMsgId } : {}),
    }
    this.sendMessage({ conversation_id: convId, content })
  }

  // 流式输出:把生成中的文本全量快照推给"正在看本会话"的 user 连接。
  // op=14 绕过 dispatchBuffer/Resume,不带 seq、不落库、不计未读。
  // 终态仍由 sendTypedMessage 发 MESSAGE_CREATE(带 _stream_id 让 APP 替换占位)。
  // aggregate(聚合模式):指向聚合卡内某元素(element_id),APP 把流式内容渲染到该元素,
  // 不建独立流式占位气泡;无 aggregate 字段 = 非聚合模式,APP 走旧独立占位逻辑。
  // 与 sendTyping 一致:WS 未连接时 silently drop,不 emit error 不 warn
  // (流式为瞬态,终态消息兜底;agent 建会话期间短窗口掉帧可接受)。
  sendStream(
    convId: string,
    payload: {
      stream_id: string
      msg_type: string
      text: string
      aggregate?: { message_id: string; element_id: string }
    },
  ): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      return
    }
    const frame: WSMessage = {
      op: OP_STREAM,
      d: { conversation_id: convId, ...payload },
    }
    this.ws.send(JSON.stringify(frame))
  }

  sendTyping(convId: string): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return
    const payload: WSMessage = {
      op: OP_DISPATCH,
      t: EVENT_TYPING_START,
      d: { conversation_id: convId },
    }
    this.ws.send(JSON.stringify(payload))
  }

  sendSessionStatus(
    convId: string,
    status: string,
    extra?: { attempt?: number; message?: string },
  ): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return
    const d: Record<string, unknown> = { conversation_id: convId, status }
    if (extra?.attempt !== undefined) d.attempt = extra.attempt
    if (extra?.message) d.message = extra.message
    const payload: WSMessage = {
      op: OP_DISPATCH,
      t: "SESSION_STATUS",
      d,
    }
    this.ws.send(JSON.stringify(payload))
    logger.info(`[wanling] sendSessionStatus conv=${convId.slice(0, 8)}… status=${status}`)
  }

  // 上报 agent 可选模型清单(plugin 启动/重连时拉 opencode providers)。
  // server 收到后写 AgentRegistry 内存缓存,APP 通过 GET /api/agents/:id/models 拉取。
  // 与 sendTypedMessage 一致:WS 未连接时 silently drop + console.warn,
  // 不抛错(下次连上 loadProviderNames 重报)。
  sendAgentModels(agentId: string, models: Array<{
    provider_id: string
    provider_name: string
    model_id: string
    model_name: string
  }>): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      console.warn("[wanling] sendAgentModels: WS 未连接,跳过")
      return
    }
    const payload: WSMessage = {
      op: OP_DISPATCH,
      t: EVENT_AGENT_MODELS,
      d: { agent_id: agentId, models, reported_at: new Date().toISOString() },
    }
    this.ws.send(JSON.stringify(payload))
    logger.info(`[wanling] sendAgentModels agent=${agentId.slice(0, 8)}… ${models.length} models`)
  }

  // plugin 启动/重连时上报该 agent 的命令清单(OC command.list 拉取结果)。
  // server 收到后写 SlashCatalogRegistry 内存缓存,APP 通过 GET /api/agents/:id/slash-catalog 拉取。
  // 与 sendAgentModels 一致:WS 未连接时 silently drop + console.warn,
  // 不抛错(下次连上 loadSlashCatalog 重报)。
  sendAgentSlashCatalog(agentId: string, commands: Array<{
    name: string
    template: string
    description?: string
    source: string  // "command" | "skill"
  }>): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      console.warn("[wanling] sendAgentSlashCatalog: WS 未连接,跳过")
      return
    }
    const payload: WSMessage = {
      op: OP_DISPATCH,
      t: EVENT_AGENT_SLASH_CATALOG,
      d: { agent_id: agentId, commands, reported_at: new Date().toISOString() },
    }
    this.ws.send(JSON.stringify(payload))
    logger.info(`[wanling] sendAgentSlashCatalog agent=${agentId.slice(0, 8)}… ${commands.length} commands`)
  }

  // plugin 启动/重连时上报 RPC 方法清单(dispatcher.listMethods() 结果)。
  // server 收到后写 CapabilityRegistry 内存缓存,APP 通过 GET /api/agents/:id/rpc-methods 拉取。
  // 与 sendAgentModels / sendAgentSlashCatalog 一致:WS 未连接时 silently drop + console.warn,
  // 不抛错(下次连上 streamer.start 重报)。
  sendPluginCapabilities(
    agentId: string,
    methods: Array<{ name: string; timeout_hint_ms: number }>,
  ): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      console.warn("[wanling] sendPluginCapabilities: WS 未连接,跳过")
      return
    }
    const payload: WSMessage = {
      op: OP_DISPATCH,
      t: EVENT_PLUGIN_CAPABILITIES,
      d: { agent_id: agentId, methods, reported_at: new Date().toISOString() },
    }
    this.ws.send(JSON.stringify(payload))
    logger.info(`[wanling] sendPluginCapabilities agent=${agentId.slice(0, 8)}… ${methods.length} methods`)
  }

  private apiUrl(p: string): string {
    return `${this.opts.serverUrl.replace(/\/+$/, "")}${p}`
  }

  private async exchangeToken(): Promise<string> {
    const url = this.apiUrl(`/api/agents/${this.opts.agentId}/token`)
    const body = JSON.stringify({
      agent_id: this.opts.agentId,
      secret_key: this.opts.secretKey,
    })
    const controller = new AbortController()
    const timeoutMs = this.opts.requestTimeoutMs ?? 10000
    const timer = setTimeout(() => controller.abort(), timeoutMs)
    let resp: Response
    try {
      resp = await fetch(url, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body,
        signal: controller.signal,
      })
    } catch (err) {
      throw new Error(`token exchange failed: ${err instanceof Error ? err.message : err}`)
    } finally {
      clearTimeout(timer)
    }
    if (!resp.ok) {
      throw new Error(`token exchange failed: ${resp.status}`)
    }
    const data = await resp.json()
    if (!data.ok || !data.data?.token) {
      throw new Error("token exchange: invalid response")
    }
    return data.data.token
  }

  private async refreshToken(): Promise<void> {
    try {
      const newToken = await this.exchangeToken()
      this.token = newToken
      logger.info("[wanling] token 已刷新")
      this.scheduleTokenRefresh()
    } catch (err) {
      this.emit("fatal", "token_refresh_failed", String(err))
      throw err
    }
  }

  private scheduleTokenRefresh(): void {
    if (this.refreshTimer) {
      clearTimeout(this.refreshTimer)
      this.refreshTimer = null
    }
    if (!this.token) return
    const exp = decodeJwtExp(this.token)
    if (!exp) return
    const expMs = exp * 1000
    const refreshAt = expMs - 3600 * 1000 // 提前 1h
    const rawDelay = refreshAt - Date.now()
    if (rawDelay <= 0) {
      this.refreshToken().catch(() => {})
      return
    }
    // Node.js setTimeout delay 上限 2^31-1 ms（约 24.8 天），超过会变成 1ms 导致死循环
    const MAX_TIMER_DELAY = 2147483647
    const delay = Math.min(rawDelay, MAX_TIMER_DELAY)
    this.refreshTimer = setTimeout(() => {
      this.refreshToken().catch((err) => {
        console.error(`[wanling] 主动 token 刷新失败: ${err}`)
      })
    }, delay)
    logger.info(`[wanling] token 刷新已计划: ${Math.round(delay / 1000 / 60)}min 后`)
  }

  async sendCardMessage(
    convId: string,
    msgType: string,
    data: Record<string, unknown>,
    options?: { silent?: boolean; parentMsgId?: string; rootMsgId?: string },
  ): Promise<string> {
    const silent = options?.silent ?? true
    const content: Record<string, unknown> = { msg_type: msgType, data, silent }
    if (options?.parentMsgId) content.parent_msg_id = options.parentMsgId
    if (options?.rootMsgId) content.root_msg_id = options.rootMsgId
    const resp = await fetch(this.apiUrl(`/api/conversations/${convId}/messages`), {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(this.token ? { Authorization: `Bearer ${this.token}` } : {}),
      },
      body: JSON.stringify({ content }),
    })
    if (!resp.ok) {
      throw new Error(`sendCardMessage failed: ${resp.status}`)
    }
    const json = await resp.json()
    if (!json.ok || !json.data?.message_id) {
      throw new Error("sendCardMessage: invalid response")
    }
    return json.data.message_id as string
  }

  // 聚合卡 PATCH:复用 updateMessageContent 的 REST PATCH 通道。
  // data 带 op(append/update/remove/reorder/set_state/set_silent)→ 增量 op,
  // server 合并到全量存储、广播带增量(长任务不再全量替换,解决 content 超限 + O(n²))。
  // data 无 op 带 elements → 全量替换兼容路径(旧 plugin / 建卡兜底)。
  // silent 翻转走 data {op:"set_silent"}(不再放 content 顶层)。
  async patchAggregateMessage(
    msgId: string,
    data: AggregatePatchData,
  ): Promise<void> {
    const content: Record<string, unknown> = {
      msg_type: "aggregate_card",
      data,
    }
    await this.updateMessageContent(msgId, content as { msg_type: string; data: Record<string, unknown> })
  }

  async updateMessageContent(
    msgId: string,
    content: { msg_type: string; data: Record<string, unknown>; silent?: boolean },
  ): Promise<void> {
    const resp = await fetch(this.apiUrl(`/api/messages/${msgId}`), {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        ...(this.token ? { Authorization: `Bearer ${this.token}` } : {}),
      },
      body: JSON.stringify({ content }),
    })
    if (!resp.ok) {
      throw new Error(`updateMessageContent failed: ${resp.status}`)
    }
    const json = await resp.json()
    if (!json.ok) {
      throw new Error("updateMessageContent: invalid response")
    }
  }

  // agent 视角建会话(POST /api/agents/me/conversations),用于为主 session 建对应群
  // directory: OC session 工作目录,透传到 server conversations.directory 一级列(TUI 场景必走)
  async createGroupAsAgent(
    type: string,
    title: string,
    members: { userId: string; directory?: string },
  ): Promise<string> {
    const resp = await fetch(this.apiUrl(`/api/agents/me/conversations`), {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        ...(this.token ? { Authorization: `Bearer ${this.token}` } : {}),
      },
      body: JSON.stringify({
        user_id: members.userId,
        type,
        title,
        ...(members.directory ? { directory: members.directory } : {}),
      }),
    })
    if (!resp.ok) {
      throw new Error(`createGroupAsAgent failed: ${resp.status}`)
    }
    const json = await resp.json()
    if (!json.ok || !json.data?.id) {
      throw new Error("createGroupAsAgent: invalid response")
    }
    return json.data.id as string
  }

  // 改会话名(agent 视角 PATCH /api/agents/me/conversations/:id/title)。
  // 走 agentAuth 组,plugin 持 agent JWT 可直接调,不再 403。
  async updateConversationTitle(convId: string, title: string): Promise<void> {
    const resp = await fetch(this.apiUrl(`/api/agents/me/conversations/${convId}/title`), {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        ...(this.token ? { Authorization: `Bearer ${this.token}` } : {}),
      },
      body: JSON.stringify({ title }),
    })
    if (!resp.ok) {
      throw new Error(`updateConversationTitle failed: ${resp.status}`)
    }
  }

  // 更新 agent_session 元数据(agent 视角 PATCH /api/agents/me/conversations/:id/session-meta)。
  // session.updated 事件触发:mode/model/variant 变化时同步到 server,
  // APP 从 conversation API 读取渲染副标题。
  // 注意:cwd 字段已彻底剔除(升级到 conversations.directory 一级列)。
  async updateSessionMeta(
    convId: string,
    meta: {
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
    },
  ): Promise<void> {
    const resp = await fetch(this.apiUrl(`/api/agents/me/conversations/${convId}/session-meta`), {
      method: "PATCH",
      headers: {
        "Content-Type": "application/json",
        ...(this.token ? { Authorization: `Bearer ${this.token}` } : {}),
      },
      body: JSON.stringify(meta),
    })
    if (!resp.ok) {
      throw new Error(`updateSessionMeta failed: ${resp.status}`)
    }
  }

  private async runReceiveLoop(): Promise<void> {
    while (!this.retry.stopping) {
      try {
        if (this.tokenRefreshPromise) {
          await this.tokenRefreshPromise
          this.tokenRefreshPromise = null
        }
        this.ws = await this.establishWS()
        this.retry.backoff = 1
        this.emit("connected")
        await this.receiveLoop()
      } catch {
        if (this.retry.stopping) return
        this.emit("disconnected")
        this.cleanupWS()
        const jitter = this.retry.backoff * 0.2 * Math.random()
        const delay = this.retry.backoff + jitter
        this.emit("reconnecting", { delay, attempt: this.retry.backoff })
        await new Promise((r) => { this.reconnectTimer = setTimeout(r, delay * 1000) })
        this.retry.backoff = Math.min(this.retry.backoff * 2, 30)
      }
    }
  }

  private async establishWS(): Promise<WebSocket> {
    const url = wsUrl(this.opts.serverUrl)
    const ws = new WebSocket(url)

    ws.on("error", () => {})

    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => {
        reject(new Error("WS connect timeout"))
      }, this.opts.wsConnectTimeoutMs ?? 15000)
      ws.once("open", () => {
        clearTimeout(timeout)
        resolve()
      })
      ws.once("error", (err) => {
        clearTimeout(timeout)
        reject(err)
      })
    })

    const helloStr = await this.waitForMessage(ws, 10000)
    const hello: WSMessage = JSON.parse(helloStr)
    if (hello.op !== OP_HELLO) {
      throw new Error(`expected Hello (op=10), got op=${hello.op}`)
    }
    const helloPayload = hello.d as unknown as HelloPayload
    if (!helloPayload || typeof helloPayload.heartbeat_interval !== "number") {
      throw new Error(`invalid hello payload: missing heartbeat_interval (d=${JSON.stringify(hello.d)})`)
    }
    const heartbeatInterval = helloPayload.heartbeat_interval || 30000

    const identify: WSMessage = { op: OP_IDENTIFY, d: { token: this.token } }
    ws.send(JSON.stringify(identify))
    this.lastIdentifyAt = Date.now()

    if (this.retry.lastSeq > 0) {
      const resume: WSMessage = { op: OP_RESUME, d: { last_seq: this.retry.lastSeq } }
      ws.send(JSON.stringify(resume))
    }

    this.startHeartbeat(ws, heartbeatInterval)

    return ws
  }

  private async receiveLoop(): Promise<void> {
    if (!this.ws) return
    for await (const raw of iterateWebSocket(this.ws)) {
      if (this.retry.stopping) return
      try {
        const msg: WSMessage = JSON.parse(raw)
        this.handleMessage(msg)
      } catch { /* 单条消息处理失败不阻断接收循环 */ }
    }
    throw new Error("WS closed by peer")
  }

  private handleMessage(msg: WSMessage): void {
    switch (msg.op) {
      case OP_HEARTBEAT_ACK:
        break

      case OP_RECONNECT: {
        const sinceIdentify = Date.now() - this.lastIdentifyAt
        this.emit("reconnect_requested")
        if (sinceIdentify < 5000 && this.token) {
          console.warn(`[wanling] OP_RECONNECT 在 IDENTIFY 后 ${sinceIdentify}ms，疑似 token 过期，刷新后重连`)
          this.tokenRefreshPromise = this.refreshToken().catch((err) => {
            console.error(`[wanling] 被动 token 刷新失败: ${err}`)
          })
        }
        if (this.ws) {
          try { this.ws.close() } catch { /* 连接已断，忽略 */ }
        }
        break
      }

      case OP_DISPATCH: {
        if (typeof msg.s === "number" && msg.s > this.retry.lastSeq) {
          this.retry.lastSeq = msg.s
        }
        const t = msg.t
        if (t === EVENT_MESSAGE_CREATE) {
          const payload = msg.d as unknown as MessageCreatePayload
          this.emit("message", payload)
        } else if (t === EVENT_TYPING_START) {
          const payload = msg.d as unknown as TypingStartPayload
          this.emit("typing", payload)
        } else if (t === EVENT_GENERATION_ABORT) {
          const payload = msg.d as unknown as GenerationAbortPayload
          this.emit("abort", payload)
        } else if (t === EVENT_CONVERSATION_UPDATE) {
          const payload = msg.d as unknown as ConvUpdatePayload
          this.emit("conv_update", payload)
        }
        break
      }

      case OP_PLUGIN_CALL: {
        if (!this.dispatcher) {
          console.warn("[wanling] OpPluginCall 收到但无 dispatcher 注册,忽略")
          break
        }
        const call = msg.d as unknown as JSONRPCRequest
        this.dispatcher.dispatch(call).then((resp) => {
          // 与 sendTypedMessage / sendAgentModels 等 5 处 send 路径同模式:
          // 只在 WS OPEN 时发,避免 CLOSING/CLOSED 状态 ws.send 同步抛错被 catch 吞成
          // "dispatch 异常" 误导日志。
          if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return
          const out: WSMessage = { op: OP_PLUGIN_RESULT, d: resp as Record<string, unknown> }
          const frame = JSON.stringify(out)
          // 发送侧帧体积警告:server WS 帧上限 512KB,超 400KB 先预警(留缓冲)。
          // 便于定位 session.diff 等大 payload 方法(数据侧截断防护见 git/diff.ts)。
          // frame.length 是 UTF-16 字符数,须用 Buffer.byteLength 取真实字节数比较。
          const frameBytes = Buffer.byteLength(frame)
          if (frameBytes > 400 * 1024) {
            logger.warn(`[wanling] RPC 响应超大: method=${call.method} bytes=${frameBytes}(server 帧上限 512KB,可能被断连)`)
          }
          this.ws.send(frame)
        }).catch((err) => {
          // dispatcher.dispatch 内部已对 handler 抛错做了 try/catch 并返回 error 响应,
          // 走到这里说明 dispatch 自身有 bug(或 ws.send 同步抛错),记录后吞掉,
          // 不让单条 RPC 异常打断 receiveLoop。
          console.error(`[wanling] OpPluginCall dispatch 异常: ${err}`)
        })
        break
      }

      default:
        break
    }
  }

  private startHeartbeat(ws: WebSocket, intervalMs: number): void {
    this.clearHeartbeat()
    this.heartbeatTimer = setInterval(() => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ op: OP_HEARTBEAT }))
      }
    }, intervalMs)
  }

  private clearHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer)
      this.heartbeatTimer = null
    }
  }

  private clearReconnectTimer(): void {
    if (this.reconnectTimer) {
      clearTimeout(this.reconnectTimer)
      this.reconnectTimer = null
    }
  }

  private cleanupWS(): void {
    this.clearHeartbeat()
    if (this.ws) {
      try { this.ws.close() } catch { /* 连接已断，忽略 */ }
      this.ws = null
    }
  }

  private waitForMessage(ws: WebSocket, timeoutMs: number): Promise<string> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        reject(new Error("waitForMessage timeout"))
      }, timeoutMs)
      const onMsg = (data: Buffer | string) => {
        clearTimeout(timer)
        ws.removeListener("message", onMsg)
        resolve(data.toString())
      }
      const onErr = (err: Error) => {
        clearTimeout(timer)
        ws.removeListener("error", onErr)
        reject(err)
      }
      ws.on("message", onMsg)
      ws.on("error", onErr)
    })
  }
}

async function* iterateWebSocket(ws: WebSocket): AsyncGenerator<string> {
  let resolve: ((value: string) => void) | null = null
  let reject: ((err: Error) => void) | null = null

  const onMessage = (data: Buffer | string) => {
    if (resolve) {
      resolve(data.toString())
      resolve = null
    }
  }
  const onError = (err: Error) => {
    if (reject) {
      reject(err)
      reject = null
    }
  }
  const onClose = () => {
    if (reject) {
      reject(new Error("WS closed"))
      reject = null
    }
  }

  ws.on("message", onMessage)
  ws.on("error", onError)
  ws.on("close", onClose)

  try {
    while (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING) {
      const data = await new Promise<string>((res, rej) => {
        resolve = res
        reject = rej
      })
      yield data
    }
  } finally {
    ws.removeListener("message", onMessage)
    ws.removeListener("error", onError)
    ws.removeListener("close", onClose)
  }
}
