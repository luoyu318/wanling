import type { WanlingClient } from "../wanling/client.js"
import { logger } from "../utils/logger.js"
import type { EnsureDeps } from "./ensure_conversation.js"
import { ensureConversation } from "./ensure_conversation.js"
import { findBySessionId } from "./mapper.js"
import type { SessionState, ChildSessionEntry } from "./types.js"
import type { MessageRouter } from "./messaging.js"
import { getAggregateCard } from "./domains/aggregate_bridge.js"

// SessionStore:跨事件共享状态仓。
// 持有 sessions / childSessionTree / partIndex / idleHandled / createStateInflight
// 五个 map 与 getOrCreateState 的幂等入口,集中管理所有「同一 session 跨多次 SSE 事件
// 必须共享的状态」。Streamer 通过 this.store.* 委托访问。
//
// sessions / childSessionTree 暴露为 public readonly:迁移过渡期 Streamer 保留
// 同名 getter 供 streamer.test.ts 通过 (streamer as any).sessions / .childSessionTree
// 直接 .set/.get/.has 访问 map。后续 task 把测试改造为通过 SessionStore 公开 API
// 访问后可改回 private。
export class SessionStore {
  private mainSessionId: string
  private readonly ensureDeps: EnsureDeps
  private readonly wanling: WanlingClient
  private readonly router: MessageRouter
  private readonly childTimeoutMs: number

  public readonly sessions: Map<string, SessionState> = new Map()
  private createStateInflight = new Map<string, Promise<SessionState | null>>()
  // idle 去重:session.status type=idle 和 session.idle 独立事件可能都触发 onSessionIdle。
  // 记录最近处理的 idle sessionID+时间戳，5 秒内不重复发结束信号。
  private idleHandled: Map<string, number> = new Map()
  // 子 session 注册表: childSessionId → ChildSessionEntry。
  // Task 7 在 task/running 命中时 .set,这里只搭框架,允许 getOrCreateState 命中后透传。
  public readonly childSessionTree: Map<string, ChildSessionEntry> = new Map()
  private partIndex: Map<string, SessionState> = new Map()

  constructor(deps: {
    mainSessionId: string
    ensureDeps: EnsureDeps
    wanling: WanlingClient
    router: MessageRouter
    childTimeoutMs: number
  }) {
    this.mainSessionId = deps.mainSessionId
    this.ensureDeps = deps.ensureDeps
    this.wanling = deps.wanling
    this.router = deps.router
    this.childTimeoutMs = deps.childTimeoutMs
  }

