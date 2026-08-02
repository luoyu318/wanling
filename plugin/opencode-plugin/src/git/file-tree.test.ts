import { describe, it, expect, vi, beforeEach } from "vitest"

vi.mock("./runner.js", () => ({
  runGit: vi.fn(),
  GitError: class GitError extends Error {
    constructor(public exitCode: number, public stderr: string, message?: string) {
      super(message ?? `git failed: exit ${exitCode}`)
      this.name = "GitError"
    }
  },
}))

vi.mock("fs", async (importActual) => {
  const actual = await importActual<typeof import("fs")>()
  return {
    ...actual,
    statSync: vi.fn(),
  }
})

import { runGit } from "./runner.js"
import { statSync } from "fs"
import { listDirectory } from "./file-tree.js"

function mockRunGitSequence(responses: Array<{ stdout?: string; stderr?: string; exitCode?: number } | Error>): void {
  const queue = [...responses]
  vi.mocked(runGit).mockImplementation(async () => {
    const next = queue.shift()
    if (next instanceof Error) throw next
    return {
      stdout: next.stdout ?? "",
      stderr: next.stderr ?? "",
      exitCode: next.exitCode ?? 0,
    }
  })
}

describe("listDirectory", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("根层 path='.' → 列出根目录文件 + 子目录(去重)", async () => {
    mockRunGitSequence([
      { stdout: "README.md\nsrc/main.go\nsrc/util.go\ndocs/intro.md\npackage.json\n" },
      { stdout: "untracked.txt\n" },
    ])
    vi.mocked(statSync).mockReturnValue({ size: 100 } as any)

    const result = await listDirectory("/proj", ".")

    expect(result.truncated).toBe(false)
    const names = result.entries.map(e => e.name)
    expect(names).toContain("src")
    expect(names).toContain("docs")
    expect(names).toContain("README.md")
    expect(names).toContain("package.json")
    expect(names).toContain("untracked.txt")
    const srcEntry = result.entries.find(e => e.name === "src")
    expect(srcEntry?.type).toBe("dir")
    expect(srcEntry?.size).toBe(0)
    const readme = result.entries.find(e => e.name === "README.md")
    expect(readme?.type).toBe("file")
    expect(readme?.size).toBe(100)
  })

  it("子目录 path='src' → 只列 src/ 下的直接子项", async () => {
    mockRunGitSequence([
      { stdout: "src/main.go\nsrc/util.go\nsrc/sub/low.go\nsrc/main_test.go\n" },
      { stdout: "" },
    ])
    vi.mocked(statSync).mockReturnValue({ size: 200 } as any)

    const result = await listDirectory("/proj", "src")

    const names = result.entries.map(e => e.name)
    expect(names).toContain("main.go")
    expect(names).toContain("util.go")
    expect(names).toContain("main_test.go")
    expect(names).toContain("sub")
    expect(names).not.toContain("src/main.go")
    expect(names).not.toContain("low.go")
    expect(result.entries.find(e => e.name === "sub")?.type).toBe("dir")
  })

  it("path='.' 但 ls-files 返空 → entries 空 + truncated false", async () => {
    mockRunGitSequence([
      { stdout: "" },
      { stdout: "" },
    ])
    const result = await listDirectory("/empty", ".")
    expect(result.entries).toEqual([])
    expect(result.truncated).toBe(false)
  })

  it("超过 maxSize(默认 500)→ 截断 + truncated true", async () => {
    const many = Array.from({ length: 600 }, (_, i) => `file${i}.txt`).join("\n") + "\n"
    mockRunGitSequence([
      { stdout: many },
      { stdout: "" },
    ])
    vi.mocked(statSync).mockReturnValue({ size: 10 } as any)

    const result = await listDirectory("/big", ".")

    expect(result.entries.length).toBe(500)
    expect(result.truncated).toBe(true)
  })

  it("path='..' 越界 → 抛 RPCError(-32602)", async () => {
    await expect(
      listDirectory("/proj", ".."),
    ).rejects.toMatchObject({ code: -32602 })
  })

  it("runGit 抛 GitError(128 非 git 仓库)→ 透传", async () => {
    const gitErr = new (class extends Error {
      constructor() {
        super("git failed: exit 128")
        this.name = "GitError"
      }
      exitCode = 128
      stderr = "not a git repo"
    })()
    vi.mocked(runGit).mockRejectedValue(gitErr)

    await expect(
      listDirectory("/not-a-repo", "."),
    ).rejects.toBe(gitErr)
  })

  it("排序:目录优先 + 字母序", async () => {
    mockRunGitSequence([
      { stdout: "zebra.txt\napple.md\nsrc/x.go\nApple.md\n" },
      { stdout: "" },
    ])
    vi.mocked(statSync).mockReturnValue({ size: 1 } as any)

    const result = await listDirectory("/proj", ".")

    const names = result.entries.map(e => e.name)
    expect(names).toEqual(["src", "Apple.md", "apple.md", "zebra.txt"])
  })

  it("runGit 调用必须禁用 core.quotepath,否则非 ASCII 文件名被八进制转义", async () => {
    mockRunGitSequence([
      { stdout: "README.md\n" },
      { stdout: "" },
    ])
    vi.mocked(statSync).mockReturnValue({ size: 1 } as any)

    await listDirectory("/proj", ".")

    expect(vi.mocked(runGit).mock.calls.length).toBe(2)
    for (const [args] of vi.mocked(runGit).mock.calls) {
      const i = (args as string[]).indexOf("-c")
      expect(i).toBeGreaterThanOrEqual(0)
      expect((args as string[])[i + 1]).toBe("core.quotepath=false")
    }
  })

  it("中文文件名正确解析(quotepath=false 时 git 输出的原始 Unicode)", async () => {
    mockRunGitSequence([
      { stdout: "README.md\n春晓随想.txt\n将进酒读后感.txt\n" },
      { stdout: "陋室铭读后感.txt\n" },
    ])
    vi.mocked(statSync).mockReturnValue({ size: 100 } as any)

    const result = await listDirectory("/proj", ".")

    const names = result.entries.map(e => e.name)
    expect(names).toContain("春晓随想.txt")
    expect(names).toContain("将进酒读后感.txt")
    expect(names).toContain("陋室铭读后感.txt")
    expect(names.every(n => !n.includes('"'))).toBe(true)
  })
})
