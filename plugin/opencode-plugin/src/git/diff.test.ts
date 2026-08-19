import { describe, it, expect, vi, beforeEach } from "vitest"

vi.mock("fs", async (importActual) => {
  const actual = await importActual<typeof import("fs")>()
  return {
    ...actual,
    readFileSync: vi.fn(),
  }
})

vi.mock("./runner.js", () => ({
  runGit: vi.fn(),
  GitError: class GitError extends Error {
    constructor(public exitCode: number, public stderr: string, message?: string) {
      super(message ?? `git failed: exit ${exitCode}`)
      this.name = "GitError"
    }
  },
}))

import { readFileSync } from "fs"
import { runGit } from "./runner.js"
import { computeDiff } from "./diff.js"

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

describe("computeDiff", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(readFileSync).mockReset()
  })

  it("纯 modified:1 文件,numstat+status+patch 各 1 次,rev-parse 1 次", async () => {
    mockRunGitSequence([
      { stdout: "true\n" },
      { stdout: "3\t1\tREADME.md\n" },
      { stdout: "M\tREADME.md\n" },
      { stdout: "@@ -1 +1,3 @@\n+line2\n+line3\n-line1\n" },
      { stdout: "" },
    ])

    const result = await computeDiff("/proj")

    expect(result.files).toHaveLength(1)
    expect(result.files[0]).toEqual({
      file: "README.md",
      patch: "@@ -1 +1,3 @@\n+line2\n+line3\n-line1\n",
      additions: 3,
      deletions: 1,
      status: "modified",
    })
    expect(runGit).toHaveBeenCalledTimes(5)
  })

  it("modified + untracked:tracked numstat 1 行 + porcelain 多 ?? new.txt", async () => {
    mockRunGitSequence([
      { stdout: "true\n" },
      { stdout: "2\t0\tmain.go\n" },
      { stdout: "M\tmain.go\n" },
      { stdout: "@@ -1 +1,2 @@\n+new line\n" },
      { stdout: " M main.go\n?? new.txt\n" },
    ])
    vi.mocked(readFileSync).mockImplementation(((path: unknown, opts: unknown) => {
      if (typeof opts === "string" || opts?.encoding) {
        return "hello\nworld\n"
      }
      return Buffer.from("hello\nworld\n")
    }) as unknown as typeof readFileSync)

    const result = await computeDiff("/proj")

    expect(result.files).toHaveLength(2)
    expect(result.files[0]).toEqual({
      file: "main.go",
      patch: "@@ -1 +1,2 @@\n+new line\n",
      additions: 2,
      deletions: 0,
      status: "modified",
    })
    expect(result.files[1]).toEqual({
      file: "new.txt",
      patch: "+hello\n+world\n",
      additions: 2,
      deletions: 0,
      status: "added",
    })
    expect(readFileSync).toHaveBeenCalledWith("/proj/new.txt", "utf-8")
  })

  it("deleted 文件:numstat 0/10 + status D + patch 全是 - 行", async () => {
    mockRunGitSequence([
      { stdout: "true\n" },
      { stdout: "0\t10\told.go\n" },
      { stdout: "D\told.go\n" },
      { stdout: "@@ -1,10 +0,0 @@\n-line1\n-line2\n" },
      { stdout: "" },
    ])

    const result = await computeDiff("/proj")

    expect(result.files).toHaveLength(1)
    expect(result.files[0]).toEqual({
      file: "old.go",
      patch: "@@ -1,10 +0,0 @@\n-line1\n-line2\n",
      additions: 0,
      deletions: 10,
      status: "deleted",
    })
  })

  it("空 diff(无任何改动)→ files = []", async () => {
    mockRunGitSequence([
      { stdout: "true\n" },
      { stdout: "" },
      { stdout: "" },
      { stdout: "" },
    ])

    const result = await computeDiff("/proj")

    expect(result.files).toEqual([])
  })

  it("非 git 区域(rev-parse 失败)→ 透传 GitError", async () => {
    const { GitError } = await import("./runner.js")
    vi.mocked(runGit).mockRejectedValueOnce(
      new GitError(128, "not a git repository", "git rev-parse failed: exit 128"),
    )

    await expect(computeDiff("/not-a-repo")).rejects.toBeInstanceOf(GitError)
  })

  it("binary 文件(numstat 行是 -\\t-\\t<Path>)→ 跳过", async () => {
    mockRunGitSequence([
      { stdout: "true\n" },
      { stdout: "-\t-\tbinary.png\n" },
      { stdout: "" },
      { stdout: "" },
    ])

    const result = await computeDiff("/proj")

    expect(result.files).toEqual([])
  })

  it("rename(R100)→ status=modified,patch 来自 git diff HEAD -- <newpath>", async () => {
    mockRunGitSequence([
      { stdout: "true\n" },
      { stdout: "0\t0\tnew.go\n" },
      { stdout: "R100\told.go\tnew.go\n" },
      { stdout: "" },
      { stdout: "" },
    ])

    const result = await computeDiff("/proj")

    expect(result.files).toHaveLength(1)
    expect(result.files[0].file).toBe("new.go")
    expect(result.files[0].status).toBe("modified")
  })

  it("rename(R100) 走 R/C 分支切割 newpath→ file=new.go, status=modified, patch 透传", async () => {
    mockRunGitSequence([
      { stdout: "true\n" },
      { stdout: "1\t0\tnew.go\n" },
      { stdout: "R100\told.go\tnew.go\n" },
      { stdout: "@@ -1 +1 @@\n+x\n" },
      { stdout: "" },
    ])

    const result = await computeDiff("/proj")

    expect(result.files).toHaveLength(1)
    expect(result.files[0].file).toBe("new.go")
    expect(result.files[0].status).toBe("modified")
    expect(result.files[0].patch).toBe("@@ -1 +1 @@\n+x\n")
    expect(result.files[0].additions).toBe(1)
    expect(result.files[0].deletions).toBe(0)
  })

  it("中文 untracked 文件名(literal UTF-8 路径,无引号无 octal)→ 正确解析与路径拼接", async () => {
    mockRunGitSequence([
      { stdout: "true\n" },
      { stdout: "" },
      { stdout: "" },
      { stdout: "?? 新文件.txt\n" },
    ])
    vi.mocked(readFileSync).mockImplementation(((path: unknown, opts: unknown) => {
      if (typeof opts === "string" || opts?.encoding) {
        return "hello\n世界\n"
      }
      return Buffer.from("hello\n世界\n")
    }) as unknown as typeof readFileSync)

    const result = await computeDiff("/proj")

    expect(result.files).toHaveLength(1)
    expect(result.files[0].file).toBe("新文件.txt")
    expect(result.files[0].status).toBe("added")
    expect(result.files[0].additions).toBe(2)
    expect(result.files[0].deletions).toBe(0)
    expect(result.files[0].patch).toBe("+hello\n+世界\n")
    expect(readFileSync).toHaveBeenCalledWith("/proj/新文件.txt", "utf-8")
  })
})

