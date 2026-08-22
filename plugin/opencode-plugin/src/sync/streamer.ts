import type { WanlingClient } from "../wanling/client.js"
import { logger } from "../utils/logger.js"
import type { EventSubscriber } from "../opencode/subscriber.js"
import type { RPCDispatcher } from "../rpc/dispatcher.js"
import type {
  AssistantMessageCompletedPayload,
  PartUpdatedPayload,
  SessionUpdatedPayload,
  VcsBranchUpdatedPayload,
} from "../opencode/subscriber.js"
import { type EnsureDeps } from "./ensure_conversation.js"
import { EventEmitter } from "events"
import type { SessionState, ChildSessionEntry } from "./types.js"
import { MessageRouter } from "./messaging.js"
import { SessionStore } from "./session_store.js"
import { MetaSync } from "./domains/meta_sync.js"
import { CompactionTracker } from "./domains/compaction.js"
import { ToolCardManager } from "./domains/tool_card.js"
import { PartDispatcher } from "./domains/part_dispatcher.js"
import { InteractionCards } from "./domains/interaction.js"
import { SessionLifecycle } from "./domains/session_lifecycle.js"
import { getAggregateCard } from "./domains/aggregate_bridge.js"

export class Streamer extends EventEmitter {
  // 子 session 兜底超时默认值:task 崩溃或漏发 completed/error SSE 时强制清理。
  // 复杂 task(多步规划 / 大范围重构 / 长 bash)可能跑很久,30min 阈值平衡
  // 「卡片卡死时长」与「正常长 task 不被误清理」。
  // I-O:实际值由构造参数注入(来自 config.childTimeoutMs / WANLING_CHILD_TIMEOUT_MS),
  // 运维可调整无需重编译;此常量仅作为未传入时的默认。
  private static readonly DEFAULT_CHILD_TIMEOUT_MS = 30 * 60 * 1000

  private subscriber: EventSubscriber
  private wanling: WanlingClient
  private mainSessionId: string
  private ensureDeps: EnsureDeps
  private dispatcher: RPCDispatcher
  // 跨事件共享状态仓:sessions / childSessionTree / partIndex / idleHandled /
  // createStateInflight 五个 map + getOrCreateState 幂等入口 + registerChild/cleanupChild
  // + flushReasoning/flushText 都收敛到 store。Streamer 通过 this.store.* 委托访问。
  private readonly store: SessionStore
  // session 元数据同步领域模块(providers/slash/capabilities 上报 +
  // session_updated/vcs_branch 同步 + step-finish loopEnd 主动同步)。
  // 持有 knownTitles/knownMeta/knownFullMeta/providerNames 四个状态 map。
  private readonly metaSync: MetaSync
  // compaction part 处理领域模块(running/done 状态机 + step-finish loopEnd 兜底 PATCH)。
  // 持有 compactionParts 状态 map(OC 1.18.3 抓包确认:同 partId 两次推送,首次 running
  // 第二次带 tail_start_id 切 done;实测 OC 不发第二次,靠 step-finish 兜底)。
  private readonly compaction: CompactionTracker
  // tool/task 卡片状态机领域模块(普通 tool + task 工具的 running/completed/error
  // + inflight Promise 竞态修复 + childSessionTree 注册经 store 委托)。
  // 不持有状态(toolPartsSent/toolCardMsgIds/toolCardInflight/pendingToolCard 都在
  // SessionState 上随 state 流动),错误经注入的 emitter(this)上抛。
  private readonly toolCard: ToolCardManager
  // part_updated/part_delta 分发领域模块(reasoning/text/step-finish case + delta 增量
  // + flush 缓冲)。tool/compaction case 由 ToolCard/Compaction 各自订阅 part_updated
  // 自行过滤,本模块只处理 reasoning/text/step-finish。错误经注入的 emitter(this)上抛。
  private readonly partDispatcher: PartDispatcher
  // permission/question 交互卡片领域模块(正向流发卡 + 反向流 PATCH 终态 +
  // 启动孤儿卡片清理)。不持有状态(card_store 是模块级单例)。
  // 错误经注入的 emitter(this)上抛。
  private readonly interaction: InteractionCards
  // session 状态/心跳/flush 兜底领域模块(busy/retry/idle 透传 + 20s 心跳保活 +
  // session.idle flush 兜底)。持有 activeSessions + heartbeatTimer 两个状态。
  private readonly lifecycle: SessionLifecycle
  private started = false
  private readonly router: MessageRouter
  // 聚合卡开关(构造时存储,与 PartDispatcher/ToolCardManager 的 useAggregate 同语义)。
  private readonly aggregateCardEnabled: boolean

