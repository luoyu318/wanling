/* eslint-disable @typescript-eslint/no-explicit-any */
import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { WanlingClient } from "../src/client.js"
import { RPCDispatcher } from "../src/rpc.js"

function makeJwt(exp: number): string {
  const payload = Buffer.from(JSON.stringify({ sub: "agent-1", exp })).toString("base64url")
  return `h.${payload}.s`
}

describe("WanlingClient 事件分发", () => {
  let client: WanlingClient
  beforeEach(() => {
    client = new WanlingClient({ serverUrl: "http://localhost:18008", agentId: "agent-1", secretKey: "s" })
  })
  afterEach(() => client.disconnect())

  it("MESSAGE_CREATE → emit message", () => {
    const got: unknown[] = []
    client.on("message", (p) => got.push(p))
    ;(client as any).handleMessage({ op: 0, t: "MESSAGE_CREATE", s: 1, d: { conversation_id: "c1" } })
    expect((client as any).retry.lastSeq).toBe(1)
    expect(got).toHaveLength(1)
    expect((got[0] as any).conversation_id).toBe("c1")
  })

  it("APPROVAL_DECIDED → emit approval.decided", () => {
    const got: unknown[] = []
    client.on("approval.decided", (p) => got.push(p))
    ;(client as any).handleMessage({ op: 0, t: "APPROVAL_DECIDED", s: 2, d: { session_key: "k" } })
    expect((got[0] as any).session_key).toBe("k")
  })

  it("会话元数据事件映射", () => {
    const got: unknown[] = []
    client.on("session.meta.update", (p) => got.push(p))
    ;(client as any).handleMessage({ op: 0, t: "SESSION_META_UPDATE", d: { conv_id: "c1" } })
    expect(got).toHaveLength(1)
  })
})

describe("WanlingClient token 换取与刷新", () => {
  let client: WanlingClient
  let fetchSpy: ReturnType<typeof vi.spyOn>
  beforeEach(() => {
    client = new WanlingClient({ serverUrl: "http://localhost:18008", agentId: "agent-1", secretKey: "s" })
    fetchSpy = vi.spyOn(globalThis, "fetch")
  })
  afterEach(() => { client.disconnect(); vi.restoreAllMocks() })

  it("connect() 调 exchangeToken 并计划刷新", async () => {
    const token = makeJwt(Math.floor(Date.now() / 1000) + 3600)
    fetchSpy.mockResolvedValue(new Response(JSON.stringify({ ok: true, data: { token } }), { status: 200 }))
    const connectSpy = vi.spyOn(client as any, "runReceiveLoop").mockResolvedValue(undefined)
    await client.connect()
    expect(fetchSpy).toHaveBeenCalledWith(
      expect.stringContaining("/api/agents/agent-1/token"),
      expect.objectContaining({ method: "POST" }),
    )
    expect((client as any).token).toBe(token)
    connectSpy.mockRestore()
  })

  it("token 刷新失败 emit fatal", async () => {
    ;(client as any).token = makeJwt(Math.floor(Date.now() / 1000) + 7200)
    fetchSpy.mockRejectedValueOnce(new Error("network down"))
    const fatal = vi.fn()
    client.on("fatal", fatal)
    await expect((client as any).refreshToken()).rejects.toThrow("network down")
    expect(fatal).toHaveBeenCalled()
  })
})

describe("WanlingClient 发送", () => {
  let client: WanlingClient
  let wsMock: { readyState: number; send: ReturnType<typeof vi.fn> }
  beforeEach(() => {
    client = new WanlingClient({ serverUrl: "http://localhost:18008", agentId: "a", secretKey: "s" })
    wsMock = { readyState: 1, send: vi.fn() }
    ;(client as any).ws = wsMock
  })
  afterEach(() => { client.disconnect(); vi.restoreAllMocks() })

  it("sendTypedMessage 组 content 并发 MESSAGE_CREATE", () => {
    client.sendTypedMessage("c1", "markdown", { text: "hi" }, { silent: true })
    const sent = JSON.parse(wsMock.send.mock.calls[0][0])
    expect(sent.op).toBe(0)
    expect(sent.t).toBe("MESSAGE_CREATE")
    expect(sent.d.content).toEqual({ msg_type: "markdown", data: { text: "hi" }, silent: true })
  })

  it("sendStream 走 op=14", () => {
    client.sendStream("c1", { stream_id: "s1", msg_type: "text", text: "abc" })
    const sent = JSON.parse(wsMock.send.mock.calls[0][0])
    expect(sent.op).toBe(14)
    expect(sent.d.conversation_id).toBe("c1")
  })

  it("sendTyping 发 TYPING_START", () => {
    client.sendTyping("c1")
    const sent = JSON.parse(wsMock.send.mock.calls[0][0])
    expect(sent.t).toBe("TYPING_START")
  })

  it("WS 未连接时 sendMessage emit error 不抛", () => {
    wsMock.readyState = 3
    const errSpy = vi.fn()
    client.on("error", errSpy)
    expect(() => client.sendTypedMessage("c1", "text", { text: "x" })).not.toThrow()
    expect(errSpy).toHaveBeenCalled()
  })
})

describe("WanlingClient RPC", () => {
  let client: WanlingClient
  let wsMock: { readyState: number; send: ReturnType<typeof vi.fn> }
  beforeEach(() => {
    client = new WanlingClient({ serverUrl: "http://localhost:18008", agentId: "a", secretKey: "s" })
    wsMock = { readyState: 1, send: vi.fn() }
    ;(client as any).ws = wsMock
  })
  afterEach(() => { client.disconnect(); vi.restoreAllMocks() })

  it("PLUGIN_CALL 经 dispatcher 回 PLUGIN_RESULT", async () => {
    const d = new RPCDispatcher()
    d.register("echo", async (p) => ({ echoed: p }))
    client.attachDispatcher(d)
    ;(client as any).handleMessage({ op: 12, d: { jsonrpc: "2.0", id: "r1", method: "echo", params: 1 } })
    await new Promise((r) => setTimeout(r, 20))
    const sent = JSON.parse(wsMock.send.mock.calls[0][0])
    expect(sent.op).toBe(13)
    expect(sent.d.result).toEqual({ echoed: 1 })
  })

  it("未注册 dispatcher 时 PLUGIN_CALL 安全忽略", () => {
    expect(() => (client as any).handleMessage({ op: 12, d: { jsonrpc: "2.0", id: "r2", method: "x" } })).not.toThrow()
    expect(wsMock.send).not.toHaveBeenCalled()
  })
})

describe("WanlingClient 能力上报", () => {
  it("reportModels / reportSlashCatalog / reportCapabilities 发对应事件", () => {
    const client = new WanlingClient({ serverUrl: "http://localhost:18008", agentId: "a", secretKey: "s" })
    const wsMock = { readyState: 1, send: vi.fn() }
    ;(client as any).ws = wsMock
    client.sendAgentModels("a", [{ provider_id: "p", provider_name: "P", model_id: "m", model_name: "M" }])
    client.sendAgentSlashCatalog("a", [{ name: "compact", template: "/compact", source: "command" }])
    client.sendPluginCapabilities("a", [{ name: "echo", timeout_hint_ms: 5000 }])
    const ts = [0, 1, 2].map((i) => JSON.parse(wsMock.send.mock.calls[i][0]).t)
    expect(ts).toEqual(["AGENT_MODELS", "AGENT_SLASH_CATALOG", "PLUGIN_CAPABILITIES"])
    client.disconnect()
  })
})
