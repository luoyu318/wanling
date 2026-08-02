import { describe, it, expect, vi, afterAll, afterEach, beforeEach } from "vitest"
import http from "http"

const stub = {
  wanling: {},
  opencode: { getCurrentSession: vi.fn().mockResolvedValue(null) },
  sync: { getStatus: vi.fn().mockReturnValue({ running: false }) },
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

describe("Control API 鉴权", () => {
  let handle: { close: () => void; port: number; token: string }

  beforeEach(async () => {
    vi.resetModules()
    const mod = await import("./api.js")
    handle = await mod.startControlApi({
      port: 0,
      wanling: stub.wanling as any,
      opencode: stub.opencode as any,
      sync: stub.sync as any,
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
