import { describe, it, expect, vi, beforeEach } from "vitest"

vi.mock("../../sync/mapper.js", () => ({
  getSessionMap: vi.fn(),
}))

vi.mock("fs", async (importActual) => {
  const actual = await importActual<typeof import("fs")>()
  return {
    ...actual,
    statSync: vi.fn(),
  }
})

vi.mock("fs/promises", async (importActual) => {
  const actual = await importActual<typeof import("fs/promises")>()
  return {
    ...actual,
    readFile: vi.fn(),
    open: vi.fn(),
  }
})

import { fileReadHandler } from "./file-read.js"
import { getSessionMap } from "../../sync/mapper.js"
import { readFile, open } from "fs/promises"
import { statSync } from "fs"

function makeCtx(directory = "/proj") {
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

describe("file.read handler", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(statSync).mockReturnValue({ size: 100 } as any)
    vi.mocked(open).mockResolvedValue({
      read: async (buf: Buffer) => {
        const sample = Buffer.from("text")
        sample.copy(buf, 0)
        return { bytesRead: sample.length, buffer: buf }
      },
      close: async () => {},
    } as any)
  })

  it("文本文件 → type=text + content + mime", async () => {
    mockMap()
    vi.mocked(readFile).mockResolvedValue("hello world\n" as any)

    const result = await fileReadHandler({
      wanling_conv_id: "conv-1",
      path: "README.md",
    }, makeCtx())

    expect(result).toMatchObject({
      path: "README.md",
      type: "text",
      mime: "text/markdown",
      size: 100,
      content: "hello world\n",
      truncated: false,
    })
  })

  it("文本超过 max_bytes → 截断 + truncated true", async () => {
    mockMap()
    const longText = "a".repeat(300)
    vi.mocked(readFile).mockResolvedValue(longText as any)

    const result = await fileReadHandler({
      wanling_conv_id: "conv-1",
      path: "big.txt",
      max_bytes: 100,
    }, makeCtx()) as any

    expect(result.content.length).toBe(100)
    expect(result.truncated).toBe(true)
  })

  it("max_bytes 缺省 → 用默认 262144", async () => {
    mockMap()
    const text = "small"
    vi.mocked(readFile).mockResolvedValue(text as any)

    const result = await fileReadHandler({
      wanling_conv_id: "conv-1",
      path: "x.txt",
    }, makeCtx()) as any

    expect(result.truncated).toBe(false)
  })

  it("max_bytes 超 512KB → 钳到 512KB", async () => {
    mockMap()
    vi.mocked(readFile).mockResolvedValue("x" as any)

    await fileReadHandler({
      wanling_conv_id: "conv-1",
      path: "x.txt",
      max_bytes: 999999,
    }, makeCtx())

    expect(vi.mocked(readFile)).toHaveBeenCalledWith(
      expect.any(String),
      expect.objectContaining({ encoding: "utf-8" }),
    )
  })

  it("图片(.png)→ type=image + content_base64", async () => {
    mockMap()
    vi.mocked(readFile).mockResolvedValue(Buffer.from([0x89, 0x50, 0x4e, 0x47]) as any)

    const result = await fileReadHandler({
      wanling_conv_id: "conv-1",
      path: "logo.png",
    }, makeCtx()) as any

    expect(result.type).toBe("image")
    expect(result.mime).toBe("image/png")
    expect(typeof result.content_base64).toBe("string")
    expect(result.size).toBe(100)
  })

  it("图片 > 384KB → 抛 RPCError(-32605)", async () => {
    mockMap()
    vi.mocked(statSync).mockReturnValue({ size: 500 * 1024 } as any)

    await expect(
      fileReadHandler({ wanling_conv_id: "conv-1", path: "big.png" }, makeCtx()),
    ).rejects.toMatchObject({ code: -32605 })
  })

  it("二进制(.zip)→ type=binary 不读内容", async () => {
    mockMap()
    vi.mocked(statSync).mockReturnValue({ size: 9999 } as any)

    const result = await fileReadHandler({
      wanling_conv_id: "conv-1",
      path: "archive.zip",
    }, makeCtx()) as any

    expect(result.type).toBe("binary")
    expect(result.mime).toBe("application/octet-stream")
    expect(result.size).toBe(9999)
    expect(result.content).toBeUndefined()
    expect(result.content_base64).toBeUndefined()
    expect(vi.mocked(readFile)).not.toHaveBeenCalled()
  })

  it("params 缺 wanling_conv_id → 抛 RPCError(-32602)", async () => {
    await expect(
      fileReadHandler({ path: "x.txt" }, makeCtx()),
    ).rejects.toMatchObject({ code: -32602 })
  })

  it("params 缺 path → 抛 RPCError(-32602)", async () => {
    await expect(
      fileReadHandler({ wanling_conv_id: "conv-1" }, makeCtx()),
    ).rejects.toMatchObject({ code: -32602 })
  })

  it("map 不存在 → 抛 RPCError(-32601)", async () => {
    vi.mocked(getSessionMap).mockReturnValue(undefined)

    await expect(
      fileReadHandler({ wanling_conv_id: "conv-x", path: "x.txt" }, makeCtx()),
    ).rejects.toMatchObject({ code: -32601 })
  })

  it("OC session.directory 空 → 抛 RPCError(-32603)", async () => {
    mockMap()
    const ctx = makeCtx("")

    await expect(
      fileReadHandler({ wanling_conv_id: "conv-1", path: "x.txt" }, ctx),
    ).rejects.toMatchObject({ code: -32603 })
  })

  it("path 越界('../etc')→ 抛 RPCError(-32602)", async () => {
    mockMap()

    await expect(
      fileReadHandler({ wanling_conv_id: "conv-1", path: "../etc/passwd" }, makeCtx()),
    ).rejects.toMatchObject({ code: -32602 })
  })

  it("readFile 抛 ENOENT → 抛 RPCError(-32605)", async () => {
    mockMap()
    const err: NodeJS.ErrnoException = new Error("ENOENT")
    err.code = "ENOENT"
    vi.mocked(readFile).mockRejectedValue(err)

    await expect(
      fileReadHandler({ wanling_conv_id: "conv-1", path: "missing.txt" }, makeCtx()),
    ).rejects.toMatchObject({ code: -32605 })
  })

  it("path 为绝对路径(在 directory 下)→ 不翻倍,正确读取", async () => {
    // 回归:join(absCwd, filePath) 遇到绝对路径 filePath 会原样拼接导致路径翻倍。
    // resolve(absCwd, filePath) 遇到绝对路径会重置,行为正确。
    // 此测试确保 readFile 收到的路径不再翻倍。
    mockMap()
    vi.mocked(readFile).mockResolvedValue("ok" as any)

    await fileReadHandler({
      wanling_conv_id: "conv-1",
      path: "/proj/src/a.txt",
    }, makeCtx("/proj"))

    expect(vi.mocked(readFile)).toHaveBeenCalledWith(
      "/proj/src/a.txt",
      expect.objectContaining({ encoding: "utf-8" }),
    )
  })
})