  constructor(
    subscriber: EventSubscriber,
    wanling: WanlingClient,
    mainSessionId: string,
    ensureDeps: Omit<EnsureDeps, "wanling">,
    dispatcher: RPCDispatcher,
    childTimeoutMs?: number,
    aggregateCardEnabled?: boolean,
  ) {
    super()
    this.subscriber = subscriber
    this.wanling = wanling
    this.mainSessionId = mainSessionId
    this.aggregateCardEnabled = aggregateCardEnabled ?? true
    // wanling 以构造参数为准(单一实例来源),调用方传入的 deps 不含 wanling,这里统一补齐。
    this.ensureDeps = { ...ensureDeps, wanling }
    this.dispatcher = dispatcher
    this.router = new MessageRouter(wanling)
    this.store = new SessionStore({
      mainSessionId,
      ensureDeps: { ...ensureDeps, wanling },
      wanling,
      router: this.router,
      childTimeoutMs: childTimeoutMs ?? Streamer.DEFAULT_CHILD_TIMEOUT_MS,
    })
    this.metaSync = new MetaSync({
      store: this.store,
      router: this.router,
      wanling,
      opencode: this.ensureDeps.opencode,
      dispatcher,
    })
    this.compaction = new CompactionTracker({
      store: this.store,
      router: this.router,
      wanling,
    })
    this.toolCard = new ToolCardManager({
      store: this.store,
      router: this.router,
      wanling,
      emitter: this,
      aggregateCardEnabled: aggregateCardEnabled ?? true,
    })
    this.partDispatcher = new PartDispatcher({
      store: this.store,
      router: this.router,
      metaSync: this.metaSync,
      compaction: this.compaction,
      emitter: this,
      wanling,
      aggregateCardEnabled: aggregateCardEnabled ?? true,
    })
    this.interaction = new InteractionCards({
      store: this.store,
      router: this.router,
      wanling,
      opencode: this.ensureDeps.opencode,
      toolCard: this.toolCard,
      emitter: this,
      aggregateCardEnabled: aggregateCardEnabled ?? true,
    })
    this.lifecycle = new SessionLifecycle({
      store: this.store,
      router: this.router,
      wanling,
      partDispatcher: this.partDispatcher,
      emitter: this,
    })
  }

  updateMainSessionId(id: string): void {
    if (id && id !== this.mainSessionId) {
      logger.info(`[streamer] main session 切换: ${this.mainSessionId.slice(0, 12)}… → ${id.slice(0, 12)}…`)
      this.mainSessionId = id
      // 同步给 store:getOrCreateState 的主/非主判定依赖此值
      this.store.updateMainSessionId(id)
    }
  }

  // 兼容访问器(供 streamer.test.ts 通过 (streamer as any).sessions / .childSessionTree
  // 直接 .set/.get/.has 访问 map):映射到 store 内部 map。
  // 待后续 task 把测试改造为通过 SessionStore 公开 API 访问后可移除。
  private get sessions(): Map<string, SessionState> {
    return this.store.sessions
  }

  private get childSessionTree(): Map<string, ChildSessionEntry> {
    return this.store.childSessionTree
  }

  // 兼容委托(供 streamer.test.ts 直接调 (streamer as any)._registerChildSession):
  // 转发到 store.registerChild。待测试改造后移除。
  private _registerChildSession(
    parentState: SessionState,
    taskCardMsgId: string,
    childSessionId: string,
    parentSessionId: string | undefined,
    taskInput: Record<string, unknown>,
  ): ChildSessionEntry {
    return this.store.registerChild(parentState, taskCardMsgId, childSessionId, parentSessionId, taskInput)
  }

  // 兼容访问器(供 streamer.test.ts 通过 (streamer as any).providerNames 直接 .set/.get
  // 访问):映射到 metaSync 内部 map。待后续 task 把测试改造为通过 MetaSync 公开 API
  // 访问后可移除。
  private get providerNames(): Map<string, { modelName: string; providerName: string; contextLimit: number }> {
    return this.metaSync.providerNames
  }

  // 兼容委托(供 streamer.test.ts 直接调 (streamer as any).loadProviderNames /
  // loadSlashCatalog / loadCapabilities / onSessionUpdated / onVcsBranchUpdated):
  // 转发到 metaSync。待后续 task 把测试改造为通过 MetaSync 公开 API 访问后可移除。
  private async loadProviderNames(): Promise<void> {
    await this.metaSync.loadProviderNames()
  }
  private async loadSlashCatalog(): Promise<void> {
    await this.metaSync.loadSlashCatalog()
  }
  private async loadCapabilities(): Promise<void> {
    await this.metaSync.loadCapabilities()
  }
  private async onSessionUpdated(payload: SessionUpdatedPayload): Promise<void> {
    await this.metaSync.onSessionUpdated(payload)
  }
  private async onVcsBranchUpdated(payload: VcsBranchUpdatedPayload): Promise<void> {
    await this.metaSync.onVcsBranchUpdated(payload)
  }

