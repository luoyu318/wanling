import { describe, it, expect, vi, beforeEach } from "vitest"

vi.mock("fs/promises", async (importActual) => {
  const actual = await importActual<typeof import("fs/promises")>()
  return {
    ...actual,
    open: vi.fn(),
  }
})

import { open } from "fs/promises"
import { probeByName, probeByContent } from "./probe.js"

function mockOpenBytes(bytes: Buffer): void {
  vi.mocked(open).mockResolvedValue({
    read: async (buf: Buffer) => {
      bytes.copy(buf, 0)
      return { bytesRead: bytes.length, buffer: buf }
    },
    close: vi.fn().mockResolvedValue(undefined),
  } as any)
}

describe("probeByName", () => {
  it("文本扩展名(.ts)→ text/x-typescript", () => {
    expect(probeByName("main.ts")).toEqual({ kind: "text", mime: "text/x-typescript" })
  })

  it("文本扩展名(.md)→ text/markdown", () => {
    expect(probeByName("README.md")).toEqual({ kind: "text", mime: "text/markdown" })
  })

  it("文本扩展名(.go)→ text/x-go", () => {
    expect(probeByName("main.go")).toEqual({ kind: "text", mime: "text/x-go" })
  })

  it(".dart → text/x-dart（修复 dart 被误判 binary）", () => {
    expect(probeByName("widget.dart")).toEqual({ kind: "text", mime: "text/x-dart" })
  })

  it(".xml → application/xml", () => {
    expect(probeByName("pom.xml")).toEqual({ kind: "text", mime: "application/xml" })
  })

  it(".svg → text + image/svg+xml（svg 是文本格式）", () => {
    expect(probeByName("icon.svg")).toEqual({ kind: "text", mime: "image/svg+xml" })
  })

  it("图片扩展名(.png)→ image/png", () => {
    expect(probeByName("logo.png")).toEqual({ kind: "image", mime: "image/png" })
  })

  it("图片扩展名(.jpg)→ image/jpeg", () => {
    expect(probeByName("photo.jpg")).toEqual({ kind: "image", mime: "image/jpeg" })
  })

  it("图片扩展名(.ico)→ image/x-icon", () => {
    expect(probeByName("favicon.ico")).toEqual({ kind: "image", mime: "image/x-icon" })
  })

  it("大写扩展名自动 lowercase(.PNG)→ image/png", () => {
    expect(probeByName("PHOTO.PNG")).toEqual({ kind: "image", mime: "image/png" })
  })

  it(".zip → binary", () => {
    expect(probeByName("archive.zip")).toEqual({ kind: "binary", mime: "application/octet-stream" })
  })

  it(".exe → binary", () => {
    expect(probeByName("setup.exe")).toEqual({ kind: "binary", mime: "application/octet-stream" })
  })

  it(".wasm → binary", () => {
    expect(probeByName("module.wasm")).toEqual({ kind: "binary", mime: "application/octet-stream" })
  })

  it("未知扩展名(.xyz)→ text（默认放行，避免误判）", () => {
    expect(probeByName("data.xyz")).toEqual({ kind: "text", mime: "text/plain" })
  })

  it("无扩展名(Makefile)→ text/plain", () => {
    expect(probeByName("Makefile")).toEqual({ kind: "text", mime: "text/plain" })
  })

  it("路径形式(a/b/c.tsx)只看末段扩展名", () => {
    expect(probeByName("src/components/Button.tsx")).toEqual({ kind: "text", mime: "text/x-typescript" })
  })

  it(".gitignore → text/plain", () => {
    expect(probeByName(".gitignore")).toEqual({ kind: "text", mime: "text/plain" })
  })
})

describe("probeByContent", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("image 后缀(.png)→ 直接返回 image，不读字节", async () => {
    mockOpenBytes(Buffer.from([0x00]))
    const result = await probeByContent("logo.png", "/proj/logo.png")
    expect(result).toEqual({ kind: "image", mime: "image/png" })
    expect(open).not.toHaveBeenCalled()
  })

  it("KNOWN_BINARY_EXT(.zip)→ 直接返回 binary，不读字节", async () => {
    mockOpenBytes(Buffer.from([0x00]))
    const result = await probeByContent("a.zip", "/proj/a.zip")
    expect(result).toEqual({ kind: "binary", mime: "application/octet-stream" })
    expect(open).not.toHaveBeenCalled()
  })

  it(".dart 文件 ASCII 内容 → text/x-dart", async () => {
    mockOpenBytes(Buffer.from("void main() {}\n"))
    const result = await probeByContent("main.dart", "/proj/main.dart")
    expect(result).toEqual({ kind: "text", mime: "text/x-dart" })
    expect(open).toHaveBeenCalledTimes(1)
  })

  it("未知扩展名 + ASCII → text", async () => {
    mockOpenBytes(Buffer.from("just some plain text"))
    const result = await probeByContent("data.xyz", "/proj/data.xyz")
    expect(result).toEqual({ kind: "text", mime: "text/plain" })
  })

  it("未知扩展名 + NUL 字节 → binary", async () => {
    mockOpenBytes(Buffer.from([0x41, 0x42, 0x00, 0x43]))
    const result = await probeByContent("data.xyz", "/proj/data.xyz")
    expect(result).toEqual({ kind: "binary", mime: "application/octet-stream" })
  })

  it("读完后关闭 fd 防资源泄漏", async () => {
    const closeFn = vi.fn().mockResolvedValue(undefined)
    vi.mocked(open).mockResolvedValue({
      read: async (buf: Buffer) => ({ bytesRead: 0, buffer: buf }),
      close: closeFn,
    } as any)
    await probeByContent("x.xyz", "/proj/x.xyz")
    expect(closeFn).toHaveBeenCalledTimes(1)
  })

  it("open 抛错(ENOENT) → fallback 到 byName，不冒泡", async () => {
    const err = Object.assign(new Error("ENOENT: no such file"), {
      code: "ENOENT",
    })
    vi.mocked(open).mockRejectedValue(err)
    const result = await probeByContent("unknown.xyz", "/nonexistent/path")
    expect(result).toEqual({ kind: "text", mime: "text/plain" })
  })

  it("fd.read 抛错 → fallback 到 byName，fd 仍关闭", async () => {
    const closeFn = vi.fn().mockResolvedValue(undefined)
    const err = Object.assign(new Error("EIO"), { code: "EIO" })
    vi.mocked(open).mockResolvedValue({
      read: vi.fn().mockRejectedValue(err),
      close: closeFn,
    } as any)
    const result = await probeByContent("data.xyz", "/proj/data.xyz")
    expect(result).toEqual({ kind: "text", mime: "text/plain" })
    expect(closeFn).toHaveBeenCalledTimes(1)
  })
})