describe("computeDiff 大文件/二进制防护", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(readFileSync).mockReset()
  })

  it("untracked 二进制文件(含 NUL 字节)→ binary:true, patch 空, 不再整读 utf-8", async () => {
    mockRunGitSequence([
      { stdout: "true\n" },
      { stdout: "" },
      { stdout: "" },
      { stdout: "?? app-release.apk\n" },
    ])
    // 第一次调用(嗅探,Buffer)返回含 NUL 的 Buffer;若实现错误地只调 utf-8 读会走第二个 mock
    vi.mocked(readFileSync).mockImplementation(((path: unknown, opts: unknown) => {
      if (typeof opts === "string" || opts?.encoding) {
        throw new Error("FAIL: 不应对二进制文件做 utf-8 整读")
      }
      return Buffer.from([0x50, 0x4b, 0x03, 0x04, 0x00, 0x00]) // PK 头 + NUL
    }) as unknown as typeof readFileSync)

    const result = await computeDiff("/proj")

    expect(result.files).toHaveLength(1)
    expect(result.files[0]).toEqual({
      file: "app-release.apk",
      patch: "",
      additions: 0,
      deletions: 0,
      status: "added",
      binary: true,
    })
  })

  it("untracked 大文本文件(> 256KB patch)→ truncated:true, patch 截断且末行带省略提示", async () => {
    mockRunGitSequence([
      { stdout: "true\n" },
      { stdout: "" },
      { stdout: "" },
      { stdout: "?? big.log\n" },
    ])
    const bigText = "x".repeat(60) + "\n"
    vi.mocked(readFileSync).mockImplementation(((path: unknown, opts: unknown) => {
      if (typeof opts === "string" || opts?.encoding) {
        return bigText.repeat(6000) // ~366KB 文本 → patch ~372KB 超 256KB
      }
      return Buffer.from(Array(8000).fill(0x61)) // 纯 ASCII,无 NUL → 非二进制
    }) as unknown as typeof readFileSync)

    const result = await computeDiff("/proj")

    expect(result.files).toHaveLength(1)
    const f = result.files[0]
    expect(f.truncated).toBe(true)
    expect(Buffer.byteLength(f.patch, "utf-8")).toBeLessThanOrEqual(256 * 1024)
    expect(f.patch.endsWith("…(已截断,共 6000 行)\n")).toBe(true)
  })

  it("tracked 单文件 patch 超 256KB → truncated:true 截断", async () => {
    const hugePatch = "+" + "y".repeat(300 * 1024) + "\n"
    mockRunGitSequence([
      { stdout: "true\n" },
      { stdout: "1\t0\thuge.go\n" },
      { stdout: "M\thuge.go\n" },
      { stdout: hugePatch },
      { stdout: "" },
    ])

    const result = await computeDiff("/proj")

    expect(result.files[0].truncated).toBe(true)
    expect(Buffer.byteLength(result.files[0].patch, "utf-8")).toBeLessThanOrEqual(256 * 1024)
    expect(result.files[0].additions).toBe(1) // numstat 原值不因截断改写
  })

  it("untracked 文件读失败(权限/消失)→ 仍跳过不抛(既有行为保持)", async () => {
    mockRunGitSequence([
      { stdout: "true\n" },
      { stdout: "" },
      { stdout: "" },
      { stdout: "?? gone.txt\n" },
    ])
    vi.mocked(readFileSync).mockImplementation((() => {
      throw new Error("ENOENT")
    }) as unknown as typeof readFileSync)

    const result = await computeDiff("/proj")
    expect(result.files).toEqual([])
  })
})
