import { readFileSync } from "fs"
import { join } from "path"
import { runGit } from "./runner.js"

export type FileDiff = {
  file: string
  patch: string
  additions: number
  deletions: number
  status: "added" | "modified" | "deleted"
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
    files.push({
      file: t.file,
      patch: patchResp.stdout,
      additions: t.additions,
      deletions: t.deletions,
      status,
    })
  }

  const porcelain = await runGit(["-c", "core.quotepath=false", "status", "--porcelain=v1"], { cwd })
  for (const line of porcelain.stdout.split("\n")) {
    if (!line.startsWith("?? ")) continue
    const file = line.slice(3).trim()
    try {
      const content = readFileSync(join(cwd, file), "utf-8")
      const { patch, additions } = buildUntrackedPatch(content)
      files.push({
        file,
        patch,
        additions,
        deletions: 0,
        status: "added",
      })
    } catch {
      continue
    }
  }

  return { files }
}
