import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { WanlingClient, WanlingClientOptions } from "./client.js"
import { RPCDispatcher } from "../rpc/dispatcher.js"

// 不真正连 WS，只测 token 刷新的内部逻辑
describe("WanlingClient token 刷新", () => {
  let client: WanlingClient
  let fetchSpy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    client = new WanlingClient({
      serverUrl: "http://localhost:18008",
      agentId: "agent-1",
      secretKey: "secret",
    })
    fetchSpy = vi.spyOn(globalThis, "fetch")
  })

  afterEach(() => {
    if (client) client.disconnect()
    vi.restoreAllMocks()
  })

  it("connect() 调用 exchangeToken 获取初始 token", async () => {
    const token = makeJwt(Math.floor(Date.now() / 1000) + 3600)
    fetchSpy.mockResolvedValue(
      new Response(JSON.stringify({ ok: true, data: { token } }), { status: 200 }),
    )
    // 阻止真正进 runReceiveLoop（WS 会失败）
    const connectSpy = vi.spyOn(client as any, "runReceiveLoop").mockResolvedValue(undefined)

    await client.connect()

    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining("/api/agents/agent-1/token"),
      expect.objectContaining({ method: "POST" }),
    )
    expect((client as any).token).toBe(token)
    connectSpy.mockRestore()
  })

  it("token 过期时 refreshToken 获取新 token", async () => {
    const oldToken = makeJwt(Math.floor(Date.now() / 1000) - 100)
    const newToken = makeJwt(Math.floor(Date.now() / 1000) + 7200)
    ;(client as any).token = oldToken

    // 第 1 次 fetch = exchangeToken 返回 newToken
    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify({ ok: true, data: { token: newToken } }), { status: 200 }),
    )

    await (client as any).refreshToken()

    expect((client as any).token).toBe(newToken)
  })

  it("refreshToken 失败时 emit fatal 并 throw", async () => {
    ;(client as any).token = "old"
    fetchSpy.mockRejectedValueOnce(new Error("network down"))

    const fatalSpy = vi.fn()
    client.on("fatal", fatalSpy)

    await expect((client as any).refreshToken()).rejects.toThrow("network down")
    expect(fatalSpy).toHaveBeenCalled()
  })

  it("OP_RECONNECT 在 IDENTIFY 后 <5s 触发被动 token 刷新", async () => {
    const oldToken = makeJwt(Math.floor(Date.now() / 1000) + 7200)
    const newToken = makeJwt(Math.floor(Date.now() / 1000) + 14400)
    ;(client as any).token = oldToken
    ;(client as any).lastIdentifyAt = Date.now()

    fetchSpy.mockResolvedValueOnce(
      new Response(JSON.stringify({ ok: true, data: { token: newToken } }), { status: 200 }),
    )

    ;(client as any).handleMessage({ op: 7 }) // OP_RECONNECT = 7

    // Wait for the async refreshToken to complete
    await new Promise((r) => setTimeout(r, 50))

    expect((client as any).token).toBe(newToken)
    expect((client as any).tokenRefreshPromise).not.toBeNull()
    // The promise should resolve (not reject)
    await (client as any).tokenRefreshPromise
  })

  it("OP_RECONNECT 在 IDENTIFY 后 >5s 不触发被动刷新", async () => {
    ;(client as any).token = makeJwt(Math.floor(Date.now() / 1000) + 7200)
    ;(client as any).lastIdentifyAt = Date.now() - 10000 // 10s ago

    ;(client as any).handleMessage({ op: 7 })

    expect((client as any).tokenRefreshPromise).toBeNull()
    expect(fetchSpy).not.toHaveBeenCalled()
  })
})

