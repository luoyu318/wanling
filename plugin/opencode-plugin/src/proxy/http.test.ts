import { describe, it, expect, vi, afterAll, beforeEach, afterEach } from "vitest"
import { rmSync } from "fs"
import { join } from "path"
import { createServer, type Server } from "http"
import http from "http"

const { TMP } = vi.hoisted(() => ({
  TMP: `/tmp/wl-proxy-test-${process.pid}-${Date.now()}`,
}))
vi.mock("../config.js", () => ({ configDir: () => TMP }))

afterAll(() => {
  rmSync(TMP, { recursive: true, force: true })
})

let matchSessionPost: typeof import("./http.js").matchSessionPost
let trySyncPrompt: typeof import("./http.js").trySyncPrompt
let startProxy: typeof import("./http.js").startProxy
let mapper: typeof import("../sync/mapper.js")

beforeEach(async () => {
  vi.resetModules()
  rmSync(join(TMP, "session-maps.json"), { force: true })
  const httpMod = await import("./http.js")
  matchSessionPost = httpMod.matchSessionPost
  trySyncPrompt = httpMod.trySyncPrompt
  startProxy = httpMod.startProxy
  mapper = await import("../sync/mapper.js")
})

describe("matchSessionPost 宽松 path 匹配", () => {
  it("旧 v1 prompt path", () => {
    expect(matchSessionPost("POST", "/api/session/sess-1/prompt")).toBe("sess-1")
  })

  it("旧 TUI message path", () => {
    expect(matchSessionPost("POST", "/session/sess-1/message")).toBe("sess-1")
  })

  it("未来 v2 prompt path(SDK 升级后场景)", () => {
    expect(matchSessionPost("POST", "/api/v2/session/sess-1/prompt")).toBe("sess-1")
  })

  it("未知 verb 也命中(交给 body 判定)", () => {
    expect(matchSessionPost("POST", "/api/session/sess-1/unknownVerb")).toBe("sess-1")
  })

  it("GET 不命中", () => {
    expect(matchSessionPost("GET", "/api/session/sess-1/prompt")).toBeNull()
  })

  it("非 session path 不命中", () => {
    expect(matchSessionPost("POST", "/api/config")).toBeNull()
    expect(matchSessionPost("POST", "/foo/bar")).toBeNull()
  })

  it("裸 /session/:id 不命中(需带 verb)", () => {
    expect(matchSessionPost("POST", "/session/sess-1")).toBeNull()
  })
})

describe("trySyncPrompt body 双重判定", () => {
  function mockWanling() {
    return { sendTypedMessage: vi.fn() } as unknown as Parameters<typeof trySyncPrompt>[2]
  }

  it("含 parts 的 prompt body + 已建群 → 同步 tui_user", () => {
    mapper.upsertSessionMap({
      wanlingConvId: "conv-1", opencodeSessionId: "sess-1",
      lastSyncAt: new Date().toISOString(), messageCount: 0,
    })
    const wanling = mockWanling()
    const onUserSession = vi.fn()
    const body = Buffer.from(JSON.stringify({
      parts: [{ type: "text", text: "hello from TUI" }],
    }))
    const result = trySyncPrompt("sess-1", body, wanling, onUserSession)
    expect(result).toBe(true)
    expect(onUserSession).toHaveBeenCalledWith("sess-1")
    expect(wanling.sendTypedMessage).toHaveBeenCalledWith(
      "conv-1", "tui_user", { text: "hello from TUI" }, { silent: true },
    )
  })

  it("body 无 parts 字段(abort 等非 prompt 请求)→ 不同步、不触发 onUserSession", () => {
    const wanling = mockWanling()
    const onUserSession = vi.fn()
    const body = Buffer.from(JSON.stringify({}))
    const result = trySyncPrompt("sess-1", body, wanling, onUserSession)
    expect(result).toBe(false)
    expect(onUserSession).not.toHaveBeenCalled()
    expect(wanling.sendTypedMessage).not.toHaveBeenCalled()
  })

  it("parts 全是 system-reminder → 不同步", () => {
    const wanling = mockWanling()
    const body = Buffer.from(JSON.stringify({
      parts: [{ type: "text", text: "<system-reminder>noise</system-reminder>" }],
    }))
    expect(trySyncPrompt("sess-1", body, wanling)).toBe(false)
    expect(wanling.sendTypedMessage).not.toHaveBeenCalled()
  })

  it("非 JSON body → 静默跳过", () => {
    const wanling = mockWanling()
    expect(trySyncPrompt("sess-1", Buffer.from("not-json"), wanling)).toBe(false)
  })

  it("群未建时暂存 pending 待补发(不直接发,避免 race 丢首条)", () => {
    const wanling = mockWanling()
    const onUserSession = vi.fn()
    const body = Buffer.from(JSON.stringify({
      parts: [{ type: "text", text: "hello" }],
    }))
    const result = trySyncPrompt("sess-not-mapped", body, wanling, onUserSession)
    expect(result).toBe(true)
    expect(onUserSession).toHaveBeenCalledWith("sess-not-mapped")
    // 没建群时无 convId,不能直接发
    expect(wanling.sendTypedMessage).not.toHaveBeenCalled()
    // 消息暂存到 pending 队列,建群后由 ensureConversation drain 补发
    expect(mapper.drainPendingTuiMessages("sess-not-mapped")).toEqual(["hello"])
  })
})

