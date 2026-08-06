import type { OpencodeClient } from "@opencode-ai/sdk";
import { createOpencodeClient } from "@opencode-ai/sdk"
import type {
  OpencodeClient as OpencodeClientV2} from "@opencode-ai/sdk/v2";
import {
  createOpencodeClient as createOpencodeClientV2
} from "@opencode-ai/sdk/v2"
import type { ChildProcess } from "child_process";
import { spawn } from "child_process"
import { existsSync, readFileSync, readdirSync } from "fs"
import { join } from "path"
import { homedir } from "os"
import { EventEmitter } from "events"
import { logger } from "../utils/logger.js"

export interface MessageRecord {
  role: "user" | "assistant"
  text: string
  timestamp: string
}

function extractText(parts: Array<{ type?: string; text?: string }>): string {
  return (parts || [])
    .filter((p) => p.type === "text")
    .map((p) => p.text || "")
    .join("")
}

function resolveOpencodeBin(): string {
  const envBin = process.env.OPENCODE_BIN
  if (envBin && envBin.trim()) return envBin
  return "opencode"
}

// opencode serve 模式不从全局 config 加载 provider 字段（内置行为差异）。
// 用 OPENCODE_CONFIG 把全局 config 当作 local-scope 显式加载，绕过此限制。
function resolveGlobalConfigPath(): string | undefined {
  const candidates = [
    join(homedir(), ".config", "opencode", "opencode.json"),
    join(homedir(), ".config", "opencode", "opencode.jsonc"),
  ]
  return candidates.find((p) => existsSync(p))
}

// systemd user service 不 source .zshrc，environment.d 也需要重新登录才生效。
// 插件主动读取 ~/.config/environment.d/*.conf，解析 KEY=VALUE 注入 serve 进程环境。
function loadEnvironmentD(): Record<string, string> {
  const dir = join(homedir(), ".config", "environment.d")
  if (!existsSync(dir)) return {}
  const result: Record<string, string> = {}
  for (const file of readdirSync(dir).sort()) {
    if (!file.endsWith(".conf")) continue
    const content = readFileSync(join(dir, file), "utf-8")
    for (const line of content.split("\n")) {
      const trimmed = line.trim()
      if (!trimmed || trimmed.startsWith("#")) continue
      const eq = trimmed.indexOf("=")
      if (eq < 1) continue
      const key = trimmed.slice(0, eq)
      let val = trimmed.slice(eq + 1)
      // 去掉首尾引号
      if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
        val = val.slice(1, -1)
      }
      result[key] = val
    }
  }
  return result
}

interface SdkError extends Error {
  sdkError?: { code?: number; status?: number; statusCode?: number; message?: string }
}

function makeSdkError(op: string, sdkError: NonNullable<unknown>): SdkError {
  const e = new Error(`${op} failed: ${JSON.stringify(sdkError)}`) as SdkError
  e.sdkError = sdkError as SdkError["sdkError"]
  return e
}

export class OpencodeBridge extends EventEmitter {
  private client: OpencodeClient | null = null
  private clientV2: OpencodeClientV2 | null = null
  private serverProcess: ChildProcess | null = null
  private exitHandler: (() => void) | null = null
  private port: number
  private currentSessionId: string | null = null

  constructor(port: number = 4096) {
    super()
    this.port = port
  }

  getClient(): OpencodeClient | null {
    return this.client
  }

  getClientV2(): OpencodeClientV2 | null {
    return this.clientV2
  }

