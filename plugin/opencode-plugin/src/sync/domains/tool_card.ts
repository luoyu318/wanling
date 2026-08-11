import type { EventEmitter } from "events"
import type { WanlingClient } from "../../wanling/client.js"
import type { PartUpdatedPayload } from "../../opencode/subscriber.js"
import type { SessionState } from "../types.js"
import type { SessionStore } from "../session_store.js"
import type { MessageRouter } from "../messaging.js"
import { buildDiff } from "../utils/diff.js"
import { extractDuration, extractTaskMetadata } from "../utils/task_meta.js"
import { AggregateCardManager, type ToolCardData } from "./aggregate_card.js"

// 聚合卡 msgId 占位符:聚合模式 task running 同步注册 childSessionTree 时,
// 聚合卡可能尚未建卡(首次工具即 task),ensureCard 的建卡 REST 往返未完成,
// 先用占位 id 作为 parentMsgId/rootMsgId 注册,append PATCH 完成后补真实聚合卡
// msgId(见 flushAggregateTool)。占位期间子 session 只入 state 缓冲,消息发送
// 用真实 id 时已补全,不会用占位 id 实际发消息。
export const AGGREGATE_MSG_PENDING = "pending-aggregate-card"

// ToolCardManager:tool/task 卡片状态机领域模块。
// 职责:普通 tool 卡片 + task 工具卡片的状态机(running/completed/error),
// 含 inflight Promise(running 卡片在 sendCardMessage 往返期间的竞态修复) +
// childSessionTree 注册经 store 委托。
// 聚合卡改造(Task 4):AGGREGATE_CARD_ENABLED=true(默认)时,主 session 普通 tool 不再发
// 独立 tool_card 消息,而是追加到聚合卡元素(Task 2 AggregateCardManager):
//   running   → 追加 tool_card 元素(status:running),partId→element_id 映射存
//               state.aggregateToolElementIds(同步写入,append 前),completed/error 据此定位。
//   completed → 全量替换聚合卡元素,更新目标元素 status:completed + output + file_diff。
//   error     → 更新目标元素 status:error + error 字段。
// task 工具聚合模式:主 session 的 task 卡同样追加为聚合卡内 tool_card 元素
// (status:starting + sub_session_id,APP 点击跳子 agent 详情页),completed/error 更新该元素。
// childSessionTree 的 parentMsgId 聚合模式下取聚合卡 msgId(子 session 消息仍走独立子流,
// 经 parent/root 串到聚合卡下);working/超时 PATCH 聚合模式下经 updateElement 更新元素。
// 子 session 恒不聚合(useAggregate 判定),其内部 task 仍走独立卡。
// 开关 false 时完全回退旧逻辑(sendCard 独立卡 + updateMessageContent PATCH)。
// 聚合序号(nextSeq)/累计(aggregateElements)/patch 串行队列(aggregatePatchQueue)
// 都在 SessionState 上维护,与 PartDispatcher 共用同一计数器与队列,element_id 全卡唯一、
// 全量替换并发不覆盖。
// 不持有状态(toolPartsSent / toolCardMsgIds / toolCardInflight / pendingToolCard
// 都在 SessionState 上,随 state 参数流动)。错误经注入的 emitter 上抛
// (Streamer extends EventEmitter,传 this 作 emitter)。
export class ToolCardManager {
  private readonly store: SessionStore
  private readonly router: MessageRouter
  private readonly wanling: WanlingClient
  private readonly emitter: EventEmitter
  // 聚合卡开关:false 回退旧逐条发送(独立 tool_card + PATCH)。默认 true。
  private readonly aggregateCardEnabled: boolean

  constructor(deps: {
    store: SessionStore
    router: MessageRouter
    wanling: WanlingClient
    emitter: EventEmitter
    aggregateCardEnabled?: boolean
  }) {
    this.store = deps.store
    this.router = deps.router
    this.wanling = deps.wanling
    this.emitter = deps.emitter
    this.aggregateCardEnabled = deps.aggregateCardEnabled ?? true
  }

