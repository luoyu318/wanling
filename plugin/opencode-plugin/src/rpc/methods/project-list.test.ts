import { describe, it, expect } from "vitest"
import { projectListHandler } from "./project-list.js"

describe("project.list handler", () => {
  it("OC project.list 结果映射为 {path, name}, name 缺时用 path 末段", async () => {
    const mockClient: any = {
      project: {
        list: async () => ({
          data: [
            { worktree: "/home/user/proj-a", name: "Project A" },
            { worktree: "/home/user/proj-b" },
          ],
        }),
      },
    }
    const ctx = { getClient: () => mockClient }

    const result = await projectListHandler({}, ctx)

    expect(result.projects).toHaveLength(2)
    expect(result.projects[0]).toEqual({ path: "/home/user/proj-a", name: "Project A" })
    expect(result.projects[1]).toEqual({ path: "/home/user/proj-b", name: "proj-b" })
  })

  it("OC 返空清单时返 {projects: []}", async () => {
    const mockClient: any = {
      project: { list: async () => ({ data: [] }) },
    }
    const ctx = { getClient: () => mockClient }

    const result = await projectListHandler({}, ctx)

    expect(result.projects).toEqual([])
  })

  it("OC 未就绪(getClient 返 null)抛错", async () => {
    const ctx = { getClient: () => null }

    await expect(projectListHandler({}, ctx)).rejects.toThrow(/not ready/i)
  })

  it("OC project.list 抛错时透传", async () => {
    const mockClient: any = {
      project: { list: async () => { throw new Error("network down") } },
    }
    const ctx = { getClient: () => mockClient }

    await expect(projectListHandler({}, ctx)).rejects.toThrow("network down")
  })

  it("同 worktree 重复时按 path 去重,保留首次出现", async () => {
    const mockClient: any = {
      project: {
        list: async () => ({
          data: [
            { worktree: "/home/user/proj-a", name: "Project A" },
            { worktree: "/home/user/dup", name: "Dup First" },
            { worktree: "/home/user/dup" },
            { worktree: "/home/user/proj-b" },
          ],
        }),
      },
    }
    const ctx = { getClient: () => mockClient }

    const result = await projectListHandler({}, ctx)

    expect(result.projects).toHaveLength(3)
    expect(result.projects[1]).toEqual({ path: "/home/user/dup", name: "Dup First" })
    const paths = result.projects.map((p) => p.path)
    expect(new Set(paths).size).toBe(paths.length)
  })
})
