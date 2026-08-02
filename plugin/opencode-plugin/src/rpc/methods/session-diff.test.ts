import { describe, it, expect, vi, beforeEach } from "vitest"

vi.mock("../../sync/mapper.js", () => ({
  getSessionMap: vi.fn(),
}))

vi.mock("../../git/diff.js", () => ({
  computeDiff: vi.fn(),
}))

import { sessionDiffHandler } from "./session-diff.js"
import { getSessionMap } from "../../sync/mapper.js"
import { computeDiff } from "../../git/diff.js"
import { GitError } from "../../git/runner.js"

const mockComputeDiff = vi.mocked(computeDiff)

function makeCtx(directory = "/path/to/proj") {
  const sessionGet = vi.fn().mockResolvedValue({ data: { directory } })
  const client = { session: { get: sessionGet } } as any
  return { getClient: () => client, sessionGet }
}

function mockMap() {
  vi.mocked(getSessionMap).mockReturnValue({
    wanlingConvId: "conv-1",
    opencodeSessionId: "oc-sess-1",
    lastSyncAt: "2026-07-20T00:00:00Z",
    messageCount: 0,
  })
}

describe("session.diff handler (git-backed)", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("map 存在 + directory 存在 + computeDiff 返 2 文件 → result.files 完整透传", async () => {
    mockMap()
    mockComputeDiff.mockResolvedValue({
      files: [
        { file: "main.go", patch: "@@ -1 +1 @@", additions: 5, deletions: 2, status: "modified" },
        { file: "old.go", patch: "", additions: 0, deletions: 10, status: "deleted" },
      ],
    })

    const result = await sessionDiffHandler({ wanling_conv_id: "conv-1" }, makeCtx())

    expect(result.files).toHaveLength(2)
    expect(mockComputeDiff).toHaveBeenCalledWith("/path/to/proj")
  })

  it("params 缺 wanling_conv_id → 抛 RPCError(-32602)", async () => {
    await expect(
      sessionDiffHandler({}, makeCtx()),
    ).rejects.toMatchObject({ code: -32602 })
  })

  it("params wanling_conv_id 非字符串 → 抛 RPCError(-32602)", async () => {
    await expect(
      sessionDiffHandler({ wanling_conv_id: 123 }, makeCtx()),
    ).rejects.toMatchObject({ code: -32602 })
  })

  it("map 不存在 → 抛 RPCError(-32601) session not created", async () => {
    vi.mocked(getSessionMap).mockReturnValue(undefined)

    await expect(
      sessionDiffHandler({ wanling_conv_id: "conv-x" }, makeCtx()),
    ).rejects.toMatchObject({ code: -32601, message: "session not created" })
  })

  it("OC session.directory 空 → 抛 RPCError(-32603) directory not anchored", async () => {
    mockMap()
    const ctx = makeCtx("")

    await expect(
      sessionDiffHandler({ wanling_conv_id: "conv-1" }, ctx),
    ).rejects.toMatchObject({ code: -32603, message: "directory not anchored" })
  })

  it("computeDiff 抛 GitError → 转 RPCError(-32604)", async () => {
    mockMap()
    mockComputeDiff.mockRejectedValue(
      new GitError(128, "not a git repository", "git rev-parse failed: exit 128"),
    )
    const ctx = makeCtx("/not-a-repo")

    await expect(
      sessionDiffHandler({ wanling_conv_id: "conv-1" }, ctx),
    ).rejects.toMatchObject({ code: -32604, message: expect.stringContaining("git error") })
  })

  it("computeDiff 抛非 GitError → 透传(给 dispatcher 走 -32603)", async () => {
    mockMap()
    const otherErr = new Error("filesystem exploded")
    mockComputeDiff.mockRejectedValue(otherErr)
    const ctx = makeCtx("/proj")

    await expect(
      sessionDiffHandler({ wanling_conv_id: "conv-1" }, ctx),
    ).rejects.toBe(otherErr)
  })
})
