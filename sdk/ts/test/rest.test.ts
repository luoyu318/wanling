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

  it("downloadFile 返回 {buffer, contentType},消费 server 嗅探矫正的 Content-Type", async () => {
    fetchSpy.mockResolvedValue(
      new Response(Buffer.from([0x89, 0x50, 0x4e, 0x47]), { status: 200, headers: { "Content-Type": "image/png" } }),
    )
    const res = await client.downloadFile("f-img")
    expect(res.buffer).toEqual(Buffer.from([0x89, 0x50, 0x4e, 0x47]))
    expect(res.contentType).toBe("image/png")
  })

  it("downloadFile 响应无 Content-Type 头时 contentType 缺省(属性不存在或 undefined)", async () => {
    // ArrayBufferView body 不携带 MIME,undici 不会补默认 Content-Type
    fetchSpy.mockResolvedValue(new Response(Buffer.from([9]), { status: 200 }))
    const res = await client.downloadFile("f-raw")
    expect(res.buffer).toEqual(Buffer.from([9]))
    expect(res.contentType).toBeUndefined()
  })

  it("createApproval POST /api/conversations/:id/approvals 返 approval_id", async () => {
    fetchSpy.mockResolvedValue(okJson({ approval_id: "appr-1" }))
    const res = await client.createApproval("conv-1", {
      card_type: "command",
      title: "命令执行审批",
      preview: "rm -rf /tmp/x",
      session_key: "sk-1",
      timeout_sec: 300,
    })
    expect(res.approval_id).toBe("appr-1")
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toBe("http://localhost:18008/api/conversations/conv-1/approvals")
    expect(init.method).toBe("POST")
    expect(JSON.parse(String(init.body))).toEqual({
      card_type: "command", title: "命令执行审批", preview: "rm -rf /tmp/x",
      session_key: "sk-1", timeout_sec: 300,
    })
  })

  it("createApproval 白名单命中返 auto_approved", async () => {
    fetchSpy.mockResolvedValue(okJson({ state: "approved", auto_approved: true, matched_pattern: "rm *" }))
    const res = await client.createApproval("conv-1", {
      card_type: "command", title: "t", preview: "rm -rf /x", session_key: "sk-1", allow_pattern: "rm *",
    })
    expect(res.auto_approved).toBe(true)
  })

  it("uploadFile 超过 maxUploadBytes 抛 ApiError(可配置上限)", async () => {
    const dir = mkdtempSync(join(tmpdir(), "rest-test-"))
    const file = join(dir, "big.txt")
    writeFileSync(file, Buffer.alloc(2 * 1024 * 1024, 97)) // 2MB
    try {
      const small = new WanlingRestClient("http://x", async () => "t", { maxUploadBytes: 1024 })
      await expect(small.uploadFile(file)).rejects.toThrow("too large")
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it("uploadFile 默认上限对齐 server 32MB(不抛)", async () => {
    const dir = mkdtempSync(join(tmpdir(), "rest-test-"))
    const file = join(dir, "mid.txt")
    writeFileSync(file, Buffer.alloc(21 * 1024 * 1024, 98)) // 21MB(> 旧 20MB 限制)
    try {
      fetchSpy.mockResolvedValue(okJson({ id: "f1" }))
      const id = await client.uploadFile(file)
      expect(id).toBe("f1")
    } finally {
      rmSync(dir, { recursive: true, force: true })
    }
  })

  it("patchAggregateMessage PATCH 增量 op(append)", async () => {
    fetchSpy.mockResolvedValue(new Response(JSON.stringify({ ok: true }), { status: 200 }))
    await client.patchAggregateMessage("m1", {
      op: "append",
      element: { type: "markdown", element_id: "m1", data: { text: "hi" } },
    })
    const [url, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(url).toBe("http://localhost:18008/api/messages/m1")
    expect(init.method).toBe("PATCH")
    expect(JSON.parse(String(init.body))).toEqual({
      content: {
        msg_type: "aggregate_card",
        data: { op: "append", element: { type: "markdown", element_id: "m1", data: { text: "hi" } } },
      },
    })
  })

  it("patchAggregateMessage set_silent 翻转", async () => {
    fetchSpy.mockResolvedValue(new Response(JSON.stringify({ ok: true }), { status: 200 }))
    await client.patchAggregateMessage("m1", { op: "set_silent", silent: false })
    const [, init] = fetchSpy.mock.calls[0] as [string, RequestInit]
    expect(JSON.parse(String(init.body))).toEqual({
      content: { msg_type: "aggregate_card", data: { op: "set_silent", silent: false } },
    })
  })
})
