import { extname } from "path"
import { open } from "fs/promises"

export type FileKind = "text" | "image" | "binary"

export type ProbedFile = {
  kind: FileKind
  mime: string
}

const TEXT_MIME: Record<string, string> = {
  ".ts": "text/x-typescript",
  ".tsx": "text/x-typescript",
  ".js": "text/javascript",
  ".jsx": "text/javascript",
  ".json": "application/json",
  ".md": "text/markdown",
  ".go": "text/x-go",
  ".py": "text/x-python",
  ".rs": "text/x-rust",
  ".java": "text/x-java",
  ".kt": "text/x-kotlin",
  ".c": "text/x-c",
  ".h": "text/x-c",
  ".cpp": "text/x-c++",
  ".hpp": "text/x-c++",
  ".css": "text/css",
  ".html": "text/html",
  ".yaml": "text/yaml",
  ".yml": "text/yaml",
  ".toml": "text/x-toml",
  ".ini": "text/x-ini",
  ".sh": "text/x-shellscript",
  ".bash": "text/x-shellscript",
  ".zsh": "text/x-shellscript",
  ".sql": "text/x-sql",
  ".txt": "text/plain",
  ".lock": "text/plain",
  ".dart": "text/x-dart",
  ".xml": "application/xml",
  ".svg": "image/svg+xml",
  ".csv": "text/csv",
  ".log": "text/plain",
  ".env": "text/plain",
}

const IMAGE_EXT = new Set([
  ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".ico",
])

const IMAGE_MIME: Record<string, string> = {
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".png": "image/png",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".bmp": "image/bmp",
  ".ico": "image/x-icon",
}

const KNOWN_BINARY_EXT = new Set([
  ".zip", ".tar", ".gz", ".tgz", ".rar", ".7z", ".bz2", ".xz", ".iso",
  ".exe", ".dll", ".so", ".dylib", ".o", ".a", ".class", ".jar", ".war",
  ".pyc", ".wasm", ".bin", ".dat",
  ".mp3", ".mp4", ".avi", ".mov", ".mkv", ".wav", ".flac", ".ogg",
  ".woff", ".woff2", ".ttf", ".otf",
  ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
  ".db", ".sqlite", ".mdb",
])

const PROBE_BYTES = 8192

export function probeByName(name: string): ProbedFile {
  const base = name.split("/").pop() ?? name
  const ext = extname(base).toLowerCase()

  if (IMAGE_EXT.has(ext)) {
    return { kind: "image", mime: IMAGE_MIME[ext] ?? "application/octet-stream" }
  }
  if (KNOWN_BINARY_EXT.has(ext)) {
    return { kind: "binary", mime: "application/octet-stream" }
  }
  return { kind: "text", mime: TEXT_MIME[ext] ?? "text/plain" }
}

export async function probeByContent(
  name: string,
  fsPath: string,
): Promise<ProbedFile> {
  const byName = probeByName(name)
  if (byName.kind === "image") return byName
  if (byName.kind === "binary") return byName

  const buf = Buffer.alloc(PROBE_BYTES)
  let fd: Awaited<ReturnType<typeof open>> | undefined
  try {
    fd = await open(fsPath, "r")
    const { bytesRead } = await fd.read(buf, 0, PROBE_BYTES, 0)
    for (let i = 0; i < bytesRead; i++) {
      if (buf[i] === 0) {
        return { kind: "binary", mime: "application/octet-stream" }
      }
    }
    return byName
  } catch {
    return byName
  } finally {
    if (fd) await fd.close()
  }
}

export { probeByName as probeFile }