  async ensureServer(): Promise<void> {
    // list() 带超时：Node fetch 默认无超时，若连到 cgroup 杀后残留的半死 serve 会永久 hang。
    // 超时后快速失败进入重试，避免 ensureServer 卡死（systemd restart 时复现）。
    const listWithTimeout = async (client: OpencodeClient, ms: number): Promise<unknown> => {
      let timer: ReturnType<typeof setTimeout> | undefined
      try {
        return await Promise.race([
          client.session.list(),
          new Promise<never>((_, rej) => {
            timer = setTimeout(() => rej(new Error(`list timeout ${ms}ms`)), ms)
          }),
        ])
      } finally {
        if (timer) clearTimeout(timer)
      }
    }

    try {
      const client = this.newClient()
      this.client = client
      logger.debug(`[bridge·diag] 首次 list()...`)
      const t0 = Date.now()
      await listWithTimeout(client, 3000)
      logger.debug(`[bridge·diag] 首次 list ok in ${Date.now() - t0}ms`)
      this.clientV2 = this.newClientV2()
      return
    } catch (err) {
      const e = err as Error & { cause?: unknown }
      logger.info(`[opencode] server 未就绪，尝试启动: ${e.message} cause=${JSON.stringify(e.cause)}`)
    }

    this.client = null
    this.clientV2 = null
    await this.startServerProcess()
    const retryClient = this.newClient()
    this.client = retryClient

    for (let i = 0; i < 30; i++) {
      const t0 = Date.now()
      logger.debug(`[bridge·diag] 重试 ${i}/30 list()...`)
      try {
        await listWithTimeout(retryClient, 3000)
        logger.debug(`[bridge·diag] 重试 ${i} ok in ${Date.now() - t0}ms`)
        this.clientV2 = this.newClientV2()
        return
      } catch (err) {
        const e = err as Error & { cause?: unknown }
        logger.debug(`[bridge·diag] 重试 ${i} failed in ${Date.now() - t0}ms: ${e.message} cause=${JSON.stringify(e.cause)}`)
      }
      await new Promise((r) => setTimeout(r, 500))
    }
    throw new Error("OpenCode server failed to start")
  }

  private requireClient(): OpencodeClient {
    if (!this.client) {
      throw new Error("opencode client not ready, call ensureServer() first")
    }
    return this.client
  }

  private newClient(): OpencodeClient {
    return createOpencodeClient({
      baseUrl: `http://localhost:${this.port}`,
    })
  }

  private newClientV2(): OpencodeClientV2 {
    return createOpencodeClientV2({
      baseUrl: `http://localhost:${this.port}`,
    })
  }

  private startServerProcess(): Promise<void> {
    return new Promise((resolve, reject) => {
      const env = { ...process.env, ...loadEnvironmentD() }
      const globalConfig = resolveGlobalConfigPath()
      if (globalConfig && !env.OPENCODE_CONFIG) {
        env.OPENCODE_CONFIG = globalConfig
        logger.info(`[bridge] OPENCODE_CONFIG=${globalConfig}（让 serve 加载全局 provider 配置）`)
      }
      const proc = spawn(resolveOpencodeBin(), ["serve", "--port", String(this.port)], {
        stdio: ["ignore", "ignore", "inherit"],
        detached: false,
        env,
      })
      this.serverProcess = proc
      if (this.exitHandler) {
        process.removeListener("exit", this.exitHandler)
      }
      this.exitHandler = () => {
        if (!proc.killed) proc.kill()
      }
      process.on("exit", this.exitHandler)
      proc.on("error", (err) => reject(err))
      proc.on("exit", (code) => {
        if (code !== 0) console.error(`[bridge] opencode server exited with code ${code}`)
      })
      setTimeout(() => resolve(), 1000)
    })
  }

  async getCurrentSession(): Promise<string | null> {
    if (this.currentSessionId) return this.currentSessionId
    try {
      const resp = await this.requireClient().session.list()
      const sessions = resp.data as Array<{ id: string }> | undefined
      if (sessions && sessions.length > 0) {
        this.currentSessionId = sessions[0].id
        return this.currentSessionId
      }
    } catch { /* 解析失败返回 null 让调用方降级 */ }
    return null
  }

  async createSession(title: string, directory?: string): Promise<string> {
    const resp = await this.requireClient().session.create({
      body: { title },
      query: directory ? { directory } : undefined,
    })
    const session = resp.data as { id: string }
    this.currentSessionId = session.id
    return session.id
  }

  async prompt(
    sessionId: string,
    text: string,
    agent?: string,
    model?: { providerID: string; modelID: string },
  ): Promise<string> {
    const resp = await this.requireClient().session.prompt({
      path: { id: sessionId },
      body: {
        ...(agent ? { agent } : {}),
        ...(model ? { model } : {}),
        parts: [{ type: "text" as const, text }],
      },
    })
    const result = resp.data as { parts?: Array<{ type?: string; text?: string }> }
    return extractText(result?.parts || [])
  }

