import { resolve, relative, join } from "path"
import { statSync } from "fs"
import { runGit } from "./runner.js"
import { probeFile } from "../file/probe.js"
import { RPCError } from "../rpc/types.js"

export type FileEntry = {
  name: string
  type: "dir" | "file"
  size: number
  binary?: boolean
}

export type FileTreeResult = {
  entries: FileEntry[]
  truncated: boolean
}

const DEFAULT_MAX_SIZE = 500

export async function listDirectory(
  cwd: string,
  path: string,
  opts: { maxSize?: number } = {},
): Promise<FileTreeResult> {
  const maxSize = opts.maxSize ?? DEFAULT_MAX_SIZE
  const absCwd = resolve(cwd)
  const absPath = resolve(absCwd, path === "" || path === "." ? "." : path)
  const rel = relative(absCwd, absPath)
  if (rel.startsWith("..") || rel === "..") {
    throw new RPCError(-32602, `path escapes session.directory: ${path}`)
  }

  const tracked = await runGit(["-c", "core.quotepath=false", "ls-files"], { cwd: absCwd })
  const untracked = await runGit(["-c", "core.quotepath=false", "ls-files", "--others", "--exclude-standard"], { cwd: absCwd })

  const prefix = rel === "" ? "" : `${rel.replace(/\\/g, "/")}/`
  const directChildren = new Set<string>()
  const fileAbsPaths: string[] = []

  const allLines = (tracked.stdout + untracked.stdout).split("\n")
  for (const line of allLines) {
    if (!line) continue
    const normalized = line.replace(/\\/g, "/")
    if (prefix === "") {
      if (normalized.includes("/")) {
        directChildren.add(normalized.split("/")[0])
      } else {
        directChildren.add(normalized)
        fileAbsPaths.push(normalized)
      }
    } else {
      if (!normalized.startsWith(prefix)) continue
      const rest = normalized.slice(prefix.length)
      if (rest.includes("/")) {
        directChildren.add(rest.split("/")[0])
      } else {
        directChildren.add(rest)
        fileAbsPaths.push(normalized)
      }
    }
  }

  const entries: FileEntry[] = []
  for (const name of directChildren) {
    if (fileAbsPaths.some(p => p === prefix + name || p === name)) {
      const fullAbs = prefix === "" ? name : prefix + name
      const fsPath = join(absCwd, fullAbs)
      let size = 0
      try {
        size = statSync(fsPath).size
      } catch {
        size = 0
      }
      const probe = probeFile(name)
      const entry: FileEntry = { name, type: "file", size }
      if (probe.kind === "binary") {
        entry.binary = true
      }
      entries.push(entry)
    } else {
      entries.push({ name, type: "dir", size: 0 })
    }
  }

  entries.sort((a, b) => {
    if (a.type !== b.type) return a.type === "dir" ? -1 : 1
    return a.name < b.name ? -1 : a.name > b.name ? 1 : 0
  })

  const truncated = entries.length > maxSize
  return {
    entries: truncated ? entries.slice(0, maxSize) : entries,
    truncated,
  }
}