  // case "tool" 方法体(从 Streamer.onPartUpdated 逐字迁入)。
  async onPartUpdated(
    part: PartUpdatedPayload["part"],
    state: SessionState,
    sessionID: string,
  ): Promise<void> {
    const status = (part.state?.status as string) || ""
    const input = part.state?.input as Record<string, unknown> | undefined
    const output = part.state?.output as string | undefined
    const error = part.state?.error as string | undefined
    const toolName = part.tool || ""
    const metadata = extractTaskMetadata(part.state)
    console.log(`[TC-DBG] onPartUpdated tool=${toolName} status=${status} part=${part.id} session=${sessionID.slice(0, 12)}`)

    // question 工具由 question_card 处理（SSE question.asked → onQuestionAsked），
    // 不再发 tool_call 消息，避免 APP 同时出现两张卡片。
    if (toolName === "question") return

    // task 工具特判：解析 metadata.sessionId 建 childSessionTree + 3 状态机
    // （starting → working → completed/error）。必须在通用 tool 处理之前命中,
    // 否则 task 会被当成普通 tool 走 running 状态,丢失子 session 关联。
    if (toolName === "task") {
      await this.handleTaskTool(state, part, sessionID, metadata, status, input, output)
      return
    }

    const toolKey = `${part.id}:${status}`
    if (state.toolPartsSent.has(toolKey)) return
    state.toolPartsSent.add(toolKey)

    if (status === "running") {
      state.pendingToolCard = { toolName: toolName, input: input || {}, partId: part.id }
      // 普通工具无 child session 关联,清空避免残留上一次 task 的字段
      state.pendingChildSessionId = undefined
      state.pendingParentSessionId = undefined
      console.log(`[TC-DBG] running → pendingToolCard 已存,排 setImmediate part=${part.id}`)
      setImmediate(() => this.flushPending(state))

    } else if (status === "completed") {
      // 聚合模式:聚合卡内定位目标工具元素并全量替换更新(status/completed + output + file_diff),
      // 不再 resolveMsgId(无独立卡 msgId,聚合卡 msgId 由 updateElement 内部 ensureCard 拿)。
      if (this.useAggregate(state)) {
        const fileDiffData = this.buildFileDiff(toolName, input, output)
        const patchData: Record<string, unknown> = {
          name: toolName,
          input: input || {},
          output: output || "",
          status: "completed",
        }
        if (fileDiffData) {
          patchData.file_diff = fileDiffData
        }
        await this.updateToolElement(state, part, patchData)
        return
      }

      const msgId = await this.resolveMsgId(state, part)
      if (!msgId) {
        console.warn(`[streamer] tool_card msgId 缺失,跳过 PATCH: session=${sessionID.slice(0, 12)} part=${part.id}`)
      } else {
        console.log(`[TC-DBG] completed PATCH msgId=${msgId} part=${part.id} tool=${toolName}`)
        const fileDiffData = this.buildFileDiff(toolName, input, output)
        const patchData: Record<string, unknown> = {
          name: toolName,
          input: input || {},
          output: output || "",
          status: "completed",
        }
        if (fileDiffData) {
          patchData.file_diff = fileDiffData
        }
        await this.wanling.updateMessageContent(msgId, {
          msg_type: "tool_card",
          data: patchData,
        })
      }

    } else if (status === "error") {
      // 聚合模式:定位目标工具元素更新 status:error + error 字段。
      if (this.useAggregate(state)) {
        await this.updateToolElement(state, part, {
          name: toolName,
          input: input || {},
          error: error || "",
          status: "error",
        })
        return
      }
      const msgId = await this.resolveMsgId(state, part)
      if (!msgId) {
        console.warn(`[streamer] tool_card msgId 缺失,跳过 PATCH: session=${sessionID.slice(0, 12)} part=${part.id}`)
      } else {
        await this.wanling.updateMessageContent(msgId, {
          msg_type: "tool_card",
          data: {
            name: toolName,
            input: input || {},
            error: error || "",
            status: "error",
          },
        })
      }
    }
  }

