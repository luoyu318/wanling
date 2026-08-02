import type { EventEmitter } from "events"
import type { WanlingClient } from "../../wanling/client.js"
import type { PartUpdatedPayload } from "../../opencode/subscriber.js"
import type { SessionState } from "../types.js"
import type { SessionStore } from "../session_store.js"
import type { MessageRouter } from "../messaging.js"
import { buildDiff } from "../utils/diff.js"
import { extractDuration, extractTaskMetadata } from "../utils/task_meta.js"

// ToolCardManager:tool/task 卡片状态机领域模块。
// 职责:普通 tool 卡片 + task 工具卡片的状态机(running/completed/error),
// 含 inflight Promise(running 卡片在 sendCardMessage 往返期间的竞态修复) +
// childSessionTree 注册经 store 委托。
// 不持有状态(toolPartsSent / toolCardMsgIds / toolCardInflight / pendingToolCard
// 都在 SessionState 上,随 state 参数流动)。错误经注入的 emitter 上抛
// (Streamer extends EventEmitter,传 this 作 emitter)。
export class ToolCardManager {
  private readonly store: SessionStore
  private readonly router: MessageRouter
  private readonly wanling: WanlingClient
  private readonly emitter: EventEmitter

  constructor(deps: {
    store: SessionStore
    router: MessageRouter
    wanling: WanlingClient
    emitter: EventEmitter
  }) {
    this.store = deps.store
    this.router = deps.router
    this.wanling = deps.wanling
    this.emitter = deps.emitter
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
      const msgId = await this.resolveMsgId(state, part)
      if (!msgId) {
        console.warn(`[streamer] tool_card msgId 缺失,跳过 PATCH: session=${sessionID.slice(0, 12)} part=${part.id}`)
      } else {
        console.log(`[TC-DBG] completed PATCH msgId=${msgId} part=${part.id} tool=${toolName}`)
        let fileDiffData: Record<string, unknown> | undefined
        if ((toolName === "edit" || toolName === "write") && input) {
          const filePath = (input as Record<string, unknown>).filePath as string || ""
          if (filePath) {
            const basename = filePath.split(/[/\\]/).pop() || filePath
            const diffText = buildDiff(toolName, input as Record<string, unknown>, output || "")
            if (diffText) {
              fileDiffData = {
                file: basename,
                additions: (diffText.match(/^\+[^+]/gm) || []).length,
                deletions: (diffText.match(/^-[^-]/gm) || []).length,
                diff: diffText,
              }
            }
          }
        }

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
      setImmediate(() => this.flushPending(state, childSessionId, sessionID))

    } else if (status === "completed") {
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
}