  // 输出路由（OC sessionID → APP convId）只读查询，绝不反向改写映射。
  // 已登记 session（mapper 命中）：直接用其 convId。
  // 主 session（== mainSessionId,未登记）：调 ensureConversation 建 agent_session 群。
  // 非主 session（子 agent / Task 临时 session）：丢弃，返回 null。
  async getOrCreateState(sessionID: string): Promise<SessionState | null> {
    const existing = this.sessions.get(sessionID)
    if (existing) return existing

    // 子 session 命中 childSessionTree(Task 7 在 task/running 时 .set 进来)。
    // 命中即返回子 session 自己的 state,不再走"非主 session 丢弃"兜底。
    // 首个事件到达时 PATCH 父 task 卡片切 working(每个 child 仅一次);PATCH 失败不丢弃事件。
    const child = this.childSessionTree.get(sessionID)
    if (child) {
      child.state.isChildSession = true
      child.state.childEntry = child
      if (!child.hasFirstEvent) {
        child.hasFirstEvent = true
        try {
          if (child.aggregateElementId && child.aggregateParentState) {
            // 聚合模式:task 卡是聚合卡内元素,working 更新经 updateElement 合并进元素 data
            // (保留 input/sub_session_id,不丢字段),不再 updateMessageContent 独立卡。
            // 分卡旧卡元素 SDK 整体替换:以注册时记账的全量 data 为底再覆盖终态字段。
            await getAggregateCard(child.aggregateParentState, this.wanling).updateElement(
              child.aggregateElementId,
              { ...(child.aggregateElementData ?? {}), status: "working" },
            )
          } else {
            await this.wanling.updateMessageContent(child.parentMsgId, {
              msg_type: "tool_card",
              data: {
                name: "task",
                input: child.taskInput || {},
                status: "working",
                ...(child.childSessionId ? { sub_session_id: child.childSessionId } : {}),
              },
            })
          }
        } catch (err) {
          console.error(`[streamer] 子 session working PATCH 失败: ${err instanceof Error ? err.message : err}`)
        }
      }
      return child.state
    }

    // 并发去重：同一 sessionID 的并发调用共享同一个 Promise，
    // 避免 ensureConversation 期间第二批事件创建重复 SessionState
    // （后者覆盖前者，丢失 buffered reasoning/text + toolPartsSent 重置）。
    const inflight = this.createStateInflight.get(sessionID)
    if (inflight) return inflight

    const promise = (async (): Promise<SessionState | null> => {
      const map = findBySessionId(sessionID)
      if (map) {
        const state: SessionState = { reasoning: null, text: null, convId: map.wanlingConvId, toolPartsSent: new Set(), textPartsFlushed: new Set(), toolCardMsgIds: new Map(), toolCardInflight: new Map(), isMainSession: sessionID === this.mainSessionId }
        this.sessions.set(sessionID, state)
        return state
      }

      // 非主 session(子 agent / Task 临时 session):丢弃,不兜底进 dm
      if (sessionID !== this.mainSessionId) {
        console.warn(`[streamer] 非主 session 事件丢弃: ${sessionID}`)
        return null
      }

      // 主 session:建群(ensureConversation in-flight 防并发)
      const convId = await ensureConversation(sessionID, this.ensureDeps)
      const state: SessionState = { reasoning: null, text: null, convId, toolPartsSent: new Set(), textPartsFlushed: new Set(), toolCardMsgIds: new Map(), toolCardInflight: new Map(), isMainSession: true }
      this.sessions.set(sessionID, state)
      return state
    })()

    this.createStateInflight.set(sessionID, promise)
    try {
      return await promise
    } finally {
      this.createStateInflight.delete(sessionID)
    }
  }

  peekConvId(sessionID: string): string | undefined {
    return this.sessions.get(sessionID)?.convId ?? findBySessionId(sessionID)?.wanlingConvId
  }

  // 暴露当前 mainSessionId(MetaSync 的 onSessionUpdated 标题同步守卫需要判定
  // 「非主 session」;store 已通过 updateMainSessionId 与 Streamer 同步此值)。
  peekMainSessionId(): string {
    return this.mainSessionId
  }

  peekState(sessionID: string): SessionState | undefined {
    return this.sessions.get(sessionID)
  }

  indexPart(partId: string, state: SessionState): void {
    this.partIndex.set(partId, state)
  }

  getPart(partId: string): SessionState | undefined {
    return this.partIndex.get(partId)
  }

  dropPart(partId: string): void {
    this.partIndex.delete(partId)
  }

  getChild(childSessionId: string): ChildSessionEntry | undefined {
    return this.childSessionTree.get(childSessionId)
  }

  // 清理 childSessionTree 条目:撤销兜底超时 timer 后删除条目。
  // 正常路径(task/completed|error)调用;漏发终态时由 _flushPendingToolCard 注册的超时兜底。
  cleanupChild(childSessionId: string | undefined): void {
    if (!childSessionId) return
    const entry = this.childSessionTree.get(childSessionId)
    if (entry?.cleanupTimer) {
      clearTimeout(entry.cleanupTimer)
    }
    this.childSessionTree.delete(childSessionId)
  }