  async resolveMsgId(
    state: SessionState,
    part: PartUpdatedPayload["part"],
    taskChildSessionId?: string,
    taskParentSessionId?: string,
  ): Promise<string | undefined> {
    // 1. msgId 已就位
    const existing = state.toolCardMsgIds.get(part.id)
    if (existing) {
      console.log(`[TC-DBG] resolveMsgId 分支1(已就位) part=${part.id} msgId=${existing}`)
      return existing
    }

    // 2. sendCardMessage(running) 在飞行中 → await 它(捕获竞态窗口)
    const inflight = state.toolCardInflight.get(part.id)
    if (inflight) {
      console.log(`[TC-DBG] resolveMsgId 分支2(await inflight) part=${part.id}`)
      try {
        const mid = await inflight
        console.log(`[TC-DBG] resolveMsgId 分支2 resolved part=${part.id} msgId=${mid}`)
        return mid
      } catch {
        // sendCardMessage 失败,落到下面的兜底分支(若 pending 已被消费则返回 undefined)
      }
    }

    // 3. pending 还在(running 后 setImmediate 未跑或被事件抢到前)→ 同步发起。
    //    I-A:task/completed 抢占 setImmediate 时走此分支,必须同步发起 sendCardMessage
    //    并注册 childSessionTree(否则子 session 后续事件全部丢失)。
    //    普通工具无 childSessionId,只发卡片不注册。
    if (state.pendingToolCard && state.pendingToolCard.partId === part.id) {
      console.log(`[TC-DBG] resolveMsgId 分支3(pending同步发) part=${part.id} — completed 抢占了 setImmediate`)
      const pending = state.pendingToolCard
      state.pendingToolCard = undefined
      // task 工具同步发起用 starting 状态(对齐 flushPending),普通工具用 running。
      const msgId = await this.router.sendCard(state, "tool_card", {
        name: pending.toolName,
        input: pending.input,
        status: pending.toolName === "task" ? "starting" : "running",
        ...(pending.toolName === "task" && taskChildSessionId ? { sub_session_id: taskChildSessionId } : {}),
      })
      state.toolCardMsgIds.set(part.id, msgId)
      // task 工具:同步注册 childSessionTree,等价 flushPending 的 .then 分支。
      if (pending.toolName === "task" && taskChildSessionId) {
        this.store.registerChild(state, msgId, taskChildSessionId, taskParentSessionId, pending.input)
      }
      return msgId
    }

    return undefined
  }

