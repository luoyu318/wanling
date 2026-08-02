import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { WanlingDownloader, type DownloadResult } from "./downloader.js"
import { mkdtempSync, rmSync, writeFileSync } from "fs"
import { tmpdir } from "os"
import { join } from "path"

// 仅 mock writeFile(mkdir/readdir 保持真实),供 write_failed 用例注入失败。
// 其余用例下 writeFile 默认 resolve undefined,不落盘也不影响断言(无 on-disk 校验)。
vi.mock("fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("fs/promises")>()
  return { ...actual, writeFile: vi.fn() }
})

let TMP = ""

beforeEach(() => {
  TMP = mkdtempSync(join(tmpdir(), "wl-dl-"))
})
afterEach(() => {
  rmSync(TMP, { recursive: true, force: true })
})

function makeDownloader() {
  return new WanlingDownloader({
    baseUrl: "http://localhost:18008",
    tokenProvider: async () => "fake-jwt",
    cacheDir: TMP,
    maxBytes: 20 * 1024 * 1024,
  })
}

describe("WanlingDownloader 构造", () => {
  it("接受 baseUrl/tokenProvider/cacheDir 三参数", () => {
    const d = new WanlingDownloader({
      baseUrl: "http://localhost:18008",
      tokenProvider: async () => "fake-jwt",
      cacheDir: "/tmp/wl-test-cache",
      maxBytes: 20 * 1024 * 1024,
    })
    expect(d).toBeInstanceOf(WanlingDownloader)
  })
})

describe("WanlingDownloader 幂等", () => {
  it("缓存目录已存在 <fileId>.* 时直接返回,不调 fetch", async () => {
    writeFileSync(join(TMP, "file-abc.png"), Buffer.from("already here"))
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response("should-not-be-used", { status: 200 }),
    )
    const d = makeDownloader()

    const r: DownloadResult = await d.download({ fileId: "file-abc" })

    expect(r.path).toBe(join(TMP, "file-abc.png"))
    expect(fetchSpy).not.toHaveBeenCalled()
    fetchSpy.mockRestore()
  })
})

describe("WanlingDownloader 正常下载", () => {
  it("server 返回 image/png + Content-Disposition,落盘到缓存", async () => {
    const body = Buffer.from("fake-png-bytes")
    const fetchSpy = vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(body, {
        status: 200,
        headers: {
          "content-type": "image/png",
          "content-disposition": 'attachment; filename="cat.png"',
          "content-length": String(body.byteLength),
        },
      }),
    )
    const d = makeDownloader()

    const r = await d.download({ fileId: "fid-1" })

    expect(r.filename).toBe("fid-1.png")
    expect(r.mime).toBe("image/png")
    expect(r.path).toBe(join(TMP, "fid-1.png"))
    // Authorization 头带上 JWT
    expect(fetchSpy.mock.calls[0]![1]!.headers).toEqual({ Authorization: "Bearer fake-jwt" })
    fetchSpy.mockRestore()
  })

  it("Content-Type 是 octet-stream 时退到 probeByName 兜底", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(Buffer.from("xyz"), {
        status: 200,
        headers: {
          "content-type": "application/octet-stream",
          "content-disposition": 'attachment; filename="data.json"',
          "content-length": "3",
        },
      }),
    )
    const d = makeDownloader()
    const r = await d.download({ fileId: "fid-2" })
    expect(r.mime).toBe("application/json")
  })
})

describe("WanlingDownloader 扩展名解析", () => {
  it("Content-Disposition 扩展名不在白名单(如 .exe)落 .bin", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(Buffer.from("x"), {
        status: 200,
        headers: {
          "content-type": "application/octet-stream",
          "content-disposition": 'attachment; filename="evil.exe"',
          "content-length": "1",
        },
      }),
    )
    const d = makeDownloader()
    const r = await d.download({ fileId: "fid-3" })
    expect(r.filename).toBe("fid-3.bin")
  })

  it("Content-Disposition 缺失时用 expectedExt 兜底", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(Buffer.from("x"), {
        status: 200,
        headers: { "content-type": "application/pdf", "content-length": "1" },
      }),
    )
    const d = makeDownloader()
    const r = await d.download({ fileId: "fid-4", expectedExt: ".pdf" })
    expect(r.filename).toBe("fid-4.pdf")
  })

  it("Content-Disposition 和 expectedExt 都缺时落 .bin", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(Buffer.from("x"), {
        status: 200,
        headers: { "content-type": "application/octet-stream", "content-length": "1" },
      }),
    )
    const d = makeDownloader()
    const r = await d.download({ fileId: "fid-5" })
    expect(r.filename).toBe("fid-5.bin")
  })
})

describe("WanlingDownloader 错误路径", () => {
  it("Content-Length 超 20MB 抛 too_large", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response("", {
        status: 200,
        headers: { "content-length": String(20 * 1024 * 1024 + 1) },
      }),
    )
    const d = makeDownloader()
    await expect(d.download({ fileId: "big" })).rejects.toMatchObject({
      code: "too_large",
    })
  })

  it("HTTP 404 抛 http_error", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response("not found", { status: 404 }))
    const d = makeDownloader()
    await expect(d.download({ fileId: "missing" })).rejects.toMatchObject({
      code: "http_error",
    })
  })

  it("fetch 网络异常抛 network", async () => {
    vi.spyOn(globalThis, "fetch").mockRejectedValue(new Error("ECONNREFUSED"))
    const d = makeDownloader()
    await expect(d.download({ fileId: "fid-net" })).rejects.toMatchObject({
      code: "network",
    })
  })

  it("fileId 含路径分隔符抛 http_error (防穿越)", async () => {
    const d = makeDownloader()
    await expect(d.download({ fileId: "../../etc/passwd" })).rejects.toMatchObject({
      code: "http_error",
    })
  })

  it("writeFile 失败(磁盘满/权限)抛 write_failed", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      new Response(Buffer.from("x"), {
        status: 200,
        headers: { "content-type": "image/png", "content-length": "1" },
      }),
    )
    // mock writeFile 抛 EACCES(替代依赖不存在的路径,消除 root 环境差异)
    const { writeFile: mockedWrite } = await import("fs/promises")
    vi.mocked(mockedWrite).mockRejectedValueOnce(new Error("EACCES"))
    const d = makeDownloader()
    await expect(d.download({ fileId: "fid-wf" })).rejects.toMatchObject({
      code: "write_failed",
    })
  })
})

describe("WanlingDownloader maxBytes 配置", () => {
  it("实际大小超 maxBytes 抛 too_large", async () => {
    const dl = new WanlingDownloader({
      baseUrl: "http://localhost:18008",
      tokenProvider: async () => "fake-jwt",
      cacheDir: TMP,
      maxBytes: 1024,
    })
    const big = Buffer.alloc(2048, 0x41)
    vi.spyOn(globalThis, "fetch").mockResolvedValue({
      ok: true,
      headers: new Headers({ "content-length": "2048" }),
      arrayBuffer: () => Promise.resolve(big.buffer.slice(big.byteOffset, big.byteOffset + big.byteLength)),
    } as Response)
    await expect(dl.download({ fileId: "big-file" })).rejects.toMatchObject({
      code: "too_large",
    })
  })
})
