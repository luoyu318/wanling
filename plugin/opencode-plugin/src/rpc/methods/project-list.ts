import type { OpencodeClient as OpencodeClientV2 } from "@opencode-ai/sdk/v2"

type ProjectListCtx = {
  getClient: () => OpencodeClientV2 | null
}

type ProjectListResult = {
  projects: Array<{ path: string; name: string }>
}

export const projectListHandler = async (
  _params: unknown,
  ctx: ProjectListCtx,
): Promise<ProjectListResult> => {
  const client = ctx.getClient()
  if (!client) throw new Error("opencode client not ready")

  const resp = await client.project.list()
  const rawProjects = (resp.data as Array<{ worktree: string; name?: string }>) ?? []

  const seen = new Set<string>()
  return {
    projects: rawProjects
      .filter((p) => {
        if (seen.has(p.worktree)) return false
        seen.add(p.worktree)
        return true
      })
      .map((p) => ({
        path: p.worktree,
        name: p.name ?? p.worktree.split("/").pop() ?? p.worktree,
      })),
  }
}