describe("WanlingClient sendSessionStatus", () => {
  let client: WanlingClient

  afterEach(() => {
    if (client) client.disconnect()
  })

  it("发出 SESSION_STATUS WS payload(busy)", () => {
    client = new WanlingClient({
      serverUrl: "http://localhost:18008",
      agentId: "agent-1",
      secretKey: "secret",
    })
    // 注入 mock ws
    const sent: string[] = []
    ;(client as any).ws = { readyState: 1, send: (s: string) => sent.push(s) }

    ;(client as any).sendSessionStatus("conv-1", "busy")

    expect(sent).toHaveLength(1)
    const parsed = JSON.parse(sent[0])
    expect(parsed.op).toBe(0) // OP_DISPATCH
    expect(parsed.t).toBe("SESSION_STATUS")
    expect(parsed.d.conversation_id).toBe("conv-1")
    expect(parsed.d.status).toBe("busy")
  })

  it("发出 SESSION_STATUS WS payload(retry 带 attempt/message)", () => {
    client = new WanlingClient({
      serverUrl: "http://localhost:18008",
      agentId: "agent-1",
      secretKey: "secret",
    })
    const sent: string[] = []
    ;(client as any).ws = { readyState: 1, send: (s: string) => sent.push(s) }

    ;(client as any).sendSessionStatus("conv-1", "retry", {
      attempt: 3,
      message: "rate limit exceeded",
    })

    const parsed = JSON.parse(sent[0])
    expect(parsed.d.status).toBe("retry")
    expect(parsed.d.attempt).toBe(3)
    expect(parsed.d.message).toBe("rate limit exceeded")
  })
})

describe("WanlingClient conv_update 事件", () => {
  let client: WanlingClient

  afterEach(() => {
    if (client) client.disconnect()
  })

  it("收到 CONVERSATION_UPDATE Dispatch 后 emit conv_update", () => {
    client = new WanlingClient({
      serverUrl: "http://localhost:18008",
      agentId: "agent-1",
      secretKey: "secret",
    })

    const received: any[] = []
    client.on("conv_update", (p) => received.push(p))

    // 模拟 server 推来的 CONVERSATION_UPDATE Dispatch
    ;(client as any).handleMessage({
      op: 0, // OP_DISPATCH
      t: "CONVERSATION_UPDATE",
      s: 42,
      d: { conv_id: "conv-9", title: "新名", avatar_url: "" },
    })

    expect(received).toHaveLength(1)
    expect(received[0].conv_id).toBe("conv-9")
    expect(received[0].title).toBe("新名")
  })
})

describe("WanlingClient sendAgentModels", () => {
  let client: WanlingClient
  let wsMock: { readyState: number; send: ReturnType<typeof vi.fn>; OPEN: number }

  beforeEach(() => {
    client = new WanlingClient({
      serverUrl: "http://localhost:18008",
      agentId: "agent-1",
      secretKey: "secret",
    })
    wsMock = { readyState: 1, send: vi.fn(), OPEN: 1 }
    ;(client as any).ws = wsMock
  })

  afterEach(() => {
    if (client) client.disconnect()
    vi.restoreAllMocks()
  })

  it("WS OPEN 时发送 AGENT_MODELS payload", () => {
    const models = [
      { provider_id: "zhipuai", provider_name: "Zhipuai", model_id: "glm-5.2", model_name: "GLM-5.2" },
    ]
    client.sendAgentModels("agent-1", models)
    expect(wsMock.send).toHaveBeenCalledTimes(1)
    const sent = JSON.parse(wsMock.send.mock.calls[0][0])
    expect(sent.op).toBe(0) // OP_DISPATCH
    expect(sent.t).toBe("AGENT_MODELS")
    expect(sent.d.agent_id).toBe("agent-1")
    expect(sent.d.models).toEqual(models)
    expect(sent.d.reported_at).toBeTruthy()
  })

  it("WS 未连接时不抛错(silently drop + warn)", () => {
    wsMock.readyState = 3 // CLOSED
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {})
    expect(() => client.sendAgentModels("agent-1", [])).not.toThrow()
    expect(wsMock.send).not.toHaveBeenCalled()
    expect(warnSpy).toHaveBeenCalled()
  })
})