  // 异步 prompt:立即返回 204,实际 LLM 响应走 SSE 事件流(streamer 监听)。
  // 替代同步 prompt——同步 prompt 的 HTTP 响应要等 LLM 生成完(可能数分钟),
  // 配合 promptWithRetry 重试会放大重复写入(消息重放 bug 根因)。
  // async 语义下 OC 收到请求即刻返回,慢的 LLM 生成不阻塞 fetch,
  // retry 窗口缩到几十 ms,重复概率趋零。
  // model?: APP 端选中的模型覆盖,snake→camel 转换由调用方(engine)完成。
  // v2 queue 语义:delivery="queue" 让 opencode 持久化入队、按序调度,排队消息
  // 在当前 agent loop 内按小回合穿插执行;resume=true 保持 loop 运行。
  // 返回 opencode messageID(SessionInputAdmitted.id),供排队状态关联(engine 记 FIFO)。
  // model 处理:已实测 v2 prompt body 丢弃 model(admitted 只回显 prompt.text),
  // 故先调 session.switchModel 切到目标模型,再发 prompt(不带 model)。
  async promptAsync(
    sessionId: string,
    text: string,
    agent?: string,
    model?: { providerID: string; modelID: string },
  ): Promise<string | null> {
    if (!this.clientV2) throw new Error("opencode v2 client not ready")
    if (agent) {
      await this.switchSessionAgent(sessionId, agent)
    }
    if (model) {
      await this.switchSessionModel(sessionId, model)
    }
    const session = this.clientV2.session as unknown as {
      prompt: (params: Record<string, unknown>) => Promise<{ data?: { id?: string } }>
    }
    const result = await session.prompt({
      sessionID: sessionId,
      prompt: { text },
      delivery: "queue",
      resume: true,
    })
    // v2 返回 SessionInputAdmitted,含 opencode 生成的 messageID 与 admittedSeq
    return result?.data?.id ?? null
  }

