import { describe, it, expect, vi, afterAll, afterEach, beforeEach } from "vitest"
import http from "http"

const stub = {
  wanling: {},
  opencode: { getCurrentSession: vi.fn().mockResolvedValue(null) },
  sync: { getStatus: vi.fn().mockReturnValue({ running: false }) },
  getStreamer: vi.fn<() => undefined>(() => undefined),
}

function req(
  port: number,
  path: string,
  headers: Record<string, string> = {},
): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const r = http.request(
      { host: "127.0.0.1", port, path, method: "GET", headers },
      (res) => {
        const chunks: Buffer[] = []
        res.on("data", (c) => chunks.push(c))
        res.on("end", () =>
          resolve({
            status: res.statusCode || 0,
            body: Buffer.concat(chunks).toString("utf-8"),
          }),
        )
      },
    )
    r.on("error", reject)
    r.end()
  })
}

// POST 请求 helper(append-image 等 body endpoint 用)
function post(
  port: number,
  path: string,
  body: unknown,
  headers: Record<string, string> = {},
): Promise<{ status: number; body: string }> {
  const payload = JSON.stringify(body)
  return new Promise((resolve, reject) => {
    const r = http.request(
      {
        host: "127.0.0.1",
        port,
        path,
        method: "POST",
        headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(payload), ...headers },
      },
      (res) => {
        const chunks: Buffer[] = []
        res.on("data", (c) => chunks.push(c))
        res.on("end", () =>
          resolve({
            status: res.statusCode || 0,
            body: Buffer.concat(chunks).toString("utf-8"),
          }),
        )
      },
    )
    r.on("error", reject)
    r.end(payload)
  })
}

describe("Control API 鉴权", () => {
  let handle: { close: () => void; port: number; token: string }

  beforeEach(async () => {
    vi.resetModules()
    stub.getStreamer.mockClear()
    const mod = await import("./api.js")
    handle = await mod.startControlApi({
      port: 0,
      wanling: stub.wanling as any,
      opencode: stub.opencode as any,
      sync: stub.sync as any,
      getStreamer: stub.getStreamer,
    })
  })
  afterEach(() => handle?.close())
  afterAll(() => vi.restoreAllMocks())

  it("缺 Authorization → 403", async () => {
    const resp = await req(handle.port, "/status")
    expect(resp.status).toBe(403)
  })

  it("错 token → 403", async () => {
    const resp = await req(handle.port, "/status", {
      Authorization: "Bearer wrong-token",
    })
    expect(resp.status).toBe(403)
  })

  it("正确 token → 200", async () => {
    const resp = await req(handle.port, "/status", {
      Authorization: `Bearer ${handle.token}`,
    })
    expect(resp.status).toBe(200)
  })
})

describe("Control API POST /aggregate/append-image", () => {
  let handle: { close: () => void; port: number; token: string }

  beforeEach(async () => {
    vi.resetModules()
    stub.getStreamer.mockClear()
    const mod = await import("./api.js")
    handle = await mod.startControlApi({
      port: 0,
      wanling: stub.wanling as any,
      opencode: stub.opencode as any,
      sync: stub.sync as any,
      getStreamer: stub.getStreamer,
    })
  })
  afterEach(() => handle?.close())
  afterAll(() => vi.restoreAllMocks())

  const auth = (h: { token: string }) => ({ Authorization: `Bearer ${h.token}` })

  it("缺 file_id → 400", async () => {
    const resp = await post(handle.port, "/aggregate/append-image", {}, auth(handle))
    expect(resp.status).toBe(400)
  })

  it("streamer 未就绪(getStreamer 返回 undefined)→ 200 no_active_card", async () => {
    stub.getStreamer.mockReturnValue(undefined)
    const resp = await post(
      handle.port,
      "/aggregate/append-image",
      { file_id: "f-123" },
      auth(handle),
    )
    expect(resp.status).toBe(200)
    expect(JSON.parse(resp.body)).toEqual({ ok: true, data: { result: "no_active_card" } })
  })

  it("streamer 返回 appended → 200 透传结果", async () => {
    const appendImageToCard = vi.fn().mockResolvedValue("appended")
    stub.getStreamer.mockReturnValue({ appendImageToCard } as any)
    const resp = await post(
      handle.port,
      "/aggregate/append-image",
      { file_id: "f-123", alt: "截图", session_id: "sess-x" },
      auth(handle),
    )
    expect(resp.status).toBe(200)
    expect(JSON.parse(resp.body)).toEqual({ ok: true, data: { result: "appended" } })
    expect(appendImageToCard).toHaveBeenCalledWith("f-123", "截图")
  })

  it("appendImageToCard 抛错 → 500", async () => {
    const appendImageToCard = vi.fn().mockRejectedValue(new Error("patch failed"))
    stub.getStreamer.mockReturnValue({ appendImageToCard } as any)
    const resp = await post(
      handle.port,
      "/aggregate/append-image",
      { file_id: "f-123" },
      auth(handle),
    )
    expect(resp.status).toBe(500)
    expect(JSON.parse(resp.body).ok).toBe(false)
  })
})