describe("WanlingClient.updateSessionMeta", () => {
  let client: WanlingClient
  let fetchSpy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    client = new WanlingClient({
      serverUrl: "http://localhost:18008",
      agentId: "agent-1",
      secretKey: "secret",
    })
    fetchSpy = vi.spyOn(globalThis, "fetch")
  })

  afterEach(() => {
    if (client) client.disconnect()
    vi.restoreAllMocks()
  })

  it("body 含 cwd 和 gitBranch 字段", async () => {
    const captured: any[] = []
    fetchSpy.mockImplementation(async (_url: string, init: any) => {
      captured.push(JSON.parse(init.body))
      return new Response("{}", { status: 200 })
    })

    await client.updateSessionMeta("conv-1", {
      mode: "build",
      modelId: "m",
      providerId: "p",
      cwd: "/home/u/proj",
      gitBranch: "main",
    })

    expect(captured).toHaveLength(1)
    expect(captured[0].cwd).toBe("/home/u/proj")
    expect(captured[0].gitBranch).toBe("main")
    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining("/api/agents/me/conversations/conv-1/session-meta"),
      expect.objectContaining({ method: "PATCH" }),
    )
  })

  it("cwd/gitBranch 缺省时 body 不含这俩 key", async () => {
    const captured: any[] = []
    fetchSpy.mockImplementation(async (_url: string, init: any) => {
      captured.push(JSON.parse(init.body))
      return new Response("{}", { status: 200 })
    })

    await client.updateSessionMeta("conv-1", {
      mode: "build",
      modelId: "m",
      providerId: "p",
    })

    expect(captured).toHaveLength(1)
    expect(captured[0]).not.toHaveProperty("cwd")
    expect(captured[0]).not.toHaveProperty("gitBranch")
  })
})

describe("WanlingClient RPC 路由", () => {
  let client: WanlingClient
  let sent: string[]

  beforeEach(() => {
    sent = []
  })

  afterEach(() => {
    if (client) client.disconnect()
    vi.restoreAllMocks()
  })

  it("收到 OpPluginCall 后回发 OpPluginResult", async () => {
    const dispatcher = new RPCDispatcher()
    dispatcher.register("echo", async (p) => ({ echo: (p as { text?: string }).text ?? "" }))

    client = createTestClient({ dispatcher })
    mockSend(client, (raw) => sent.push(raw))

    simulateIncoming(client, {
      op: 12,
      d: { jsonrpc: "2.0", id: "abc", method: "echo", params: { text: "hi" } },
    })

    await nextTick()

    expect(sent).toHaveLength(1)
    const out = JSON.parse(sent[0])
    expect(out.op).toBe(13)
    expect(out.d).toEqual({ jsonrpc: "2.0", id: "abc", result: { echo: "hi" } })
  })

  it("无 dispatcher 时安全忽略 OpPluginCall(不抛错)", async () => {
    client = createTestClient()
    mockSend(client, (raw) => sent.push(raw))

    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {})
    expect(() =>
      simulateIncoming(client, {
        op: 12,
        d: { jsonrpc: "2.0", id: "x", method: "echo", params: {} },
      }),
    ).not.toThrow()
    expect(warnSpy).toHaveBeenCalled()
    await nextTick()
    expect(sent).toHaveLength(0)
  })
})

describe("WanlingClient sendAgentSlashCatalog", () => {
  let client: WanlingClient
  let wsMock: { readyState: number; send: ReturnType<typeof vi.fn>; OPEN: number }

  beforeEach(() => {
    client = new WanlingClient({
      serverUrl: "http://localhost:18008",
      agentId: "agent-1",
      secretKey: "secret",
    })
    wsMock = { readyState: 1, send: vi.fn(), OPEN: 1 }
    ;(client as any).ws = wsMock
  })

  afterEach(() => {
    if (client) client.disconnect()
    vi.restoreAllMocks()
  })

  it("WS OPEN 时发送 AGENT_SLASH_CATALOG payload", () => {
    const commands = [
      { name: "compact", template: "/compact", description: "压缩上下文", source: "command" },
      { name: "agently-mail", template: "/agently-mail", description: "邮件", source: "skill" },
    ]
    client.sendAgentSlashCatalog("agent-1", commands)
    expect(wsMock.send).toHaveBeenCalledTimes(1)
    const sent = JSON.parse(wsMock.send.mock.calls[0][0])
    expect(sent.op).toBe(0) // OP_DISPATCH
    expect(sent.t).toBe("AGENT_SLASH_CATALOG")
    expect(sent.d.agent_id).toBe("agent-1")
    expect(sent.d.commands).toEqual(commands)
    expect(sent.d.reported_at).toBeTruthy()
  })

  it("WS 未连接时不抛错(silently drop + warn)", () => {
    wsMock.readyState = 3 // CLOSED
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {})
    expect(() => client.sendAgentSlashCatalog("agent-1", [])).not.toThrow()
    expect(wsMock.send).not.toHaveBeenCalled()
    expect(warnSpy).toHaveBeenCalled()
  })
})