  // 切换 session agent(POST /api/session/{id}/agent)。与 model 同理:v2 prompt
  // 无法透传 agent,用 switchAgent 让排队消息使用 APP 选中的 mode。
  // 注意:SDK 1.18.3 的 v2 client 运行时不暴露 switchAgent(类型有但对象没有,
  // 真机实测 undefined),故用 fetch 直接调 API,不依赖 SDK 方法。
  async switchSessionAgent(
    sessionId: string,
    agent: string,
  ): Promise<void> {
    const resp = await fetch(`http://localhost:${this.port}/api/session/${encodeURIComponent(sessionId)}/agent`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ agent }),
    })
    if (!resp.ok) {
      throw new Error(`switchAgent failed: ${resp.status} ${await resp.text().catch(() => "")}`)
    }
  }

  // 切换 session 模型(POST /api/session/{id}/model)。v2 prompt 无法透传 model,
  // 用 switchModel 让排队消息使用 APP 选中的模型。影响该 session 后续消息
  // (同会话队列消息共用此模型,语义可接受)。幂等:切换失败抛错由调用方重试。
  // 同 switchAgent:SDK 1.18.3 运行时无 switchModel 方法,用 fetch 直接调。
  async switchSessionModel(
    sessionId: string,
    model: { providerID: string; modelID: string },
  ): Promise<void> {
    const resp = await fetch(`http://localhost:${this.port}/api/session/${encodeURIComponent(sessionId)}/model`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        model: {
          providerID: model.providerID,
          id: model.modelID,
        },
      }),
    })
    if (!resp.ok) {
      throw new Error(`switchModel failed: ${resp.status} ${await resp.text().catch(() => "")}`)
    }
  }

  // 调用 opencode session.command API 执行斜杠命令。
  // 与 promptAsync 对应的两条通道:
  //   - promptAsync → POST /session/{id}/prompt_async(普通消息)
  //   - runCommand  → POST /session/{id}/command(命令,带 template 渲染)
  // agent/model?: APP 端 mode/model override 透传(对象形式,对称 promptAsync)。
  // 注意:OC SDK 的 command.model 类型是 string(promptAsync 是对象,OC API 内部不一致),
  // bridge 内部序列化为 "providerID/modelID"(OC 全局约定,见 streamer cache key)。
  // 与 promptAsync 一致用 async 语义:立即返回,LLM 响应走 SSE。
  async runCommand(
    sessionId: string,
    commandName: string,
    args: string,
    agent?: string,
    model?: { providerID: string; modelID: string },
  ): Promise<void> {
    if (!this.clientV2) throw new Error("opencode v2 client not ready")
    const result = await this.clientV2.session.command({
      sessionID: sessionId,
      command: commandName,
      arguments: args,
      ...(agent ? { agent } : {}),
      ...(model ? { model: `${model.providerID}/${model.modelID}` } : {}),
    })
    if (result.error) {
      throw makeSdkError("session.command", result.error)
    }
  }

  // 调用 OC session.summarize API 触发对话压缩。
  // 对应 OpenCode API: POST /session/{id}/summarize body {providerID, modelID}。
  // 抓包确认(OC 1.18.3):/api/session/{id}/compact(v2) 返回 503 未实现,
  // v1 /summarize 才是真实可用入口。SDK 已封装为 client.session.summarize。
  // 压缩产物通过 SSE 事件流回流(message.part.updated type=compaction +
  // compaction agent 的 markdown 消息),streamer 监听后发 wanling WS。
  // 幂等:404(session 不存在)忽略,与 abortSession/renameSession 一致口径。
  async summarizeSession(
    sessionId: string,
    providerID: string,
    modelID: string,
  ): Promise<void> {
    const client = this.requireClient()
    try {
      await client.session.summarize({
        path: { id: sessionId },
        body: { providerID, modelID },
      })
    } catch (err) {
      const e = err as SdkError
      const code = e?.sdkError?.code ?? e?.sdkError?.status ?? e?.sdkError?.statusCode
      if (code === 404) {
        logger.debug(`[bridge] summarizeSession ${sessionId.slice(0, 12)}… session 不存在,忽略`)
        return
      }
      throw err
    }
  }

  // 中止指定 session 的当前生成。对应 OpenCode API: POST /session/{id}/abort。
  // 幂等:session 空闲时调用无副作用(OpenCode 内部忽略)。
  // 抛错仅在网络故障 / session 不存在时(调用方决定降级策略)。
  async abortSession(sessionId: string): Promise<void> {
    const client = this.requireClient()
    try {
      await client.session.abort({ path: { id: sessionId } })
    } catch (err) {
      const e = err as SdkError
      const code = e?.sdkError?.code ?? e?.sdkError?.status ?? e?.sdkError?.statusCode
      // 404 = session 不存在(已结束 / 被删),幂等忽略
      if (code === 404) {
        logger.debug(`[bridge] abortSession ${sessionId.slice(0, 12)}… session 不存在,忽略`)
        return
      }
      throw err
    }
  }

  // 改 OC session 标题。对应 OpenCode API: PATCH /session/{id} body {title}。
  // 用于万灵→OC 单向同步:APP 改会话名 → server 广播 CONVERSATION_UPDATE → 插件调本方法改 OC。
  // 幂等:404(session 不存在)忽略,与 abortSession 一致口径。
  async renameSession(sessionId: string, title: string): Promise<void> {
    const client = this.requireClient()
    try {
      await client.session.update({ path: { id: sessionId }, body: { title } })
    } catch (err) {
      const e = err as SdkError
      const code = e?.sdkError?.code ?? e?.sdkError?.status ?? e?.sdkError?.statusCode
      if (code === 404) {
        logger.debug(`[bridge] renameSession ${sessionId.slice(0, 12)}… session 不存在,忽略`)
        return
      }
      throw err
    }
  }

  async replyPermission(
    requestID: string,
    reply: "once" | "always" | "reject",
    directory?: string,
  ): Promise<void> {
    if (!this.clientV2) throw new Error("opencode v2 client not ready")
    const result = await this.clientV2.permission.reply({ requestID, reply, directory: directory || undefined })
    if (result.error) {
      throw makeSdkError("permission.reply", result.error)
    }
  }

  async replyQuestion(
    requestID: string,
    answers: Array<Array<string>>,
    directory?: string,
  ): Promise<void> {
    if (!this.clientV2) throw new Error("opencode v2 client not ready")
    const result = await this.clientV2.question.reply({ requestID, answers, directory: directory || undefined })
    if (result.error) {
      throw makeSdkError("question.reply", result.error)
    }
  }

  async rejectQuestion(requestID: string, directory?: string): Promise<void> {
    if (!this.clientV2) throw new Error("opencode v2 client not ready")
    const result = await this.clientV2.question.reject({ requestID, directory: directory || undefined })
    if (result.error) {
      throw makeSdkError("question.reject", result.error)
    }
  }

  async getMessageHistory(
    sessionId: string,
  ): Promise<MessageRecord[]> {
    const resp = await this.requireClient().session.messages({
      path: { id: sessionId },
    })
    const msgs = (resp.data ||
      []) as Array<{
      info?: { role?: string; time?: { created?: number } }
      parts?: Array<{ type?: string; text?: string }>
    }>
    return msgs.map((m) => ({
      role: (m.info?.role === "user" ? "user" : "assistant") as
        | "user"
        | "assistant",
      text: extractText(m.parts || []),
      // info.time.created 为毫秒(opencode 时间统一毫秒),直接构造 Date。
      timestamp: m.info?.time?.created
        ? new Date(m.info.time.created).toISOString()
        : new Date().toISOString(),
    }))
  }

  // 取 opencode 回合(assistant message)耗时(秒)。step-finish part 不含 time 字段,
  // 回合起止从 message.info.time(created→completed,毫秒)计算。
  // 用 v2 client + limit:1 只拉最近消息(v1 拉全量历史在长会话易 terminated)。
  // 无 message / 无 completed → 返回 0(调用方降级为不显示耗时)。
  async getTurnDuration(sessionId: string): Promise<number> {
    try {
      const client = this.clientV2 ?? this.client
      if (!client) return 0
      // v2 session.messages 运行时参数平铺 {sessionID, limit}(sdk buildClientParams 提取),
      // 但 SDK 的 TS 类型错误声明为 {path:{sessionID}},这里按运行时形状断言。
      const resp = await (client as any).session.messages({
        sessionID: sessionId,
        limit: 1,
      })
      const msgs = (resp.data || []) as Array<{
        info?: { role?: string; time?: { created?: number; completed?: number } }
      }>
      // 取最后一条 assistant message(回合完成时为最新)
      for (let i = msgs.length - 1; i >= 0; i--) {
        const info = msgs[i]?.info
        if (info?.role === "assistant") {
          const created = info.time?.created
          const completed = info.time?.completed
          if (typeof created === "number" && typeof completed === "number") {
            const ms = completed - created
            if (ms > 0) {
              // opencode 时间统一毫秒(与 tool state.time 一致),转秒保留 1 位小数
              return Math.round(ms / 100) / 10
            }
          }
        }
      }
      return 0
    } catch {
      return 0
    }
  }

  // 取 opencode session 的可读标题,用于建群后改名。拿不到返空串(调用方降级用 sessionId 前缀)。
  async getSessionTitle(sessionId: string): Promise<string> {
    if (!this.client) return ""
    try {
      const resp = await this.client.session.get({ path: { id: sessionId } })
      const data = resp.data as { title?: string; metadata?: { title?: string } }
      return data.title || data.metadata?.title || ""
    } catch {
      return ""
    }
  }

  // 直接在本地文件系统执行 git 命令查 branch(绕过 OC vcs API)。
  // OC 1.18+ 的 vcs.get 对未初始化 vcs 索引的 project 返回 branch=null,
  // 且 project/git/init 会创建重复 project 记录(有副作用)。
  // 直接执行 git symbolic-ref 更可靠,且 plugin 有本地 fs 权限。
  // 非目录/非 git 仓库/任何错误 → 返回空串(fail-soft)。
  static async getGitBranch(directory: string): Promise<string> {
    if (!directory) return ""
    try {
      const { execFile } = await import("child_process")
      const result = await new Promise<string>((resolve, reject) => {
        execFile("git", ["symbolic-ref", "--short", "HEAD"], {
          cwd: directory,
          timeout: 3000,
          maxBuffer: 256,
        }, (err, stdout) => {
          if (err) reject(err)
          else resolve(stdout.trim())
        })
      })
      return result || ""
    } catch {
      return ""
    }
  }

  // 取 opencode session 的工作目录(directory),用于:
  //   1. ensureConversation 建群时透传给 server conversations.directory(TUI 场景)
  //   2. RPC 方法(file-list/file-read/session-diff)按需调获取路径 anchor
  // 拿不到返空串(调用方降级:RPC 抛 directory not anchored,server 写 NULL)。
  async getSessionDirectory(sessionId: string): Promise<string> {
    if (!this.client) return ""
    try {
      const resp = await this.client.session.get({ path: { id: sessionId } })
      const data = resp.data as { directory?: string }
      return data.directory || ""
    } catch {
      return ""
    }
  }

  shutdown(): void {
    if (this.serverProcess) {
      this.serverProcess.kill()
      this.serverProcess = null
    }
  }
}
