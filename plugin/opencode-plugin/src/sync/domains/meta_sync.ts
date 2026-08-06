import type { WanlingClient } from "../../wanling/client.js"
import type { RPCDispatcher } from "../../rpc/dispatcher.js"
import { OpencodeBridge } from "../../opencode/bridge.js"
import type {
  SessionUpdatedPayload,
  VcsBranchUpdatedPayload,
} from "../../opencode/subscriber.js"
import { findBySessionId } from "../mapper.js"
import type { SessionStore } from "../session_store.js"
import type { MessageRouter } from "../messaging.js"

// MetaSync:session 元数据同步领域模块。
// 职责:providers/slash/capabilities 启动上报 + session_updated/vcs_branch_updated
// 被动同步 + step-finish loopEnd 主动同步。
// 依赖 store(peekConvId/peekMainSessionId)、router、wanling、opencode、dispatcher。
// 持有 knownTitles/knownMeta/knownFullMeta/providerNames 四个状态 map(从 Streamer 迁入)。
export class MetaSync {
  private readonly store: SessionStore
  private readonly router: MessageRouter
  private readonly wanling: WanlingClient
  private readonly opencode: OpencodeBridge
  private readonly dispatcher: RPCDispatcher

  private knownTitles: Map<string, string> = new Map()
  private knownMeta: Map<string, string> = new Map()
  // 方案 B 缓存:server UpdateSessionMeta 是整 JSON 覆盖写,vcs_branch_updated
  // 增量更新时若只发 {gitBranch},会把 mode/model 覆盖成空。
  // onSessionUpdated 成功发完后写缓存,onVcsBranchUpdated 读缓存拼完整 meta 再发。
  // 缓存 key 用 sessionID;同一 session 的 mode/model/branch 改动都更新同一 entry。
  // directory 仍作内部缓存(供 _syncMetaAfterLoopEnd session.get 失败时 fallback
  // 调 fetchGitBranch),但不写入 session_meta(已升级到 conversations.directory 一级列)。
  private knownFullMeta: Map<string, {
    mode: string
    modelId: string
    providerId: string
    variant?: string
    modelName?: string
    providerName?: string
    directory: string
    gitBranch: string
    tokensTotal: number
    contextUsed: number
    contextLimit: number
  }> = new Map()
  // public readonly(迁移过渡期):Streamer 保留同名 getter 供 streamer.test.ts 通过
  // (streamer as any).providerNames 直接 .set/.get 访问。待后续 task 把测试改造为
  // 通过 MetaSync 公开 API 访问后可改回 private。
  public readonly providerNames: Map<string, { modelName: string; providerName: string; contextLimit: number }> = new Map()

  constructor(deps: {
    store: SessionStore
    router: MessageRouter
    wanling: WanlingClient
    opencode: OpencodeBridge
    dispatcher: RPCDispatcher
  }) {
    this.store = deps.store
    this.router = deps.router
    this.wanling = deps.wanling
    this.opencode = deps.opencode
    this.dispatcher = deps.dispatcher
  }

  async loadAll(): Promise<void> {
    await Promise.all([this.loadProviderNames(), this.loadSlashCatalog(), this.loadCapabilities()])
  }