describe("WanlingClient sendPluginCapabilities", () => {
  let client: WanlingClient
  let wsMock: { readyState: number; send: ReturnType<typeof vi.fn>; OPEN: number }

  beforeEach(() => {
    client = new WanlingClient({
      serverUrl: "http://localhost:18008",
      agentId: "agent-1",
      secretKey: "secret",
    })
    wsMock = { readyState: 1, send: vi.fn(), OPEN: 1 }
    ;(client as any).ws = wsMock
  })

  afterEach(() => {
    if (client) client.disconnect()
    vi.restoreAllMocks()
  })

  it("WS OPEN 时发送 PLUGIN_CAPABILITIES payload", () => {
    const methods = [
      { name: "echo", timeout_hint_ms: 3000 },
      { name: "tool.run", timeout_hint_ms: 5000 },
    ]
    client.sendPluginCapabilities("agent-1", methods)
    expect(wsMock.send).toHaveBeenCalledTimes(1)
    const sent = JSON.parse(wsMock.send.mock.calls[0][0])
    expect(sent.op).toBe(0) // OP_DISPATCH
    expect(sent.t).toBe("PLUGIN_CAPABILITIES")
    expect(sent.d.agent_id).toBe("agent-1")
    expect(sent.d.methods).toEqual(methods)
    expect(typeof sent.d.reported_at).toBe("string")
    expect(sent.d.reported_at).toMatch(/^\d{4}-\d{2}-\d{2}T/) // ISO 8601
  })

  it("WS 未连接时不抛错(silently drop + warn)", () => {
    wsMock.readyState = 3 // CLOSED
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {})
    expect(() => client.sendPluginCapabilities("agent-1", [])).not.toThrow()
    expect(wsMock.send).not.toHaveBeenCalled()
    expect(warnSpy).toHaveBeenCalled()
  })
})

describe("WanlingClient sendStream", () => {
  let client: WanlingClient

  afterEach(() => {
    if (client) client.disconnect()
    vi.restoreAllMocks()
  })

  it("发 op=14 STREAM 帧,WS 未连接时 silently drop", () => {
    client = new WanlingClient({
      serverUrl: "http://localhost:18008",
      agentId: "agent-1",
      secretKey: "secret",
    })
    const sent: string[] = []
    ;(client as any).ws = { readyState: 1, send: (s: string) => sent.push(s) }

    client.sendStream("conv-1", { stream_id: "s-1", msg_type: "reasoning", text: "思考" })

    expect(sent).toHaveLength(1)
    const frame = JSON.parse(sent[0])
    expect(frame.op).toBe(14)
    expect(frame.d).toEqual({
      conversation_id: "conv-1",
      stream_id: "s-1",
      msg_type: "reasoning",
      text: "思考",
    })
    expect(frame.t).toBeUndefined() // STREAM 不带 t

    // WS 未连接时 drop
    ;(client as any).ws = { readyState: 3, send: (s: string) => sent.push(s) }
    client.sendStream("conv-1", { stream_id: "s-1", msg_type: "reasoning", text: "x" })
    expect(sent).toHaveLength(1) // 没新增,仍是第 1 帧
  })
})

function makeJwt(exp: number): string {
  const header = Buffer.from(JSON.stringify({ alg: "HS256" })).toString("base64url")
  const payload = Buffer.from(JSON.stringify({ exp })).toString("base64url")
  return `${header}.${payload}.sig`
}

// RPC 测试用的 helper:createTestClient 注入默认 server 配置 + 可选 dispatcher,
// mockSend 注入 readyState=OPEN 的 mock ws,simulateIncoming 直调 handleMessage,
// nextTick 等 dispatcher.dispatch 异步链路 flush。
function createTestClient(opts: { dispatcher?: RPCDispatcher } = {}): WanlingClient {
  const options: WanlingClientOptions = {
    serverUrl: "http://localhost:18008",
    agentId: "agent-1",
    secretKey: "secret",
  }
  if (opts.dispatcher) {
    options.dispatcher = opts.dispatcher
  }
  return new WanlingClient(options)
}

function mockSend(client: WanlingClient, fn: (raw: string) => void): void {
  ;(client as unknown as {
    ws: { readyState: number; send: (s: string) => void }
  }).ws = {
    readyState: 1,
    send: (s) => fn(s),
  }
}

function simulateIncoming(client: WanlingClient, msg: unknown): void {
  ;(client as unknown as { handleMessage: (m: unknown) => void }).handleMessage(msg)
}

async function nextTick(): Promise<void> {
  await new Promise((r) => setTimeout(r, 10))
}
