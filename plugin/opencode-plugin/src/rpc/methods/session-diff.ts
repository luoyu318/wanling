import { getSessionMap } from "../../sync/mapper.js"
import { computeDiff } from "../../git/diff.js"
import { GitError } from "../../git/runner.js"
import { RPCError } from "../types.js"
import { fetchSessionDirectory, type RPCContext } from "../utils.js"

type SnapshotFileDiff = {
  file?: string
  patch?: string
  additions: number
  deletions: number
  status?: "added" | "modified" | "deleted"
}

type SessionDiffResult = {
  files: SnapshotFileDiff[]
}

export const sessionDiffHandler = async (
  params: unknown,
  ctx: RPCContext,
): Promise<SessionDiffResult> => {
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

  try {
    return await computeDiff(directory)
  } catch (e) {
    if (e instanceof GitError) {
      throw new RPCError(-32604, `git error: ${e.stderr || e.message}`)
    }
    throw e
  }
}