  // public(迁移过渡期):Streamer 保留同名委托方法供 streamer.test.ts 通过
  // (streamer as any).loadProviderNames 直接调用。待后续 task 把测试改造为通过
  // MetaSync 公开 API 访问后可降级为 private。
  public async loadProviderNames(): Promise<void> {
    try {
      const client = this.opencode.getClient()
      if (!client) return
      const resp = await client.config.providers()
      const data = resp.data as {
        providers?: Array<{
          id: string
          name?: string
          models?: Record<string, { name?: string; limit?: { context?: number } }>
        }>
      } | undefined
      if (!data?.providers) return
      for (const p of data.providers) {
        const providerName = p.name ?? p.id
        const models = p.models ?? {}
        for (const [modelId, model] of Object.entries(models)) {
          this.providerNames.set(`${p.id}/${modelId}`, {
            modelName: model.name ?? modelId,
            providerName,
            contextLimit: model.limit?.context ?? 0,
          })
        }
      }

      // Fallback:自定义 provider 的 model.limit.context=0 时,从标准 provider 同名 modelId 兜底。
      // 标准 provider(zhipuai-coding-plan / opencode Zen 等)带 canonical limit,
      // 用户自定义 provider 通常只配 baseURL+apiKey 不配 limit,需要兜底才能显示百分比。
      const modelIdToContextLimit = new Map<string, number>()
      for (const [key, info] of this.providerNames) {
        const modelId = key.split("/")[1]
        if (info.contextLimit > 0 && !modelIdToContextLimit.has(modelId)) {
          modelIdToContextLimit.set(modelId, info.contextLimit)
        }
      }
      for (const [key, info] of this.providerNames) {
        if (info.contextLimit === 0) {
          const modelId = key.split("/")[1]
          const fallback = modelIdToContextLimit.get(modelId)
          if (fallback) info.contextLimit = fallback
        }
      }

      console.log(`[streamer] providers 缓存: ${this.providerNames.size} models`)

      // 上报给 server:构造 ModelInfo 数组(4 字段 snake_case,无 status)。
      // server AgentRegistry 缓存后供 APP GET /api/agents/:id/models 拉取。
      // agentId 从 wanling client 读取(单一来源),WS 未连接时 sendAgentModels silently drop,
      // 下次重连 loadProviderNames 会重跑重报。
      const reportModels: Array<{
        provider_id: string
        provider_name: string
        model_id: string
        model_name: string
      }> = []
      for (const p of data.providers) {
        const providerName = p.name ?? p.id
        const models = p.models ?? {}
        for (const [modelId, model] of Object.entries(models)) {
          reportModels.push({
            provider_id: p.id,
            provider_name: providerName,
            model_id: modelId,
            model_name: model.name ?? modelId,
          })
        }
      }
      this.wanling.sendAgentModels(this.wanling.agentId, reportModels)
      console.log(`[streamer] AGENT_MODELS 已上报: ${reportModels.length} models`)
    } catch (err) {
      console.error(`[streamer] loadProviderNames 失败: ${err instanceof Error ? err.message : err}`)
    }
  }

  public async loadSlashCatalog(): Promise<void> {
    try {
      const client = this.opencode.getClient()
      if (!client) return
      const resp = await client.command.list()
      const rawCommands = (resp.data as Array<{ name: string; template: string; description?: string; source?: string }> | undefined) ?? []
      const commands = rawCommands.map((c) => ({
        name: c.name,
        template: c.template,
        description: c.description,
        // OC 不返 source 时降级为 "skill"(抓包确认实际都返,降级仅防御)
        source: c.source ?? "skill",
      }))
      // compact 不在 OC /command 返回里(它是 UI 快捷键直触 /summarize),
      // plugin 端补一条让 APP 命令面板显示,source=command 归到「命令」组。
      // engine.handleIncomingMessage 的 _slash 分支会拦截 name=compact 特判走 summarizeSession。
      // Dedup 守卫:防御 OC 未来版本开始在 command.list 返回 compact 导致双倍条目,
      // 当前(OC 1.18.3)抓包确认不返回,守卫仅 future-proof。
      let pluginPushedCompact = 0
      if (!commands.some((c) => c.name === "compact")) {
        commands.push({
          name: "compact",
          template: "/compact",
          description: "压缩上下文",
          source: "command",
        })
        pluginPushedCompact = 1
      }
      this.wanling.sendAgentSlashCatalog(this.wanling.agentId, commands)
      console.log(`[streamer] loadSlashCatalog: ${commands.length} commands (plugin-push compact=${pluginPushedCompact}), source=${commands.filter(c => c.source === "command").length} command / ${commands.filter(c => c.source === "skill").length} skill`)
    } catch (err) {
      console.error(`[streamer] loadSlashCatalog 失败: ${err instanceof Error ? err.message : err}`)
    }
  }

  public   async loadCapabilities(): Promise<void> {
    try {
      const agentId = this.wanling.agentId
      if (!agentId) return
      const methods = this.dispatcher.listMethods()
      this.wanling.sendPluginCapabilities(agentId, methods)
      console.log(`[streamer] PLUGIN_CAPABILITIES 已上报: ${methods.length} methods`)
    } catch (err) {
      console.error(`[streamer] loadCapabilities 失败: ${err instanceof Error ? err.message : err}`)
    }
  }