  start(): void {
    if (this.started) return
    this.started = true

    // 启动时清理孤儿卡片：plugin 重启 = SSE 断开期间 pending 卡片的 opencode 端
    // 上下文可能已丢失（session 过期 / serve 重启），统一 PATCH 为 expired，
    // 防止入口行永远显示「待处理 N 项」。
    void this.interaction.cleanupOrphans()

    // 加载 providers + slash catalog + capabilities 并发上报(metaSync 内部 Promise.all)
    void this.metaSync.loadAll()

    // part_updated 事件三路分发:PartDispatcher(reasoning/text/step-finish)、
    // ToolCardManager(tool)、CompactionTracker(compaction)各自订阅同一事件,
    // 按 part.type 自行过滤。三路独立 try/catch,互不阻塞。
    this.subscriber.on("part_updated", (payload) => this.partDispatcher.onPartUpdated(payload))
    this.subscriber.on("part_updated", (payload) => this.dispatchToolPart(payload))
    this.subscriber.on("part_updated", (payload) => this.dispatchCompactionPart(payload))
    this.subscriber.on("part_delta", (payload) => this.partDispatcher.onPartDelta(payload))
    this.subscriber.on("session_status", (payload) => this.lifecycle.onSessionStatus(payload))
    this.subscriber.on("session_idle", (payload) => this.lifecycle.onSessionIdle(payload.sessionID))
    this.subscriber.on("session_updated", (payload) => this.metaSync.onSessionUpdated(payload))
    this.subscriber.on("vcs_branch_updated", (payload) => this.metaSync.onVcsBranchUpdated(payload))
    // 新 assistant 回合开始(opencode 建新 assistant message,parentID 指向新 user
    // 消息)→ 结束当前聚合卡段落(interrupt footer + reset),下一条回答开新卡。
    // 时序可靠:opencode 对新回合的 assistant message 在此事件前已将旧回合以
    // tool-calls/stop 完成,此时旧卡内容已完整,分段不会截断流式输出。
    this.subscriber.on("assistant_message_started", (payload) => {
      void this.finishCardForSession(payload.sessionID, "interrupt")
    })
    // assistant 回合完成(completed + finish 非 tool-calls/unknown,对齐 TUI final()):
    // 回合正常结束,聚合卡收尾(footer 带完整 duration/cost/tokens/mode/model + reset)。
    // 此时 completed 已落库,duration = completed - user.created 可直接计算,零轮询。
    // 时序:旧回合 completed 先于新回合创建到达(已验证),footer 追加正确卡片。
    this.subscriber.on("assistant_message_completed", (payload) => {
      void this.finalizeCardForSession(payload)
    })

    // 交互事件
    this.subscriber.on("approval_request", (payload) => this.interaction.onPermissionAsked(payload))
    this.subscriber.on("question_asked", (payload) => this.interaction.onQuestionAsked(payload))
    this.subscriber.on("permission_replied", (payload) => this.interaction.onPermissionReplied(payload))
    this.subscriber.on("question_replied", (payload) => this.interaction.onQuestionReplied(payload))
    this.subscriber.on("question_rejected", (payload) => this.interaction.onQuestionRejected(payload))

  }

  // 供 engine(停止/分段)触发的聚合卡主动收尾:查 session 对应 state 的聚合卡。
  // 停止(abort)→ finishCard("stop")(APP 显示「已停止」);排队分段 → finishCard("interrupt")。
  async finishCardForSession(sessionId: string, reason: "stop" | "interrupt"): Promise<void> {
    const state = await this.store.getOrCreateState(sessionId)
    if (!state) return
    if (!this.aggregateCardEnabled || state.isChildSession) return
    await getAggregateCard(state, this.wanling)
      .finishCard(reason)
      .catch((err) => {
        console.error(`[streamer] finishCard(${reason}) 失败: ${err instanceof Error ? err.message : String(err)}`)
      })
  }