  // registerChild 在 task 卡片 sendCardMessage 成功(resolve 拿到 msgId)后调用,
  // 把子 session 注册到 childSessionTree,后续子 session 事件才能命中 getOrCreateState。
  //
  // I-A:抽出此方法供 _flushPendingToolCard 和 _resolveToolCardMsgId 分支 3 复用,
  // 解决 task/completed 抢占 setImmediate 时分支 3 不注册 childSessionTree 的数据丢失。
  //
  // I-L:嵌套子 agent(子 session 内部再起 task)时,新 entry 的 rootMsgId/depth
  // 必须从父 childEntry 继承,而非永远写「rootMsgId=本次 msgId, depth=1」,
  // 否则二层 task 的 rootMsgId 无法串到最顶层,消息树断裂。
  //
  // I-N:超时回调 PATCH 父 task 卡片为 error(不再只删 map),避免 task 崩溃后
  // 父卡片永远停在 working/starting 让用户以为还在跑。
  //
  // I-O:超时阈值由构造注入(默认 30min),可经 WANLING_CHILD_TIMEOUT_MS env 调整。
  registerChild(
    parentState: SessionState,
    taskCardMsgId: string,
    childSessionId: string,
    parentSessionId: string | undefined,
    taskInput: Record<string, unknown>,
    aggregateOpts?: { elementId: string; data?: Record<string, unknown> },
  ): ChildSessionEntry {
    // 嵌套继承:若父 state 本身是 child(即 isChildSession=true),说明本次 task 是
    // 二层子 agent,rootMsgId 必须取父 childEntry 的 rootMsgId(指向最顶层),
    // depth = 父 depth + 1。否则是普通一层子 agent,root == 本次 parent。
    const parentEntry = parentState.isChildSession ? parentState.childEntry : undefined
    const rootMsgId = parentEntry?.rootMsgId ?? taskCardMsgId
    const depth = (parentEntry?.depth ?? 0) + 1

    const childState: SessionState = {
      reasoning: null,
      text: null,
      convId: parentState.convId,
      toolPartsSent: new Set(),
      textPartsFlushed: new Set(),
      toolCardMsgIds: new Map(),
      toolCardInflight: new Map(),
      isChildSession: true,
    }
    const entry: ChildSessionEntry = {
      parentMsgId: taskCardMsgId,
      rootMsgId,
      depth,
      state: childState,
      parentSessionId: parentSessionId ?? "",
      hasFirstEvent: false,
      taskInput,
      childSessionId,
    }
    // 聚合模式:task 卡是聚合卡内元素,记录 element_id + 父 state,
    // working PATCH / 超时兜底 PATCH 经 updateElement 更新聚合元素。
    if (aggregateOpts) {
      entry.aggregateElementId = aggregateOpts.elementId
      entry.aggregateElementData = aggregateOpts.data
      entry.aggregateParentState = parentState
    }
    childState.childEntry = entry
    // wide-review M-2:同 childSessionId key 覆盖旧 entry 时先 clearTimeout 旧 timer,
    // 避免理论边界(同 session 复用)下旧 timer 悬挂泄漏。
    const oldEntry = this.childSessionTree.get(childSessionId)
    if (oldEntry?.cleanupTimer) clearTimeout(oldEntry.cleanupTimer)
    this.childSessionTree.set(childSessionId, entry)
    logger.info(`[streamer] childSessionTree 注册: child=${childSessionId.slice(0, 12)} parentMsg=${taskCardMsgId.slice(0, 8)} depth=${depth}`)
    // 兜底超时:task 崩溃或漏发 completed/error SSE 时,30min 后强制清理避免泄漏。
    // 正常路径(task/completed|error)在 _handleTaskTool 调 cleanupChildSession 前 clearTimeout。
    // 超时时不仅删 map,还要 PATCH 父卡片为 error,避免父卡片永远转圈(I-N)。
    entry.cleanupTimer = setTimeout(() => {
      console.warn(`[streamer] 子 session 超时未完成,清理 + PATCH 父卡片为 error: ${childSessionId.slice(0, 12)}`)
      this.childSessionTree.delete(childSessionId)
      if (entry.aggregateElementId && entry.aggregateParentState) {
        // 聚合模式:更新聚合卡内 task 元素为 error(updateElement 合并保留 input/sub_session_id)。
        // 分卡旧卡元素 SDK 整体替换:以注册时记账的全量 data 为底再覆盖终态字段。
        getAggregateCard(entry.aggregateParentState, this.wanling).updateElement(
          entry.aggregateElementId,
          { ...(entry.aggregateElementData ?? {}), output: "子 Agent 超时未完成(>30min)", status: "error" },
        ).catch((patchErr) => {
          console.error(`[streamer] 超时更新聚合卡 task 元素失败: ${patchErr instanceof Error ? patchErr.message : patchErr}`)
        })
      } else {
        this.wanling.updateMessageContent(taskCardMsgId, {
          msg_type: "tool_card",
          data: {
            name: "task",
            input: taskInput,
            output: "子 Agent 超时未完成(>30min)",
            status: "error",
            ...(childSessionId ? { sub_session_id: childSessionId } : {}),
          },
        }).catch((patchErr) => {
          // PATCH 失败不再阻塞,日志即可,卡片可能已被 completed/error PATCH 过
          console.error(`[streamer] 超时 PATCH 父卡片失败: ${patchErr instanceof Error ? patchErr.message : patchErr}`)
        })
      }
    }, this.childTimeoutMs)
    return entry
  }

