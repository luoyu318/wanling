import { spawn } from "child_process"

export type GitRunResult = {
  stdout: string
  stderr: string
  exitCode: number
}

export type GitRunOptions = {
  cwd: string
  env?: NodeJS.ProcessEnv
  maxBuffer?: number
}

const DEFAULT_MAX_BUFFER = 10 * 1024 * 1024

export class GitError extends Error {
  constructor(
    public exitCode: number,
    public stderr: string,
    message?: string,
  ) {
    super(message ?? `git failed: exit ${exitCode}`)
    this.name = "GitError"
  }
}

export async function runGit(
  args: string[],
  opts: GitRunOptions,
): Promise<GitRunResult> {
  return new Promise((resolve, reject) => {
    const max = opts.maxBuffer ?? DEFAULT_MAX_BUFFER
    const proc = spawn("git", args, { cwd: opts.cwd, env: opts.env })
    let stdout = ""
    let stderr = ""
    let stdoutLen = 0
    let killed = false

    proc.stdout?.on("data", (chunk: Buffer) => {
      if (stdoutLen + chunk.length > max) {
        if (!killed) {
          killed = true
          proc.kill("SIGKILL")
        }
        return
      }
      stdout += chunk.toString()
      stdoutLen += chunk.length
    })
    proc.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString()
    })
    proc.on("error", (err) => {
      reject(new GitError(-1, err.message, `git spawn error: ${err.message}`))
    })
    proc.on("close", (code) => {
      if (killed) {
        reject(new GitError(-1, stderr, `git ${args.join(" ")} killed: stdout exceeded maxBuffer`))
        return
      }
      if (code === 0) {
        resolve({ stdout, stderr, exitCode: 0 })
        return
      }
      reject(new GitError(code ?? -1, stderr, `git ${args.join(" ")} failed: exit ${code}`))
    })
  })
}
