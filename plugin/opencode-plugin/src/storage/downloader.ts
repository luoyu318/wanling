import { join } from "path"
import { mkdir, readdir, writeFile } from "fs/promises"
import { probeByName } from "../file/probe.js"

export interface DownloadOptions {
  fileId: string
  expectedExt?: string
}

export interface DownloadResult {
  path: string
  mime: string
  filename: string
}

export class DownloadError extends Error {
  constructor(
    message: string,
    public readonly code: "network" | "http_error" | "too_large" | "write_failed",
  ) {
    super(message)
    this.name = "DownloadError"
  }
}

const SAFE_EXT = new Set([
  ".png", ".jpg", ".jpeg", ".gif", ".webp",
  ".pdf", ".txt", ".md", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx", ".csv", ".json",
  ".zip", ".tar", ".gz", ".bin",
])

function guessSafeExt(raw: string | undefined): string {
  if (!raw) return ".bin"
  const normalized = raw.toLowerCase().startsWith(".") ? raw.toLowerCase() : `.${raw.toLowerCase()}`
  return SAFE_EXT.has(normalized) ? normalized : ".bin"
}

function guessExtFromContentDisposition(cd: string): string | null {
  // 形如: attachment; filename="foo.png" 或 attachment; filename*=UTF-8''foo.png
  const m = cd.match(/filename\*?=(?:UTF-8'')?["']?([^"';]+)/i)
  if (!m) return null
  const name = m[1] as string
  const dot = name.lastIndexOf(".")
  if (dot < 0) return null
  const ext = name.slice(dot).toLowerCase()
  return SAFE_EXT.has(ext) ? ext : ".bin"
}

function isMimeUsable(mime: string): boolean {
  if (!mime) return false
  const lower = mime.toLowerCase()
  // 排除 generic octet-stream(没信息量),让 probe 兜底
  return !lower.includes("application/octet-stream")
}

export class WanlingDownloader {
  constructor(
    private readonly config: {
      baseUrl: string
      tokenProvider: () => Promise<string>
      cacheDir: string
      maxBytes: number
    },
  ) {}

  async download(opts: DownloadOptions): Promise<DownloadResult> {
    // fileId 防穿越校验:server 端发 UUID,此处防御性锁定不变量,
    // 拒绝含 / .. 空格 等字符的输入(避免拼进 URL 或落盘文件名)。
    if (!/^[\w-]+$/.test(opts.fileId)) {
      throw new DownloadError(`invalid fileId: ${opts.fileId}`, "http_error")
    }
    const { fileId } = opts
    const cacheDir = this.config.cacheDir

    try {
      await mkdir(cacheDir, { recursive: true })
    } catch (e) {
      throw new DownloadError(
        `write failed (mkdir): ${e instanceof Error ? e.message : String(e)}`,
        "write_failed",
      )
    }

    // 1. 幂等:扫缓存目录看 <fileId>.* 是否已存在
    const existing = await this.findCached(fileId)
    if (existing) {
      return existing
    }

    // 2. HTTP GET,带 JWT
    const token = await this.config.tokenProvider()
    const url = `${this.config.baseUrl.replace(/\/+$/, "")}/api/files/${fileId}`
    let resp: Response
    try {
      resp = await fetch(url, {
        headers: { Authorization: `Bearer ${token}` },
      })
    } catch (e) {
      throw new DownloadError(
        `fetch failed: ${e instanceof Error ? e.message : String(e)}`,
        "network",
      )
    }

    if (!resp.ok) {
      throw new DownloadError(`http ${resp.status} for ${fileId}`, "http_error")
    }

    // 3. 大小预检:Content-Length
    const declaredSize = Number(resp.headers.get("content-length") ?? 0)
    if (declaredSize > this.config.maxBytes) {
      throw new DownloadError(
        `file too large: declared ${declaredSize} > ${this.config.maxBytes}`,
        "too_large",
      )
    }

    // 4. 落盘到 buffer,二次校验实际大小
    const buf = Buffer.from(await resp.arrayBuffer())
    if (buf.byteLength > this.config.maxBytes) {
      throw new DownloadError(
        `file too large: actual ${buf.byteLength} > ${this.config.maxBytes}`,
        "too_large",
      )
    }

    // 5. 扩展名猜测:Content-Disposition filename → expectedExt → .bin
    const cd = resp.headers.get("content-disposition") || ""
    const ext = guessExtFromContentDisposition(cd) ?? guessSafeExt(opts.expectedExt)

    const filename = `${fileId}${ext}`
    const absPath = join(cacheDir, filename)
    try {
      await writeFile(absPath, buf)
    } catch (e) {
      throw new DownloadError(
        `write failed: ${e instanceof Error ? e.message : String(e)}`,
        "write_failed",
      )
    }

    // 6. MIME:server Content-Type 优先,否则 probeByName
    const serverMime = resp.headers.get("content-type") || ""
    const mime = isMimeUsable(serverMime)
      ? serverMime.split(";")[0].trim()
      : probeByName(filename).mime

    return { path: absPath, mime, filename }
  }

  private async findCached(fileId: string): Promise<DownloadResult | null> {
    let entries: string[]
    try {
      entries = await readdir(this.config.cacheDir)
    } catch {
      return null
    }
    const prefix = `${fileId}.`
    const hit = entries.find((e) => e.startsWith(prefix))
    if (!hit) return null
    const path = join(this.config.cacheDir, hit)
    const probed = probeByName(hit)
    return { path, mime: probed.mime, filename: hit }
  }
}
