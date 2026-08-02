import { getSessionMap } from "../../sync/mapper.js"
import { listDirectory, type FileEntry } from "../../git/file-tree.js"
import { GitError } from "../../git/runner.js"
import { RPCError } from "../types.js"
import { fetchSessionDirectory, type RPCContext } from "../utils.js"

type FileListResult = {
  root: string
  path: string
  entries: FileEntry[]
  truncated: boolean
}

export const fileListHandler = async (
  params: unknown,
  ctx: RPCContext,
): Promise<FileListResult> => {
  const p = params as Record<string, unknown>
  const convId = p?.wanling_conv_id
  if (typeof convId !== "string" || convId === "") {
    throw new RPCError(-32602, "invalid params: wanling_conv_id required")
  }

  let directory: string | null =
    typeof p?.directory === "string" && p.directory !== "" ? p.directory : null
  if (!directory) {
    const map = getSessionMap(convId)
    if (!map) {
      throw new RPCError(-32601, "session not created")
    }
    directory = await fetchSessionDirectory(ctx.getClient, map.opencodeSessionId)
  }
  if (!directory) {
    throw new RPCError(-32603, "directory not anchored")
  }

  const path = typeof p?.path === "string" && p.path !== "" ? p.path : "."

  try {
    const tree = await listDirectory(directory, path)
    return {
      root: directory,
      path,
      entries: tree.entries,
      truncated: tree.truncated,
    }
  } catch (e) {
    if (e instanceof GitError) {
      throw new RPCError(-32604, `git error: ${e.stderr || e.message}`)
    }
    throw e
  }
}
