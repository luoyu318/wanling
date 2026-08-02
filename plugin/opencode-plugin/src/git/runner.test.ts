import { describe, it, expect, afterEach } from "vitest"
import { mkdtempSync, rmSync, writeFileSync } from "fs"
import { tmpdir } from "os"
import { join } from "path"
import { execSync } from "child_process"
import { runGit, GitError } from "./runner.js"

describe("runGit (integration)", () => {
  const dirs: string[] = []

  function makeTempRepo(): string {
    const dir = mkdtempSync(join(tmpdir(), "wl-git-"))
    dirs.push(dir)
    execSync("git init -q", { cwd: dir })
    execSync('git config user.email "test@wanling.local"', { cwd: dir })
    execSync('git config user.name "test"', { cwd: dir })
    return dir
  }

  function commitFile(dir: string, path: string, content: string): void {
    writeFileSync(join(dir, path), content)
    execSync(`git add ${path}`, { cwd: dir })
    execSync('git commit -q -m init', { cwd: dir })
  }

  afterEach(() => {
    for (const d of dirs) {
      try { rmSync(d, { recursive: true, force: true }) } catch { /* ignore */ }
    }
    dirs.length = 0
  })

  it("git 退出 0 → 返回 {stdout, stderr, exitCode:0}", async () => {
    const dir = makeTempRepo()
    commitFile(dir, "README.md", "hello\n")

    const result = await runGit(["rev-parse", "--is-inside-work-tree"], { cwd: dir })

    expect(result.exitCode).toBe(0)
    expect(result.stdout.trim()).toBe("true")
  })

  it("git 退出非 0(非 git 目录)→ 抛 GitError(128)", async () => {
    const nonGit = mkdtempSync(join(tmpdir(), "wl-nongit-"))
    dirs.push(nonGit)

    await expect(
      runGit(["rev-parse", "--is-inside-work-tree"], { cwd: nonGit }),
    ).rejects.toBeInstanceOf(GitError)
  })

  it("git 退出非 0 → GitError 携 exitCode + stderr", async () => {
    const dir = makeTempRepo()

    await expect(
      runGit(["log"], { cwd: dir }),
    ).rejects.toMatchObject({
      name: "GitError",
      exitCode: 128,
    })
  })

  it("args 透传(git diff --numstat HEAD)", async () => {
    const dir = makeTempRepo()
    commitFile(dir, "a.txt", "line1\n")
    writeFileSync(join(dir, "a.txt"), "line1\nline2\n")

    const result = await runGit(["diff", "--numstat", "HEAD"], { cwd: dir })

    expect(result.exitCode).toBe(0)
    expect(result.stdout.trim()).toMatch(/^1\t0\ta\.txt$/)
  })

  it("maxBuffer 超限 → 抛 GitError", async () => {
    const dir = makeTempRepo()

    await expect(
      runGit(["--version"], { cwd: dir, maxBuffer: 4 }),
    ).rejects.toBeInstanceOf(GitError)
  })
})
