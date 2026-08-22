import WebSocket from "ws"
import { EventEmitter } from "events"
import {
  OP_HELLO, OP_IDENTIFY, OP_HEARTBEAT, OP_HEARTBEAT_ACK,
  OP_DISPATCH, OP_RESUME, OP_RECONNECT,
  OP_PLUGIN_CALL, OP_PLUGIN_RESULT, OP_STREAM,
  EVENT_MESSAGE_CREATE, EVENT_MESSAGE_UPDATE, EVENT_MESSAGE_DELETE, EVENT_MESSAGE_READ,
  EVENT_TYPING_START, EVENT_GENERATION_ABORT,
  EVENT_CONVERSATION_UPDATE, EVENT_CONVERSATION_PARTICIPANT_JOIN,
  EVENT_CONVERSATION_PARTICIPANT_LEAVE, EVENT_SESSION_META_UPDATE,
  EVENT_AGENT_ONLINE, EVENT_AGENT_OFFLINE,
  EVENT_APPROVAL_DECIDED, EVENT_APPROVAL_EXPIRED,
  EVENT_AGENT_MODELS, EVENT_AGENT_SLASH_CATALOG, EVENT_PLUGIN_CAPABILITIES,
  EVENT_AGENT_MODES, EVENT_AGENT_PRESETS,
} from "./opcodes.js"
import type {
  WSMessage, HelloPayload, OutboundMessage,
} from "./types.js"
import { decodeJwtExp } from "./jwt.js"
import type { RPCDispatcher, JSONRPCRequest } from "./rpc.js"
import { WanlingRestClient } from "./rest.js"
import type { AggregatePatchOp, CreateApprovalBody } from "./rest.js"
import { Approvals } from "./approvals.js"
import { AggregateCard } from "./aggregate_card.js"
import type { AggregateCardOptions } from "./aggregate_card.js"
import { StreamSession } from "./stream_session.js"
import type { StreamSessionOptions } from "./stream_session.js"
import { SessionMapping } from "./session_mapping.js"
import type { SessionMappingOptions } from "./session_mapping.js"

export interface WanlingClientOptions {
  serverUrl: string
  agentId: string
  secretKey: string
  wsConnectTimeoutMs?: number
  requestTimeoutMs?: number
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
  // 可选 RPCDispatcher:注入后,handleMessage 收到 OpPluginCall 会路由到 dispatcher.dispatch,
  // 并把响应用 OpPluginResult 回发。未注入时 OpPluginCall 安全忽略(防止 plugin 未装 RPC 时崩溃)。
  private dispatcher: RPCDispatcher | null = null
  // REST 客户端:会话/消息/文件/审批等 HTTP 方法统一走 rest.ts,WS 只管转发与状态。
  rest: WanlingRestClient
  // 审批/提问高层封装(ask 发卡等决策)。构造时挂事件监听(this.on 不依赖 WS 状态,
  // 挂一次即可,重连不重复挂),断线重连后 resync 主动兜底未决项。
  approvals: Approvals

  constructor(opts: WanlingClientOptions) {
    super()
    this.opts = opts
    this.rest = new WanlingRestClient(opts.serverUrl, this.getToken.bind(this))
    this.approvals = new Approvals(
      (convId, body) => this.rest.createApproval(convId, body as CreateApprovalBody),
      (id) => this.rest.getApproval(id),
      (name, cb) => { this.on(name, cb) },
      (msg) => console.log(`[wanling] ${msg}`),
    )
  }

  // 注入 RPC 分发器(可选)。未注入时 OpPluginCall 会被安全忽略;
  // plugin 启动后可用 client.attachDispatcher(dispatcher) 挂上。
  attachDispatcher(dispatcher: RPCDispatcher): void {
    this.dispatcher = dispatcher
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
  // aggregate 定位(聚合模式卡内元素流式):帧不建独立占位,APP 定位
  // aggregate_card 消息内 element_id 匹配元素整体替换 data.text。
  // 与 sendTyping 一致:WS 未连接时 silently drop,不 emit error 不 warn
  // (流式为瞬态,终态消息兜底;agent 建会话期间短窗口掉帧可接受)。
  sendStream(
    convId: string,
    payload: { stream_id: string; msg_type: string; text: string; aggregate?: { message_id: string; element_id: string } },
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

  // 聚合卡工厂:一次问答一张卡(append/update/finish/interrupt)。
  // 建卡 silent=true(回合进行中不打扰,计未读由 finish 翻转 set_silent 承接)。
  aggregate(convId: string, opts?: AggregateCardOptions): AggregateCard {
    return new AggregateCard(convId, {
      sendCard: (data) => this.rest.sendCardMessage(convId, data.msg_type, data.data, true),
      patch: (messageId, op) => this.rest.patchAggregateMessage(messageId, op as AggregatePatchOp),
      updateContent: (messageId, content) => this.rest.updateMessageContent(messageId, content),
      recall: (messageId) => this.rest.recallMessage(messageId),
    }, opts)
  }

  // 流式会话工厂:首帧立即 + 节流 + 兜底 flush,终态消息由调用方带 _stream_id 发。
  stream(convId: string, opts?: StreamSessionOptions): StreamSession {
    return new StreamSession(convId, (cid, frame) => this.sendStream(cid, frame), opts)
  }

  // 会话映射工厂:外部 session ↔ conversation 持久映射(miss 时建 agent_session 群)。
  // ownerUserId 可在工厂注入或 ensureConversation 时传入(server 强制 user_id
  // 必须是 agent 的 owner,缺失时 fail fast 不发请求)。
  sessionMapping(opts: SessionMappingOptions & { ownerUserId?: string }): SessionMapping {
    const factoryOwner = opts.ownerUserId
    return new SessionMapping(opts.path, async (_sessionId, o) => {
      const ownerUserId = o.ownerUserId ?? factoryOwner
      if (!ownerUserId) {
        throw new Error("sessionMapping 需要 ownerUserId(工厂 opts 或 ensureConversation opts 提供)")
      }
      return this.rest.createGroupAsAgent("agent_session", o.title, {
        userId: ownerUserId,
        ...(o.directory !== undefined ? { directory: o.directory } : {}),
      })
    })
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
    console.log(`[wanling] sendAgentModels agent=${agentId.slice(0, 8)}… ${models.length} models`)
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
    console.log(`[wanling] sendAgentSlashCatalog agent=${agentId.slice(0, 8)}… ${commands.length} commands`)
  }

  // plugin 启动/重连时上报该 agent 的模式清单(能力上报管线第四成员)。
  // server 写 ModeRegistry 内存缓存,APP 渲染模式色条按 session-meta mode
  // id 查清单取 label/style(不再硬编码各平台枚举)。
  // style 为受控渲染档位: "default" | "plan" | "warn"。
  // 与 sendAgentModels 一致:WS 未连接时 silently drop + console.warn。
  sendAgentModes(agentId: string, modes: Array<{
    id: string
    label: string
    style: "default" | "plan" | "warn"
  }>): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      console.warn("[wanling] sendAgentModes: WS 未连接,跳过")
      return
    }
    const payload: WSMessage = {
      op: OP_DISPATCH,
      t: EVENT_AGENT_MODES,
      d: { agent_id: agentId, modes, reported_at: new Date().toISOString() },
    }
    this.ws.send(JSON.stringify(payload))
    console.log(`[wanling] sendAgentModes agent=${agentId.slice(0, 8)}… ${modes.length} modes`)
  }