  // task 工具特判处理:3 状态机 + 子 session 关联映射。
  //   running    → 建 task 卡片(status=starting),sendCardMessage resolve 后注册 childSessionTree
  //   completed  → PATCH completed + 清理 childSessionTree(子 session 不再产生事件)
  //   error      → PATCH error + 清理 childSessionTree
  // working 状态由 Task 6 的 getOrCreateState 在子 session 首事件时 PATCH,这里不重复。
  private async handleTaskTool(
    state: SessionState,
    part: PartUpdatedPayload["part"],
    sessionID: string,
    metadata: { sessionId?: string; parentSessionId?: string } | undefined,
    status: string,
    input: Record<string, unknown> | undefined,
    output: string | undefined,
  ): Promise<void> {
    const childSessionId = metadata?.sessionId
    const toolKey = `${part.id}:${status}`
    if (state.toolPartsSent.has(toolKey)) return
    state.toolPartsSent.add(toolKey)

    if (status === "running") {
      // 1) 建 task 卡片(starting)— 复用 pendingToolCard + setImmediate 机制。
      //    childSessionId/parentSessionId 存入 state(wide-review I-1),
      //    让所有 flush 路径(含审批/提问抢占)一致读取,不再仅靠参数传递。
      state.pendingToolCard = { toolName: "task", input: input || {}, partId: part.id }
      state.pendingChildSessionId = childSessionId
      state.pendingParentSessionId = sessionID
      // 2) 提前注册 childSessionTree(task running 同步段,setImmediate 之前):
      //    子 agent 被 task 工具拉起后 SSE 事件立即涌入,若等 append PATCH 完成
      //    再注册(旧实现 flushAggregateTool 的 .then),子 session 首事件会在
      //    注册前到达,getOrCreateState 命中「非主 session 丢弃」→ 思考/工具/
      //    结果全部丢失。此处同步注册(聚合卡 msgId 未就绪用占位 id,append 后补全),
      //    消除竞态窗口。
      if (childSessionId) {
        this.registerTaskChildEarly(state, part.id, childSessionId, sessionID, input || {})
      }
      setImmediate(() => this.flushPending(state, childSessionId, sessionID))

    } else if (status === "completed") {
      // 聚合模式:更新聚合卡内 task 元素(status:completed + output + duration + sub_session_id),
      // 非聚合走下方独立 task 卡 updateMessageContent。
      if (this.useAggregate(state)) {
        let patched = false
        try {
          const duration = extractDuration(part)
          const patchData: Record<string, unknown> = {
            name: "task",
            input: input || {},
            output: output || "",
            status: "completed",
          }
          if (childSessionId) patchData.sub_session_id = childSessionId
          if (duration !== null) patchData.duration = duration
          await this.updateToolElement(state, part, patchData)
          patched = true
        } catch (err) {
          console.error(`[streamer] task completed 聚合更新失败: ${err instanceof Error ? err.message : err}`)
        }
        if (patched) this.store.cleanupChild(childSessionId)
        return
      }
      // 终态 PATCH 失败时保留 childSessionTree + 兜底 timer,让 30min 兜底兜住
      // (旧实现 finally 无条件 cleanup,反而拆掉自己的兜底 → 卡片永卡 working)
      let patched = false
      try {
        // 传 childSessionId/parentSessionId 给 resolveMsgId,
        // 让分支 3(task/completed 抢占 setImmediate)能同步注册 childSessionTree。
        const msgId = await this.resolveMsgId(state, part, childSessionId, sessionID)
        if (!msgId) {
          console.warn(`[streamer] task tool_card msgId 缺失,跳过 PATCH: session=${sessionID.slice(0, 12)} part=${part.id}`)
        } else {
          const duration = extractDuration(part)
          await this.wanling.updateMessageContent(msgId, {
            msg_type: "tool_card",
            data: {
              name: "task",
              input: input || {},
              output: output || "",
              status: "completed",
              ...(childSessionId ? { sub_session_id: childSessionId } : {}),
              ...(duration !== null ? { duration } : {}),
            },
          })
          patched = true
        }
      } catch (err) {
        console.error(`[streamer] task completed PATCH 失败: ${err instanceof Error ? err.message : err}`)
      }
      // 仅 PATCH 成功才 cleanup(撤销兜底 timer + 删 tree);失败让兜底 timer 兜住
      if (patched) this.store.cleanupChild(childSessionId)

    } else if (status === "error") {
      // 聚合模式:更新聚合卡内 task 元素(status:error + error 字段)。
      if (this.useAggregate(state)) {
        let patched = false
        try {
          const patchData: Record<string, unknown> = {
            name: "task",
            input: input || {},
            error: (part.state?.error as string) || "",
            status: "error",
          }
          if (childSessionId) patchData.sub_session_id = childSessionId
          await this.updateToolElement(state, part, patchData)
          patched = true
        } catch (err) {
          console.error(`[streamer] task error 聚合更新失败: ${err instanceof Error ? err.message : err}`)
        }
        if (patched) this.store.cleanupChild(childSessionId)
        return
      }
      let patched = false
      try {
        const msgId = await this.resolveMsgId(state, part, childSessionId, sessionID)
        if (!msgId) {
          console.warn(`[streamer] task tool_card msgId 缺失,跳过 PATCH: session=${sessionID.slice(0, 12)} part=${part.id}`)
        } else {
          await this.wanling.updateMessageContent(msgId, {
            msg_type: "tool_card",
            data: {
              name: "task",
              input: input || {},
              error: (part.state?.error as string) || "",
              status: "error",
              ...(childSessionId ? { sub_session_id: childSessionId } : {}),
            },
          })
          patched = true
        }
      } catch (err) {
        console.error(`[streamer] task error PATCH 失败: ${err instanceof Error ? err.message : err}`)
      }
      if (patched) this.store.cleanupChild(childSessionId)
    }
  }