  // idle 去重入口:onSessionIdle 调用,5s 窗口内同 session 只允许一次。
  // 返回 true 表示首次允许处理,false 表示窗口内重复(调用方应早退)。
  markIdleIfFirst(sessionID: string): boolean {
    const now = Date.now()
    const last = this.idleHandled.get(sessionID)
    if (last && now - last < 5000) return false
    this.idleHandled.set(sessionID, now)
    return true
  }

  // 由 Streamer.updateMainSessionId 委托调用,同步本仓库的 mainSessionId 拷贝
  // (getOrCreateState 的主/非主判定依赖此值)。日志和 if 守卫留在 Streamer 端统一处理。
  updateMainSessionId(id: string): void {
    this.mainSessionId = id
  }

  // flush 缓冲 reasoning/text(public 暴露:onSessionIdle 仍在 Streamer,需直接调用;
  // 待 Task 8 把 onSessionIdle 整体迁入 store 后可降级为 private)。
  flushReasoning(state: SessionState): void {
    if (!state.reasoning?.text.trim()) return
    this.router.send(state, "reasoning", { text: state.reasoning.text }, true)
    state.reasoning = null
  }

  flushText(state: SessionState): void {
    // 兜底:缓存的最终 text 终态(未等来 step-finish)→ 以 silent=true 发掉,避免滞留。
    if (state.pendingText) {
      const pt = state.pendingText
      state.pendingText = undefined
      this.router.send(state, "markdown",
        pt.streamId ? { text: pt.text, _stream_id: pt.streamId } : { text: pt.text }, true)
    }
    if (!state.text?.text.trim()) return
    // I-P:子 agent 文本输出强制 silent=true(与 case "text" 同步口径)。
    this.router.send(state, "markdown", { text: state.text.text }, true)
    state.text = null
  }

  // flush 所有未完成 reasoning/text(经 router) + 撤销所有 child session 兜底 timer + 清空 maps。
  // 由 Streamer.stop 调用,Streamer 仍负责心跳停止 + 清理仍在 Streamer 的字段。
  stop(): void {
    // flush 所有未完成 reasoning/text(原 flushSessionIfIdle("") 的「flush all」语义,
    // 该方法已被 onSessionStatus 取代,这里内联保留 stop 的兜底 flush)。
    for (const state of this.sessions.values()) {
      this.flushReasoning(state)
      this.flushText(state)
    }
    this.sessions.clear()
    // 撤销所有 child session 的兜底超时 timer,避免 stop 后回调触发操作已清空的 map
    for (const entry of this.childSessionTree.values()) {
      if (entry.cleanupTimer) clearTimeout(entry.cleanupTimer)
    }
    this.childSessionTree.clear()
    this.partIndex.clear()
    this.idleHandled.clear()
  }
}