  // plugin 启动/重连时上报该 agent 的预设清单(能力上报管线第五成员)。
  // 预设是 per-session 能力组合(dsh 等),集合开放(user 可自创)。
  // server 写 PresetRegistry 内存缓存,APP 新建会话选择器数据源。
  // trust 区分 "system"(部署内置)/"user"(用户自创);无预设概念的
  // plugin 不调用本方法即可(APP 据空清单隐藏选择步骤)。
  sendAgentPresets(agentId: string, presets: Array<{
    id: string
    label: string
    description?: string
    trust: "system" | "user"
    order?: number
  }>): void {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) {
      console.warn("[wanling] sendAgentPresets: WS 未连接,跳过")
      return
    }
    const payload: WSMessage = {
      op: OP_DISPATCH,
      t: EVENT_AGENT_PRESETS,
      d: { agent_id: agentId, presets, reported_at: new Date().toISOString() },
    }
    this.ws.send(JSON.stringify(payload))
    console.log(`[wanling] sendAgentPresets agent=${agentId.slice(0, 8)}… ${presets.length} presets`)
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
    console.log(`[wanling] sendPluginCapabilities agent=${agentId.slice(0, 8)}… ${methods.length} methods`)
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
      console.log("[wanling] token 已刷新")
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
    console.log(`[wanling] token 刷新已计划: ${Math.round(delay / 1000 / 60)}min 后`)
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
        // 重连后未决审批可能错过 WS 推送，REST 兜底查询一次（首次连接 pending 为空，空跑无害）。
        void this.approvals.resync()
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

    try {
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
    } catch (err) {
      // 握手阶段失败(连接超时 / 收 Hello 超时 / Hello 校验失败)时关闭底层连接,
      // 避免 ws 局部变量失去引用后悬挂连接累积(agent 常驻反复握手失败场景)。
      try { ws.close() } catch { /* 连接已断，忽略 */ }
      throw err
    }
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
        const d = msg.d as unknown as Record<string, unknown>
        if (t === EVENT_MESSAGE_CREATE) this.emit("message", d)
        else if (t === EVENT_MESSAGE_UPDATE) this.emit("message.update", d)
        else if (t === EVENT_MESSAGE_DELETE) this.emit("message.delete", d)
        else if (t === EVENT_MESSAGE_READ) this.emit("message.read", d)
        else if (t === EVENT_TYPING_START) this.emit("typing", d)
        else if (t === EVENT_GENERATION_ABORT) this.emit("abort", d)
        else if (t === EVENT_CONVERSATION_UPDATE) this.emit("conv_update", d)
        else if (t === EVENT_CONVERSATION_PARTICIPANT_JOIN) this.emit("conv.participant.join", d)
        else if (t === EVENT_CONVERSATION_PARTICIPANT_LEAVE) this.emit("conv.participant.leave", d)
        else if (t === EVENT_SESSION_META_UPDATE) this.emit("session.meta.update", d)
        else if (t === EVENT_AGENT_ONLINE) this.emit("agent.online", d)
        else if (t === EVENT_AGENT_OFFLINE) this.emit("agent.offline", d)
        else if (t === EVENT_APPROVAL_DECIDED) this.emit("approval.decided", d)
        else if (t === EVENT_APPROVAL_EXPIRED) this.emit("approval.expired", d)
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
          // "dispatch 异常" 误导日志(Task 7 review MINOR)。
          if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return
          const out: WSMessage = { op: OP_PLUGIN_RESULT, d: resp as Record<string, unknown> }
          this.ws.send(JSON.stringify(out))
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