  // 聚合模式 task running 的提前注册:在 handleTaskTool 同步段注册 childSessionTree,
  // 不等 append PATCH 完成(消除子 session 首事件被 getOrCreateState 丢弃的竞态窗口)。
  // 预分配聚合元素号并暂存到 pendingToolCard.aggregateSeq,flushAggregateTool 复用同一
  // element_id(不重复取号,entry 的 aggregateElementId 与真正 append 的元素一致)。
  // 注意:不能提前写 state.aggregateToolElementIds(completed 抢占 setImmediate 时
  // updateToolElement 的 preempt 判定依赖该映射未建立,过早写入会破坏同步补发逻辑)。
  // 聚合卡 msgId 未就绪(首次工具即 task)时用占位 id,append 完成(ensureCard resolve)
  // 后由 flushAggregateTool 补真实聚合卡 msgId 到 parentMsgId/rootMsgId。
  private registerTaskChildEarly(
    state: SessionState,
    partId: string,
    childSessionId: string,
    parentSessionId: string,
    taskInput: Record<string, unknown>,
  ): void {
    if (!this.useAggregate(state)) return
    const seq = this.nextSeq(state)
    if (state.pendingToolCard) {
      state.pendingToolCard.aggregateSeq = seq
    }
    this.store.registerChild(
      state,
      state.aggregateCardMsgId ?? AGGREGATE_MSG_PENDING,
      childSessionId,
      parentSessionId,
      taskInput,
      { elementId: `tool_card_${seq}` },
    )
  }

  flushPending(state: SessionState, childSessionId?: string, parentSessionId?: string): void {
    const pending = state.pendingToolCard
    if (!pending) {
      console.log(`[TC-DBG] flushPending 无 pending(已被消费)`)
      return
    }
    state.pendingToolCard = undefined
    console.log(`[TC-DBG] flushPending 发 running 卡 tool=${pending.toolName} part=${pending.partId}`)
    // wide-review I-1:childSessionId 优先用参数(setImmediate 路径传),
    // fallback 到 state.pending*(审批/提问抢占路径无参,从 pending 对象读)。
    const effectiveChild = childSessionId ?? state.pendingChildSessionId
    const effectiveParent = parentSessionId ?? state.pendingParentSessionId
    state.pendingChildSessionId = undefined
    state.pendingParentSessionId = undefined

    // 聚合模式:把工具(tool + task)追加为聚合卡元素,不再发独立 tool_card。
    // 子 session 恒不聚合(useAggregate 判定)。
    if (this.useAggregate(state)) {
      this.flushAggregateTool(state, pending, effectiveChild, effectiveParent)
      return
    }

    // task 工具卡片初始 status 用 starting(后续由子 session 首事件 PATCH 切 working,
    // task/completed PATCH 切 completed);普通工具仍是 running。
    const cardData: Record<string, unknown> = {
      name: pending.toolName,
      input: pending.input,
      status: pending.toolName === "task" ? "starting" : "running",
    }
    if (pending.toolName === "task" && effectiveChild) {
      cardData.sub_session_id = effectiveChild
    }

    // 关键修复:发起 sendCardMessage 前先把 promise 入 inflight map,
    // 这样 completed/error 事件在 WS 往返期间能 await 到 msgId。
    // 子 session 的 tool_card 透传 parent/root,让 server 把卡片串到父 task 下。
    const promise = this.router.sendCard(state, "tool_card", cardData)
    state.toolCardInflight.set(pending.partId, promise)

    promise.then((msgId) => {
      state.toolCardMsgIds.set(pending.partId, msgId)
      state.toolCardInflight.delete(pending.partId)

      // task 工具:sendCardMessage 成功后注册 childSessionTree,
      // 后续子 session 事件才能命中 getOrCreateState 走透传路径(不再被丢弃)。
      if (pending.toolName === "task" && effectiveChild) {
        this.store.registerChild(state, msgId, effectiveChild, effectiveParent, pending.input)
      }
    }).catch((err) => {
      // I-M:延迟 tool_card 发送失败不能静默吞,emit('error') 让上层感知
      // (与 onPermissionAsked 的 catch 一致口径),否则子 session 输出全部丢失
      // 而生产环境只看到一行不可见日志,违反 fail-fast。
      console.error(`[streamer] 延迟 tool_card 发送失败: ${err instanceof Error ? err.message : err}`)
      state.toolCardInflight.delete(pending.partId)
      this.emitter.emit("error", err instanceof Error ? err : new Error(String(err)))
    })
  }