  // 回合结束 footer 快照读取:PartDispatcher 构造 footer 时把当时的 mode/model
  // 写进 footer data(消息快照)。sessionMeta 是会话实时态会变动,提示条应读快照。
  peekFullMeta(sessionID: string): { mode: string; modelId: string; modelName?: string } | undefined {
    const meta = this.knownFullMeta.get(sessionID)
    if (!meta) return undefined
    return {
      mode: meta.mode,
      modelId: meta.modelId,
      ...(meta.modelName !== undefined ? { modelName: meta.modelName } : {}),
    }
  }

  // 回合结束 footer 耗时读取:step-finish part 不含 time,回合起止从
  // assistant message.info.time(created→completed)计算(委托 bridge.getTurnDuration)。
  // 失败/无 completed 返回 0(调用方降级为不显示耗时)。
  async fetchTurnDuration(sessionID: string): Promise<number> {
    try {
      return await this.opencode.getTurnDuration(sessionID)
    } catch {
      return 0
    }
  }

  async onSessionUpdated(payload: SessionUpdatedPayload): Promise<void> {
    const map = findBySessionId(payload.sessionID)
    if (!map) return

    // 1. 标题同步（title 变了才发）
    // 断环靠 server 侧:updateConversationTitle 走 agent 视角 UpdateTitleAsAgent,
    // 其 BroadcastConversationUpdateToUsers 只推 user 不推 agent,plugin 收不到
    // 自己触发的回声。knownTitles 去重兜底:APP 改名经 plugin renameSession 回写,
    // title 相同不重复发。
    if (payload.title && this.knownTitles.get(payload.sessionID) !== payload.title) {
      try {
        await this.wanling.updateConversationTitle(map.wanlingConvId, payload.title)
        this.knownTitles.set(payload.sessionID, payload.title)
        console.log(`[streamer] 会话标题同步: ${map.wanlingConvId.slice(0, 8)}… ← "${payload.title}"`)
      } catch (err) {
        console.error(`[streamer] 会话标题同步失败: ${err instanceof Error ? err.message : err}`)
      }
    }

    // 2. session meta 同步（mode/model/variant 变了才发)
    //    注意:cwd(directory)已升级到 server conversations.directory 一级列,
    //    不再走 session_meta JSONB,故 metaKey 不含 directory。
    const metaKey = `${payload.mode}|${payload.model.id}|${payload.model.providerID}|${payload.model.variant ?? ""}`
    if (this.knownMeta.get(payload.sessionID) !== metaKey && payload.model.id) {
      // 从缓存查规范名称
      const cacheKey = `${payload.model.providerID}/${payload.model.id}`
      const cached = this.providerNames.get(cacheKey)
      // vcs.get 拉初始 branch(directory 仍从 payload 拿用于查 branch,非 git 目录或失败降级空串)
      const gitBranch = await this.fetchGitBranch(payload.directory)
      // 计算 tokensTotal(累计):onSessionUpdated 携带的是 OC 累计值
      const rawTokens = payload.tokens
      const tokensTotal = rawTokens
        ? rawTokens.input + rawTokens.output + rawTokens.reasoning
          + rawTokens.cache.read + rawTokens.cache.write
        : 0
      // 从 providerNames 缓存查 contextLimit(loadProviderNames 可能尚未完成,fallback 0)
      const contextLimit = cached?.contextLimit ?? 0
      try {
        await this.wanling.updateSessionMeta(map.wanlingConvId, {
          mode: payload.mode,
          modelId: payload.model.id,
          providerId: payload.model.providerID,
          variant: payload.model.variant,
          modelName: cached?.modelName ?? payload.model.id,
          providerName: cached?.providerName ?? payload.model.providerID,
          gitBranch,
          tokensTotal,
          // contextUsed 在 onSessionUpdated 不知道本次 LLM 调用,先用 0,
          // _syncMetaAfterLoopEnd 收到 step_finish 时填实际值。
          contextUsed: 0,
          contextLimit,
        })
        this.knownMeta.set(payload.sessionID, metaKey)
        // 方案 B:缓存全字段,vcs_branch_updated 增量更新时读缓存拼完整 meta 防覆盖。
        // directory 仍在缓存里(供 _syncMetaAfterLoopEnd session.get 失败时 fallback 查 branch),
        // 但不写入 session_meta JSONB(已升级到 conversations.directory 一级列)。
        this.knownFullMeta.set(payload.sessionID, {
          mode: payload.mode,
          modelId: payload.model.id,
          providerId: payload.model.providerID,
          variant: payload.model.variant,
          modelName: cached?.modelName ?? payload.model.id,
          providerName: cached?.providerName ?? payload.model.providerID,
          directory: payload.directory,
          gitBranch,
          tokensTotal,
          contextUsed: 0,
          contextLimit,
        })
        console.log(`[streamer] session meta 同步: ${map.wanlingConvId.slice(0, 8)}… ← ${metaKey}`)
      } catch (err) {
        console.error(`[streamer] session meta 同步失败: ${err instanceof Error ? err.message : err}`)
      }
    }
  }

