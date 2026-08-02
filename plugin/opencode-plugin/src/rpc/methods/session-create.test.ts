import { describe, it, expect, vi, beforeEach } from "vitest"

vi.mock("../../sync/mapper.js", () => ({
  getSessionMap: vi.fn(),
  upsertSessionMap: vi.fn(),
}))

import { sessionCreateHandler } from "./session-create.js"
import { getSessionMap, upsertSessionMap } from "../../sync/mapper.js"

function makeCtx(clientOverrides?: Partial<{ create: any }>) {
  const create = clientOverrides?.create ?? vi.fn().mockResolvedValue({
    data: { id: "oc-sess-new" },
  })
  const client = { session: { create } } as any
  return { getClient: () => client }
}

describe("session.create handler", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("创建新的 OC session，回写 mapper，返回 opencode_session_id", async () => {
    vi.mocked(getSessionMap).mockReturnValue(undefined)

    const result = await sessionCreateHandler(
      { wanling_conv_id: "conv-1", title: "我的项目", directory: "/tmp/proj" },
      makeCtx(),
    )

    expect(result.opencode_session_id).toBe("oc-sess-new")
    expect(upsertSessionMap).toHaveBeenCalledWith(
      expect.objectContaining({
        wanlingConvId: "conv-1",
        opencodeSessionId: "oc-sess-new",
        messageCount: 0,
      }),
    )
  })

  it("wanling_conv_id 已存在 → 直接返回已有 session，不调 OC create", async () => {
    vi.mocked(getSessionMap).mockReturnValue({
      wanlingConvId: "conv-1",
      opencodeSessionId: "oc-sess-exists",
      lastSyncAt: "2026-07-20T00:00:00Z",
      messageCount: 3,
    })
    const ctx = makeCtx()

    const result = await sessionCreateHandler({ wanling_conv_id: "conv-1" }, ctx)

    expect(result.opencode_session_id).toBe("oc-sess-exists")
    expect(ctx.getClient().session.create).not.toHaveBeenCalled()
  })

  it("无 title 时 use 默认 title '万灵对话'", async () => {
    vi.mocked(getSessionMap).mockReturnValue(undefined)
    const ctx = makeCtx()

    await sessionCreateHandler({ wanling_conv_id: "conv-1" }, ctx)

    expect(ctx.getClient().session.create).toHaveBeenCalledWith(
      expect.objectContaining({ title: "万灵对话" }),
    )
  })

  it("无 directory 时不传 directory 字段", async () => {
    vi.mocked(getSessionMap).mockReturnValue(undefined)
    const ctx = makeCtx()

    await sessionCreateHandler({ wanling_conv_id: "conv-1" }, ctx)

    expect(ctx.getClient().session.create).toHaveBeenCalledWith(
      expect.not.objectContaining({ directory: expect.anything() }),
    )
  })

  it("有 directory 时传给 OC create", async () => {
    vi.mocked(getSessionMap).mockReturnValue(undefined)
    const ctx = makeCtx()

    await sessionCreateHandler(
      { wanling_conv_id: "conv-1", directory: "/home/user/proj" },
      ctx,
    )

    expect(ctx.getClient().session.create).toHaveBeenCalledWith(
      expect.objectContaining({ directory: "/home/user/proj" }),
    )
  })

  it("params 缺 wanling_conv_id → 抛 RPCError(-32602)", async () => {
    await expect(sessionCreateHandler({}, makeCtx())).rejects.toMatchObject({
      code: -32602,
    })
  })

  it("params wanling_conv_id 为空字符串 → 抛 RPCError(-32602)", async () => {
    await expect(
      sessionCreateHandler({ wanling_conv_id: "" }, makeCtx()),
    ).rejects.toMatchObject({ code: -32602 })
  })

  it("OC client 未就绪(getClient 返 null) → 抛 RPCError(-32603)", async () => {
    vi.mocked(getSessionMap).mockReturnValue(undefined)
    const ctx = { getClient: () => null }

    await expect(
      sessionCreateHandler({ wanling_conv_id: "conv-1" }, ctx),
    ).rejects.toMatchObject({ code: -32603 })
  })

  it("OC create 抛错时透传", async () => {
    vi.mocked(getSessionMap).mockReturnValue(undefined)
    const ctx = makeCtx({
      create: vi.fn().mockRejectedValue(new Error("SDK timeout")),
    })

    await expect(
      sessionCreateHandler({ wanling_conv_id: "conv-1" }, ctx),
    ).rejects.toThrow("SDK timeout")
  })
})