  // 聚合模式工具 running 追加:取号 → 同步写入 partId→element_id 映射(completed/error 据此
  // 定位)→ 追加 tool_card 元素并 PATCH。task 工具追加 status:starting + sub_session_id,
  // append 成功后(聚合卡 msgId 就绪)注册 childSessionTree(等价独立卡 sendCard 的 .then)。
  // append 失败 emit error(与独立卡发送失败一致口径,不静默吞)。
  private flushAggregateTool(
    state: SessionState,
    pending: { toolName: string; input: Record<string, unknown>; partId: string; aggregateSeq?: number },
    childSessionId?: string,
    parentSessionId?: string,
  ): void {
    // 复用 handleTaskTool 提前注册时预分配的元素号(task running 已取号,
    // 保证 entry.aggregateElementId 与真正 append 的元素一致);普通工具现场取号。
    const seq = pending.aggregateSeq ?? this.nextSeq(state)
    const elementId = `tool_card_${seq}`
    if (!state.aggregateToolElementIds) state.aggregateToolElementIds = new Map()
    state.aggregateToolElementIds.set(pending.partId, elementId)
    // 审批/提问抢占路径(updateToolElement preempt 直接调本方法)无参,
    // fallback 到 state.pending*(flushPending 路径已清空,由参数携带)。
    const effectiveChild = childSessionId ?? state.pendingChildSessionId
    const effectiveParent = parentSessionId ?? state.pendingParentSessionId
    const isTask = pending.toolName === "task"
    const data: ToolCardData = {
      name: pending.toolName,
      input: pending.input,
      status: isTask ? "starting" : "running",
    }
    if (isTask && effectiveChild) {
      data.sub_session_id = effectiveChild
    }
    console.log(`[TC-DBG] flushPending 聚合追加 tool_card_${seq} tool=${pending.toolName} part=${pending.partId}`)
    void this.appendToolElement(state, data, seq)
      .then(() => {
        // task 子 session:entry 已在 handleTaskTool running 同步注册(提前注册),
        // append 完成拿到真实聚合卡 msgId 后,把占位 parentMsgId/rootMsgId 补成真实 id,
        // 子 session 消息才能正确经 parent/root 串到聚合卡下。
        // entry 缺失时兜底补注册(等价旧实现,理论上不发生)。
        if (isTask && effectiveChild) {
          const msgId = state.aggregateCardMsgId
          if (!msgId) {
            console.error(`[streamer] task 聚合追加后聚合卡 msgId 缺失,childSessionTree 未注册: part=${pending.partId}`)
            return
          }
          const entry = this.store.getChild(effectiveChild)
          if (entry) {
            if (entry.parentMsgId === AGGREGATE_MSG_PENDING) entry.parentMsgId = msgId
            if (entry.rootMsgId === AGGREGATE_MSG_PENDING) entry.rootMsgId = msgId
          } else {
            console.error(`[streamer] task 聚合追加后 childSessionTree 未注册(提前注册缺失),补注册: part=${pending.partId}`)
            this.store.registerChild(state, msgId, effectiveChild, effectiveParent, pending.input, { elementId })
          }
        }
      })
      .catch((err) => {
        console.error(`[streamer] 延迟 tool_card 聚合追加失败: ${err instanceof Error ? err.message : err}`)
        this.emitter.emit("error", err instanceof Error ? err : new Error(String(err)))
      })
  }