  // vcs.branch.updated 事件处理:运行中切分支时增量同步 gitBranch。
  // server UpdateSessionMeta 是整 JSON 覆盖写,不能只发 {gitBranch},否则会把
  // mode/model 覆盖成空。方案 B:读 knownFullMeta 缓存拼完整 meta 再发。
  // 缓存未命中(vcs_branch_updated 先于 session_updated 到达)的兜底:发全字段空壳 + branch,
  // 此场景实战极少(进入会话才切分支),保留兜底防卡片空白,等 session_updated 真正到来再补全。
  // 注意:cwd 不再写入 session_meta(已升级到 conversations.directory 一级列)。
  async onVcsBranchUpdated(payload: VcsBranchUpdatedPayload): Promise<void> {
    const map = findBySessionId(payload.sessionID)
    if (!map) return

    // 去重:同 branch 不重复发(防 SSE 重连重放)
    const branchKey = `branch|${payload.branch}`
    const dedupKey = `${payload.sessionID}:branch`
    if (this.knownMeta.get(dedupKey) === branchKey) return
    this.knownMeta.set(dedupKey, branchKey)

    const full = this.knownFullMeta.get(payload.sessionID)
    const metaToSend = full
      ? { ...full, gitBranch: payload.branch }
      : {
          mode: "", modelId: "", providerId: "", variant: "",
          modelName: "", providerName: "",
          gitBranch: payload.branch,
          tokensTotal: 0, contextUsed: 0, contextLimit: 0,
        }

    try {
      await this.wanling.updateSessionMeta(map.wanlingConvId, metaToSend)
      // 同步更新缓存中的 gitBranch,后续 vcs_branch_updated 读到的是最新值
      if (full) {
        full.gitBranch = payload.branch
      }
      console.log(`[streamer] vcs branch 同步: ${map.wanlingConvId.slice(0, 8)}… ← ${payload.branch}`)
    } catch (err) {
      console.error(`[streamer] vcs branch 同步失败: ${err instanceof Error ? err.message : err}`)
    }
  }

  // 在 directory 下查当前 git branch。
  // OC 1.18+ 的 vcs.get 对未初始化 vcs 索引的 project 返回 branch=null,
  // 且 project/git/init 会创建重复 project 记录(有副作用)。
  // 方案:先试 OC vcs.get(快,走 SSE 同一连接),空则 fallback 直接执行 git 命令(可靠)。
  // - directory 为空 / 非 git 目录 / 任何失败 → 返回空串(fail-soft)
  private async fetchGitBranch(directory: string): Promise<string> {
    if (!directory) return ""
    // 先试 OC vcs.get(已初始化的 project 能直接返回)
    const client = this.opencode.getClient()
    if (client) {
      try {
        const resp = await client.vcs.get({ query: { directory } })
        const branch = resp.data?.branch
        if (branch) return branch
      } catch (err) {
        console.warn(`[streamer] vcs.get 失败(${directory}): ${err instanceof Error ? err.message : err}`)
      }
    }
    // vcs.get 返回空或失败:fallback 直接执行 git 命令
    return OpencodeBridge.getGitBranch(directory)
  }