  // assistant 回合完成的聚合卡收尾(assistant_message_completed 事件驱动,对齐 TUI final()):
  // 此时 completed 已落库,duration = completed - user.created(parentID 归属)可直接计算。
  // footerDraft 由 step-finish 暂存(cost/tokens/reason),这里合并;meta 快照取 knownFullMeta。
  // 幂等:finalizeCard 内部守卫(卡已 done / 未建卡跳过);若被 finishCard(abort/分段)
  // 先收尾,此处静默跳过。
  private async finalizeCardForSession(
    payload: AssistantMessageCompletedPayload,
  ): Promise<void> {
    const state = await this.store.getOrCreateState(payload.sessionID)
    if (!state) return
    if (!this.aggregateCardEnabled || state.isChildSession) return
    // 回合耗时起点:parent user 消息的 created(subscriber 缓存)。缺失则降级不显示耗时。
    const userCreated = this.subscriber.peekUserCreated(payload.parentID)
    // 回合耗时(毫秒,对齐 TUI:`message.time.completed - user.time.created` 原始毫秒,
    // APP 端用 Locale.duration 格式化;不转秒否则 <100ms 变 0)。
    const duration = userCreated
      ? Math.max(0, payload.completed - userCreated)
      : 0
    const draft = state.footerDraft
    const footerMeta = this.metaSync.peekFullMeta(payload.sessionID)
    await getAggregateCard(state, this.wanling)
      .finalizeCard({
        reason: draft?.reason ?? "stop",
        duration,
        cost: draft?.cost,
        tokens: draft?.tokens,
        mode: footerMeta?.mode,
        model: footerMeta ? (footerMeta.modelName ?? footerMeta.modelId) : undefined,
      })
      .catch((err) => {
        console.error(`[streamer] finalizeCard 失败: ${err instanceof Error ? err.message : String(err)}`)
      })
  }

  // 兼容委托(供 streamer.test.ts 直接调 (streamer as any).onPartUpdated):
  // 串行扇出三路分发,等价于三路 subscriber 同步触发(测试环境无 subscriber,
  // 必须显式调用三路才能覆盖 tool/compaction case 的回归网)。待测试改造后移除。
  private async onPartUpdated(payload: PartUpdatedPayload): Promise<void> {
    await this.partDispatcher.onPartUpdated(payload)
    await this.dispatchToolPart(payload)
    await this.dispatchCompactionPart(payload)
  }

  // part_updated → ToolCardManager 分发(tool case)。
  // 与 PartDispatcher 独立订阅同一事件,这里按 part.type==="tool" 过滤后做 state 查询
  // (getOrCreateState 幂等,与 PartDispatcher 的查询共享 inflight promise 不重复建群)。
  private async dispatchToolPart(payload: PartUpdatedPayload): Promise<void> {
    if (payload.part.type !== "tool") return
    try {
      const state = await this.store.getOrCreateState(payload.sessionID)
      if (!state) return
      await this.toolCard.onPartUpdated(payload.part, state, payload.sessionID)
    } catch (err) {
      this.emit("error", err instanceof Error ? err : new Error(String(err)))
    }
  }

  // part_updated → CompactionTracker 分发(compaction case)。
  // 同 dispatchToolPart,state 查询幂等复用 PartDispatcher 的 inflight。
  private async dispatchCompactionPart(payload: PartUpdatedPayload): Promise<void> {
    if (payload.part.type !== "compaction") return
    try {
      const state = await this.store.getOrCreateState(payload.sessionID)
      if (!state) return
      await this.compaction.handlePart(payload.part, state)
    } catch (err) {
      this.emit("error", err instanceof Error ? err : new Error(String(err)))
    }
  }

  // 兼容委托(供 streamer.test.ts 直接调 (streamer as any).onSessionStatus /
  // onSessionIdle / _startHeartbeat / .activeSessions / .heartbeatTimer):
  // 转发到 lifecycle。待后续 task 把测试改造为通过 SessionLifecycle 公开 API
  // 访问后可移除。
  private onSessionStatus(payload: Parameters<SessionLifecycle["onSessionStatus"]>[0]): void {
    this.lifecycle.onSessionStatus(payload)
  }

  private async onSessionIdle(sessionID: string): Promise<void> {
    await this.lifecycle.onSessionIdle(sessionID)
  }

  private get activeSessions(): Set<string> {
    return this.lifecycle.activeSessions
  }

  private get heartbeatTimer(): ReturnType<typeof setInterval> | null {
    return this.lifecycle.heartbeatTimer
  }

  private _startHeartbeat(): void {
    this.lifecycle.startHeartbeat()
  }

  // 兼容委托(供 streamer.test.ts 直接调 (streamer as any).onPermissionAsked /
  // onQuestionAsked):转发到 interaction。待测试改造后移除。
  private async onPermissionAsked(payload: Parameters<InteractionCards["onPermissionAsked"]>[0]): Promise<void> {
    await this.interaction.onPermissionAsked(payload)
  }

  private async onQuestionAsked(payload: Parameters<InteractionCards["onQuestionAsked"]>[0]): Promise<void> {
    await this.interaction.onQuestionAsked(payload)
  }

  stop(): void {
    this.started = false
    // lifecycle.stop 清心跳 timer + activeSessions;store.stop 内联了 flush all
    // reasoning/text(经 router)+ 撤销所有 child session 兜底 timer + 清空
    // sessions/childSessionTree/partIndex/idleHandled。
    this.lifecycle.stop()
    this.store.stop()
    // knownTitles/knownMeta/knownFullMeta/providerNames 状态已迁入 metaSync,
    // 由 metaSync 自身持有(streamer.stop 不再清理;模块销毁即清理)。
  }
}
