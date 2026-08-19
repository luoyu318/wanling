import { closeSync, openSync, readFileSync, readSync } from "fs"
import { join } from "path"
import { runGit } from "./runner.js"

// 二进制嗅探读取的前缀字节数;单文件 patch 字节上限(超限截断,防大 payload 断连);
// 帧级总预算(480KB:512KB server 帧上限留 JSON 转义余量)
const BINARY_SNIFF_BYTES = 8000
const MAX_PATCH_BYTES = 256 * 1024
const MAX_TOTAL_FRAME_BYTES = 480 * 1024

export type FileDiff = {
  file: string
  patch: string
  additions: number
  deletions: number
  status: "added" | "modified" | "deleted"
  binary?: boolean
  truncated?: boolean
}

export type DiffResult = {
  files: FileDiff[]
}

function parseNumstatLine(line: string): { additions: number; deletions: number; file: string } | null {
  const parts = line.split("\t")
  if (parts.length !== 3) return null
  const [add, del, file] = parts
  if (add === "-" || del === "-") return null
  const additions = parseInt(add, 10)
  const deletions = parseInt(del, 10)
  if (Number.isNaN(additions) || Number.isNaN(deletions)) return null
  return { additions, deletions, file }
}

function mapStatus(s: string): "added" | "modified" | "deleted" {
  const head = s.charAt(0)
  if (head === "A") return "added"
  if (head === "D") return "deleted"
  return "modified"
}

function parseNameStatusLine(line: string): { status: string; file: string } | null {
  const m = line.match(/^(\w+)\t(.+)$/)
  if (!m) return null
  const [, status, file] = m
  if (status.startsWith("R") || status.startsWith("C")) {
    const idx = file.indexOf("\t")
    if (idx >= 0) return { status, file: file.slice(idx + 1) }
    return { status, file }
  }
  return { status, file }
}

function buildUntrackedPatch(content: string): { patch: string; additions: number } {
  const trimmed = content.endsWith("\n") ? content.slice(0, -1) : content
  if (trimmed === "") return { patch: "", additions: 0 }
  const lines = trimmed.split("\n")
  let patch = ""
  for (const line of lines) {
    patch += `+${line}\n`
  }
  return { patch, additions: lines.length }
}

// 嗅探只读前 8000 字节(fd 前缀读,不整读大文件):含 NUL 判二进制。
// 读失败(权限/消失)让异常上抛,由调用方 catch 跳过(保持既有行为,且绝不回退 utf-8 整读)
function sniffBinary(path: string): boolean {
  const fd = openSync(path, "r")
  try {
    const buf = Buffer.alloc(BINARY_SNIFF_BYTES)
    const read = readSync(fd, buf, 0, BINARY_SNIFF_BYTES, 0)
    return buf.subarray(0, read).includes(0)
  } finally {
    closeSync(fd)
  }
}

// patch 超限截断:按行边界截,末行追加省略提示,总字节数(含提示行)不超上限
function clampPatch(patch: string): { patch: string; truncated: boolean } {
  if (Buffer.byteLength(patch, "utf-8") <= MAX_PATCH_BYTES) return { patch, truncated: false }
  const totalLines = patch.endsWith("\n") ? patch.split("\n").length - 1 : patch.split("\n").length
  const suffix = `…(已截断,共 ${totalLines} 行)\n`
  const budget = Math.max(0, MAX_PATCH_BYTES - Buffer.byteLength(suffix, "utf-8"))
  const head = Buffer.from(patch, "utf-8").subarray(0, budget)
  const lastNl = head.lastIndexOf(0x0a)
  let body = lastNl > 0 ? head.subarray(0, lastNl + 1).toString("utf-8") : head.toString("utf-8")
  // 预算边界切断多字节字符时逐字符回退,保证字节不超
  while (body.length > 0 && Buffer.byteLength(body, "utf-8") > budget) {
    body = body.slice(0, -1)
  }
  return { patch: `${body}${suffix}`, truncated: true }
}

export async function computeDiff(cwd: string): Promise<DiffResult> {
  await runGit(["rev-parse", "--is-inside-work-tree"], { cwd })

  const numstat = await runGit(["diff", "--numstat", "HEAD"], { cwd })
  const tracked: Array<{ additions: number; deletions: number; file: string }> = []
  for (const line of numstat.stdout.split("\n")) {
    if (!line) continue
    const parsed = parseNumstatLine(line)
    if (parsed) tracked.push(parsed)
  }

  const nameStatus = await runGit(["diff", "--name-status", "HEAD"], { cwd })
  const statusMap = new Map<string, string>()
  for (const line of nameStatus.stdout.split("\n")) {
    if (!line) continue
    const parsed = parseNameStatusLine(line)
    if (parsed) statusMap.set(parsed.file, parsed.status)
  }

  const files: FileDiff[] = []
  for (const t of tracked) {
    const patchResp = await runGit(["diff", "HEAD", "--", t.file], { cwd })
    const status = mapStatus(statusMap.get(t.file) ?? "M")
    const clamped = clampPatch(patchResp.stdout)
    files.push({
      file: t.file,
      patch: clamped.patch,
      additions: t.additions,
      deletions: t.deletions,
      status,
      ...(clamped.truncated ? { truncated: true } : {}),
    })
  }

  const porcelain = await runGit(["-c", "core.quotepath=false", "status", "--porcelain=v1"], { cwd })
  for (const line of porcelain.stdout.split("\n")) {
    if (!line.startsWith("?? ")) continue
    const file = line.slice(3).trim()
    const abs = join(cwd, file)
    try {
      if (sniffBinary(abs)) {
        files.push({ file, patch: "", additions: 0, deletions: 0, status: "added", binary: true })
        continue
      }
      const content = readFileSync(abs, "utf-8")
      const built = buildUntrackedPatch(content)
      const clamped = clampPatch(built.patch)
      files.push({
        file,
        patch: clamped.patch,
        additions: built.additions,
        deletions: 0,
        status: "added",
        ...(clamped.truncated ? { truncated: true } : {}),
      })
    } catch {
      continue
    }
  }

  // 帧级总预算:多文件叠加超限时从尾部文件往前清空 patch(标 truncated),
  // 文件条目与 additions/deletions 原值保留;至少保留首个文件 patch,防全空帧
  for (let i = files.length - 1; i >= 1; i--) {
    if (Buffer.byteLength(JSON.stringify({ files }), "utf-8") <= MAX_TOTAL_FRAME_BYTES) break
    if (files[i].patch === "") continue
    files[i].patch = ""
    files[i].truncated = true
  }

  return { files }
}
