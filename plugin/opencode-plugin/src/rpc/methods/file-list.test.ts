import { describe, it, expect, vi, beforeEach } from "vitest"

vi.mock("../../sync/mapper.js", () => ({
  getSessionMap: vi.fn(),
}))

vi.mock("../../git/file-tree.js", () => ({
  listDirectory: vi.fn(),
}))

import { fileListHandler } from "./file-list.js"
import { fetchSessionDirectory } from "../utils.js"
import { getSessionMap } from "../../sync/mapper.js"
import { listDirectory } from "../../git/file-tree.js"
import { GitError } from "../../git/runner.js"

const mockListDirectory = vi.mocked(listDirectory)

function makeCtx(directory = "/proj") {
  const sessionGet = vi.fn().mockResolvedValue({
    data: { directory },
  })
  const client = { session: { get: sessionGet } } as any
  return { getClient: () => client, sessionGet }
}

function mockMap(_directory?: string) {
  vi.mocked(getSessionMap).mockReturnValue({
    wanlingConvId: "conv-1",
    opencodeSessionId: "oc-sess-1",
    lastSyncAt: "2026-07-20T00:00:00Z",
    messageCount: 0,
  })
}

describe("file.list handler", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("map 存在 + directory 存在 → 透传 listDirectory 结果,root=directory", async () => {
    mockMap()
    mockListDirectory.mockResolvedValue({
      entries: [
        { name: "src", type: "dir", size: 0 },
        { name: "README.md", type: "file", size: 100 },
      ],
      truncated: false,
    })
    const ctx = makeCtx("/proj")

    const result = await fileListHandler({ wanling_conv_id: "conv-1", path: "." }, ctx)

    expect(result).toEqual({
      root: "/proj",
      path: ".",
      entries: [
        { name: "src", type: "dir", size: 0 },
        { name: "README.md", type: "file", size: 100 },
      ],
      truncated: false,
    })
    expect(ctx.sessionGet).toHaveBeenCalledWith({ sessionID: "oc-sess-1" })
    expect(mockListDirectory).toHaveBeenCalledWith("/proj", ".")
  })

  it("path 缺省 → 默认 '.'", async () => {
    mockMap()
    mockListDirectory.mockResolvedValue({ entries: [], truncated: false })
    const ctx = makeCtx("/proj")

    await fileListHandler({ wanling_conv_id: "conv-1" }, ctx)

    expect(mockListDirectory).toHaveBeenCalledWith("/proj", ".")
  })

  it("path 显式传 'src' → 透传给 listDirectory", async () => {
    mockMap()
    mockListDirectory.mockResolvedValue({ entries: [], truncated: false })
    const ctx = makeCtx("/proj")

    await fileListHandler({ wanling_conv_id: "conv-1", path: "src" }, ctx)

    expect(mockListDirectory).toHaveBeenCalledWith("/proj", "src")
  })

  it("params 缺 wanling_conv_id → 抛 RPCError(-32602)", async () => {
    await expect(
      fileListHandler({}, makeCtx()),
    ).rejects.toMatchObject({ code: -32602 })
  })

  it("wanling_conv_id 非字符串 → 抛 RPCError(-32602)", async () => {
    await expect(
      fileListHandler({ wanling_conv_id: 123 }, makeCtx()),
    ).rejects.toMatchObject({ code: -32602 })
  })

  it("map 不存在 → 抛 RPCError(-32601)", async () => {
    vi.mocked(getSessionMap).mockReturnValue(undefined)

    await expect(
      fileListHandler({ wanling_conv_id: "conv-x" }, makeCtx()),
    ).rejects.toMatchObject({ code: -32601, message: "session not created" })
  })

  it("OC session.directory 空 → 抛 RPCError(-32603)", async () => {
    mockMap()
    const ctx = makeCtx("")

    await expect(
      fileListHandler({ wanling_conv_id: "conv-1" }, ctx),
    ).rejects.toMatchObject({ code: -32603, message: "directory not anchored" })
  })

  it("listDirectory 抛 GitError → 转 RPCError(-32604)", async () => {
    mockMap()
    mockListDirectory.mockRejectedValue(
      new GitError(128, "not a git repository", "git rev-parse failed: exit 128"),
    )
    const ctx = makeCtx("/not-a-repo")

    await expect(
      fileListHandler({ wanling_conv_id: "conv-1" }, ctx),
    ).rejects.toMatchObject({ code: -32604, message: expect.stringContaining("git error") })
  })

  it("listDirectory 抛 RPCError(-32602 越界)→ 透传", async () => {
    mockMap()
    const { RPCError } = await import("../types.js")
    mockListDirectory.mockRejectedValue(new RPCError(-32602, "path escapes session.directory"))
    const ctx = makeCtx("/proj")

    await expect(
      fileListHandler({ wanling_conv_id: "conv-1", path: "../etc/passwd" }, ctx),
    ).rejects.toMatchObject({ code: -32602 })
  })

  it("listDirectory 抛非 Git 非 RPCError → 透传", async () => {
    mockMap()
    const otherErr = new Error("fs exploded")
    mockListDirectory.mockRejectedValue(otherErr)
    const ctx = makeCtx("/proj")

    await expect(
      fileListHandler({ wanling_conv_id: "conv-1" }, ctx),
    ).rejects.toBe(otherErr)
  })
})

describe("fetchSessionDirectory", () => {
  it("client null → 返空串", async () => {
    const got = await fetchSessionDirectory(() => null, "sess-1")
    expect(got).toBe("")
  })

  it("session.get 抛错 → 返空串", async () => {
    const sessionGet = vi.fn().mockRejectedValue(new Error("network"))
    const client = { session: { get: sessionGet } } as any
    const got = await fetchSessionDirectory(() => client, "sess-1")
    expect(got).toBe("")
  })

  it("session.get 成功 → 返 directory", async () => {
    const sessionGet = vi.fn().mockResolvedValue({ data: { directory: "/path" } })
    const client = { session: { get: sessionGet } } as any
    const got = await fetchSessionDirectory(() => client, "sess-1")
    expect(got).toBe("/path")
    expect(sessionGet).toHaveBeenCalledWith({ sessionID: "sess-1" })
  })
})
