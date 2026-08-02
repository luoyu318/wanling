import { describe, it, expect, beforeEach, afterEach, vi } from "vitest"
import { mkdtempSync, writeFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { WanlingRestClient, ApiError } from "../src/rest.js"

function okJson(data: unknown): Response {
  return new Response(JSON.stringify({ ok: true, data }), { status: 200 })
}

describe("WanlingRestClient", () => {
  let fetchSpy: ReturnType<typeof vi.spyOn>
  let client: WanlingRestClient

  beforeEach(() => {
    fetchSpy = vi.spyOn(globalThis, "fetch")
    client = new WanlingRestClient("http://localhost:18008/", async () => "jwt-token")
  })

  afterEach(() => vi.restoreAllMocks())

  it("sendCardMessage POST /api/conversations/:id/messages 带 silent + token", async () => {
    fetchSpy.mockResolvedValue(okJson({ message_id: "m1" }))
    const id = await client.sendCardMessage("conv-1", "card", { action: "x" })
    expect(id).toBe("m1")
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toBe("http://localhost:18008/api/conversations/conv-1/messages")
    expect(init.method).toBe("POST")
    expect(JSON.parse(String(init.body))).toEqual({ content: { msg_type: "card", data: { action: "x" }, silent: true } })
    expect((init.headers as Record<string, string>).Authorization).toBe("Bearer jwt-token")
  })

  it("createGroupAsAgent 返 data.id", async () => {
    fetchSpy.mockResolvedValue(okJson({ id: "conv-9" }))
    const id = await client.createGroupAsAgent("agent_session", "t", { userId: "u1" })
    expect(id).toBe("conv-9")
  })

  it("非 ok 状态抛 ApiError", async () => {
    fetchSpy.mockResolvedValue(new Response(JSON.stringify({ ok: false, error: { code: "not_found", message: "x" } }), { status: 404 }))
    await expect(client.updateConversationTitle("c1", "n")).rejects.toThrow("HTTP 404")
  })

  it("uploadFile 网络错误抛 ApiError 而非原生异常", async () => {
    const dir = mkdtempSync(join(tmpdir(), "rest-test-"))
    const file = join(dir, "foo.txt")
    writeFileSync(file, "hello")
    fetchSpy.mockRejectedValue(new Error("ECONNRESET"))
    await expect(client.uploadFile(file)).rejects.toThrow(ApiError)
    await expect(client.uploadFile(file)).rejects.toThrow("request failed: ECONNRESET")
    rmSync(dir, { recursive: true, force: true })
  })

  it("downloadFile 超时(AbortError)抛 ApiError 而非 DOMException", async () => {
    fetchSpy.mockRejectedValue(new DOMException("The operation was aborted.", "AbortError"))
    await expect(client.downloadFile("f1")).rejects.toThrow(ApiError)
    await expect(client.downloadFile("f1")).rejects.toThrow("request failed: The operation was aborted.")
  })
})