// 端到端:proxy 真实起 HTTP server + target server,验证转发 + 同步联动
describe("startProxy 端到端 HTTP", () => {
  let target: Server
  let targetPort: number
  let proxyHandle: { close: () => void; port: number }
  let targetReceived: { method: string; url: string; body: string }[]
  let wanling: { sendTypedMessage: ReturnType<typeof vi.fn> }
  let onUserSession: ReturnType<typeof vi.fn>

  function startTarget(): Promise<{ server: Server; port: number }> {
    return new Promise((resolve) => {
      const s = createServer((req, res) => {
        const chunks: Buffer[] = []
        req.on("data", (c: Buffer) => chunks.push(c))
        req.on("end", () => {
          targetReceived.push({
            method: req.method || "",
            url: req.url || "",
            body: Buffer.concat(chunks).toString("utf-8"),
          })
          res.writeHead(200, { "Content-Type": "application/json" })
          res.end(JSON.stringify({ ok: true }))
        })
      })
      s.listen(0, "127.0.0.1", () => {
        const addr = s.address()
        const port = addr && typeof addr === "object" ? addr.port : 0
        resolve({ server: s, port })
      })
    })
  }

  function request(port: number, method: string, path: string, body?: unknown, extraHeaders: Record<string, string> = {}): Promise<{ status: number; body: string }> {
    return new Promise((resolve, reject) => {
      const bodyStr = body === undefined ? "" : JSON.stringify(body)
      const auth = Buffer.from("opencode:test-proxy-pw").toString("base64")
      const headers = {
        "Content-Type": "application/json",
        "Content-Length": String(Buffer.byteLength(bodyStr)),
        Authorization: `Basic ${auth}`,
        ...extraHeaders,
      }
      const req = http.request(
        { host: "127.0.0.1", port, path, method, headers },
        (res) => {
          const chunks: Buffer[] = []
          res.on("data", (c: Buffer) => chunks.push(c))
          res.on("end", () => resolve({ status: res.statusCode || 0, body: Buffer.concat(chunks).toString("utf-8") }))
        },
      )
      req.on("error", reject)
      req.end(bodyStr)
    })
  }

  beforeEach(async () => {
    targetReceived = []
    wanling = { sendTypedMessage: vi.fn() } as unknown as typeof wanling
    onUserSession = vi.fn()
    const t = await startTarget()
    target = t.server
    targetPort = t.port
    proxyHandle = await startProxy({
      listenPort: 0, targetPort,
      wanling: wanling as unknown as Parameters<typeof startProxy>[0]["wanling"],
      onUserSession,
      password: "test-proxy-pw",
    })
  })

  afterEach(() => {
    target.close()
    proxyHandle.close()
  })

  it("prompt body 经 v1 path 转发到 target + 同步触发", async () => {
    mapper.upsertSessionMap({
      wanlingConvId: "conv-1", opencodeSessionId: "sess-1",
      lastSyncAt: new Date().toISOString(), messageCount: 0,
    })

    const resp = await request(proxyHandle.port, "POST", "/api/session/sess-1/prompt", {
      parts: [{ type: "text", text: "hi" }],
    })

    expect(resp.status).toBe(200)
    expect(targetReceived).toHaveLength(1)
    expect(targetReceived[0].url).toBe("/api/session/sess-1/prompt")
    expect(wanling.sendTypedMessage).toHaveBeenCalled()
    expect(onUserSession).toHaveBeenCalledWith("sess-1")
  })

  it("未知 v2 path 也触发同步(SDK 升级场景)", async () => {
    mapper.upsertSessionMap({
      wanlingConvId: "conv-1", opencodeSessionId: "sess-1",
      lastSyncAt: new Date().toISOString(), messageCount: 0,
    })

    await request(proxyHandle.port, "POST", "/api/v2/session/sess-1/prompt", {
      parts: [{ type: "text", text: "future" }],
    })

    expect(wanling.sendTypedMessage).toHaveBeenCalledWith(
      "conv-1", "tui_user", { text: "future" }, { silent: true },
    )
  })

  it("非 prompt body(无 parts)不触发同步但仍转发", async () => {
    await request(proxyHandle.port, "POST", "/api/session/sess-1/abort", {})

    expect(wanling.sendTypedMessage).not.toHaveBeenCalled()
    expect(onUserSession).not.toHaveBeenCalled()
    expect(targetReceived).toHaveLength(1)
    expect(targetReceived[0].url).toBe("/api/session/sess-1/abort")
  })

  it("GET 请求不触发同步但仍转发", async () => {
    await request(proxyHandle.port, "GET", "/api/session/sess-1")

    expect(wanling.sendTypedMessage).not.toHaveBeenCalled()
    expect(targetReceived).toHaveLength(1)
  })

  it("缺 Authorization → 401", async () => {
    // 不带任何 Authorization header,直接裸请求
    const resp = await new Promise<{ status: number }>((resolve, reject) => {
      const r = http.request(
        { host: "127.0.0.1", port: proxyHandle.port, path: "/api/session/sess-1", method: "GET", headers: {} },
        (res) => {
          res.on("data", () => {})
          res.on("end", () => resolve({ status: res.statusCode || 0 }))
        }
      )
      r.on("error", reject)
      r.end()
    })
    expect(resp.status).toBe(401)
    expect(targetReceived).toHaveLength(0)
  })

  it("错 password → 401", async () => {
    const auth = Buffer.from("opencode:wrong-pw").toString("base64")
    const resp = await request(proxyHandle.port, "GET", "/api/session/sess-1", undefined, { Authorization: `Basic ${auth}` })
    expect(resp.status).toBe(401)
    expect(targetReceived).toHaveLength(0)
  })
})