  // 追加工具元素并 PATCH 增量 op(append)。队列/累计由 AggregateCardManager.appendElement
  // 统一维护,与 reasoning/markdown/footer 的追加共用同一串行队列,并发全量不再互相覆盖。
  private appendToolElement(
    state: SessionState,
    data: ToolCardData,
    seq: number,
  ): Promise<void> {
    return new AggregateCardManager(this.wanling, state).appendElement(
      AggregateCardManager.toolCard(data, seq),
    )
  }

  // 聚合模式 completed/error:按 partId 定位聚合卡内目标工具元素,增量 update(合并 data)。
  // 串行队列:与 running 的 append 共用 state.aggregatePatchQueue,保证「append 先于 update 执行」,
  // update 读到的 state.aggregateElements 已含目标元素。
  // 竞态修复(等效旧逻辑 resolveMsgId 分支 3):completed/error 抢占 setImmediate(running 的
  // flushPending 尚未执行)时,映射缺失但 pendingToolCard 匹配 → 同步补发 running 元素入队,
  // update 排在其后执行。事后 setImmediate 再跑 flushPending 时 pending 已被消费 → 直接 return,
  // 不会产生重复 running 元素。
  private async updateToolElement(
    state: SessionState,
    part: PartUpdatedPayload["part"],
    patchData: Record<string, unknown>,
  ): Promise<void> {
    if (!state.aggregateToolElementIds?.has(part.id) && state.pendingToolCard?.partId === part.id) {
      const pending = state.pendingToolCard
      state.pendingToolCard = undefined
      this.flushAggregateTool(state, pending)
    }
    const elementId = state.aggregateToolElementIds?.get(part.id)
    if (!elementId) {
      console.warn(`[streamer] 聚合卡工具元素定位缺失,跳过更新: conv=${state.convId.slice(0, 12)} part=${part.id}`)
      return
    }
    await new AggregateCardManager(this.wanling, state).updateElement(elementId, patchData)
  }

  // 聚合卡是否对本 state 生效:开关开启且非子 session。
  // 子 session 的 tool_card 恒走独立消息(保持 parent/root 串树语义,聚合卡上无法表达 child 层级)。
  private useAggregate(state: SessionState): boolean {
    return this.aggregateCardEnabled && !state.isChildSession
  }

  // 聚合卡元素序号计数器:与 PartDispatcher 共用 state.aggregateSeq,
  // reasoning/markdown/footer/tool_card 全卡唯一递增。
  private nextSeq(state: SessionState): number {
    const seq = (state.aggregateSeq ?? 0) + 1
    state.aggregateSeq = seq
    return seq
  }

  // edit/write 工具 completed 的 file_diff 统计:从 input.filePath 取文件名,
  // 对 output 构建 diff 计算新增/删除行。非 edit/write 或无 filePath 返回 undefined。
  private buildFileDiff(
    toolName: string,
    input: Record<string, unknown> | undefined,
    output: string | undefined,
  ): Record<string, unknown> | undefined {
    if ((toolName !== "edit" && toolName !== "write") || !input) return undefined
    const filePath = (input as Record<string, unknown>).filePath as string || ""
    if (!filePath) return undefined
    const basename = filePath.split(/[/\\]/).pop() || filePath
    const diffText = buildDiff(toolName, input as Record<string, unknown>, output || "")
    if (!diffText) return undefined
    return {
      file: basename,
      additions: (diffText.match(/^\+[^+]/gm) || []).length,
      deletions: (diffText.match(/^-[^-]/gm) || []).length,
      diff: diffText,
    }
  }
}
