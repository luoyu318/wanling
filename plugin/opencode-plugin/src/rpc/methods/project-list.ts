import type { OpencodeClient as OpencodeClientV2 } from "@opencode-ai/sdk/v2"

type ProjectListCtx = {
  getClient: () => OpencodeClientV2 | null
}

type ProjectListResult = {
  projects: Array<{ path: string; name: string }>
}

type RawProject = { worktree: string; name?: string; sandboxes?: string[] }

export const projectListHandler = async (
  _params: unknown,
  ctx: ProjectListCtx,
): Promise<ProjectListResult> => {
  const client = ctx.getClient()
  if (!client) throw new Error("opencode client not ready")

  const resp = await client.project.list()
  const rawProjects = (resp.data as RawProject[]) ?? []

  // worktree + sandboxes 一并展开:opencode 项目模型里附属工作目录挂在
  // sandboxes(如 wanling 挂在 chat 下),只映射 worktree 会让选择器缺目录。
  const seen = new Set<string>()
  const projects: Array<{ path: string; name: string }> = []
  for (const p of rawProjects) {
    const candidates: Array<{ path: string; name?: string }> = [
      { path: p.worktree, name: p.name },
      ...(p.sandboxes ?? []).map((path) => ({ path })),
    ]
    for (const candidate of candidates) {
      if (seen.has(candidate.path)) continue
      seen.add(candidate.path)
      projects.push({
        path: candidate.path,
        name: candidate.name ?? candidate.path.split("/").pop() ?? candidate.path,
      })
    }
  }
  return { projects }
}