  // 主 session agent 循环结束(step-finish reason=stop)后,主动同步 session_meta。
  // 根因:用户可能在 shell 里 git checkout(OC 不发 vcs.branch.updated),
  // plugin 不主动同步的话 EnvMetaStrip 永远显示旧 branch。
  // 流程:session.get 一次性拉 directory + 累计 tokens → vcs.get 用 directory 拉 branch → updateSessionMeta 覆盖。
  // 缓存未命中(plugin 重启后 / session.updated 未发过)仍可工作,因为 directory 来自 session.get 而非缓存。
  // server UpdateSessionMeta 写完库会广播 SESSION_META_UPDATE → APP 实时刷新。
  //
  // token 三字段(tokensTotal/contextUsed/contextLimit)语义:
  //   - tokensTotal  = session.get 拉 Session.tokens 累计真实值(避免 plugin 端累加漂移)
  //   - contextUsed  = 本次 step_finish 的 input + cache.read(调用方传入)
  //   - contextLimit = providerNames 缓存的 model contextLimit
  // session.get 失败或返回无 tokens → 三字段全 0,APP 不渲染 token 段(向后兼容,旧版 APP 无该字段也不报错)。
  async syncAfterLoopEnd(sessionID: string, contextUsed: number): Promise<void> {
    const full = this.knownFullMeta.get(sessionID)
    if (!full) return
    const map = findBySessionId(sessionID)
    if (!map) return

    // 主动 session.get 拉 OC 累计 tokens + directory(directory 升级为一级列后,
    // knownFullMeta 仍缓存 directory 作 fallback,session.get 失败时用缓存查 branch)。
    let tokensTotal = 0
    let reportedContextUsed = 0
    let contextLimit = 0
    let directory = full.directory // fallback 默认用缓存值
    try {
      const client = this.opencode.getClient()
      if (client) {
        const resp = await client.session.get({ path: { id: sessionID } })
        const sess = resp.data as
          | { directory?: string; tokens?: { input?: number; output?: number; reasoning?: number; cache?: { read?: number; write?: number } } }
          | undefined
        if (sess?.directory) directory = sess.directory
        const t = sess?.tokens
        if (t && typeof t.input === "number") {
          tokensTotal = t.input + (t.output ?? 0) + (t.reasoning ?? 0)
            + (t.cache?.read ?? 0) + (t.cache?.write ?? 0)
          reportedContextUsed = contextUsed
          // contextLimit 实时从 providerNames 查(loadProviderNames 异步,
          // 可能晚于首次 session.updated 完成,这里读到的是最新值)
          const providerCache = this.providerNames.get(`${full.providerId}/${full.modelId}`)
          contextLimit = providerCache?.contextLimit ?? 0
        }
      }
    } catch (err) {
      console.warn(`[streamer] session.get 拉失败(${sessionID.slice(0, 12)}): ${err instanceof Error ? err.message : err}`)
      // 三字段保持 0,APP 不渲染 token 段,向后兼容
      // directory 用缓存值(full.directory),仍能查 gitBranch
    }

    const gitBranch = await this.fetchGitBranch(directory)

    // server UpdateSessionMeta 整 JSON 覆盖写,这里必须拼全字段(读 knownFullMeta)。
    // 注意:cwd 字段不写(server 端已剔除,APP 从 conversation.directory 读)。
    const metaToSend = {
      mode: full.mode,
      modelId: full.modelId,
      providerId: full.providerId,
      variant: full.variant,
      modelName: full.modelName,
      providerName: full.providerName,
      gitBranch,
      tokensTotal,
      contextUsed: reportedContextUsed,
      contextLimit,
    }
    await this.wanling.updateSessionMeta(map.wanlingConvId, metaToSend)
    // 同步更新缓存 branch/tokens,后续 vcs.branch.updated dedup 基线正确。
    full.gitBranch = gitBranch
    full.tokensTotal = tokensTotal
    full.contextUsed = reportedContextUsed
    full.contextLimit = contextLimit
    console.log(`[streamer] step-finish meta 同步: ${map.wanlingConvId.slice(0, 8)}… ← branch=${gitBranch} tokens=${tokensTotal} used=${reportedContextUsed}/${contextLimit}`)
  }
}
