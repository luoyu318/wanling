import type { EventEmitter } from "events"
import type { WanlingClient } from "../../wanling/client.js"
import type {
  ApprovalRequestPayload,
  QuestionAskedPayload,
  PermissionRepliedPayload,
  QuestionRepliedPayload,
  QuestionRejectedPayload,
} from "../../opencode/subscriber.js"
import type { SessionStore } from "../session_store.js"
import type { SessionState } from "../types.js"
import type { MessageRouter } from "../messaging.js"
import type { ToolCardManager } from "./tool_card.js"
import { AggregateCardManager, type AggregateElement } from "./aggregate_card.js"
import { saveCard, getCard, deleteCard, getAllCards, type CardEntry } from "../card_store.js"

// InteractionCards:permission / question 交互卡片领域模块。
// 职责:交互卡片的正向流(OpenCode 问 → 发 card 到 APP) + 反向流(TUI 答 → PATCH
// 原 card 切终态) + 启动时孤儿卡片清理(plugin 重启后兜底 PATCH 为 expired)。
// 聚合卡嵌入改造(2026-08-06):AGGREGATE_CARD_ENABLED=true(默认)时,主 session 的
// question/permission 不再发独立卡片,而是作为聚合卡内嵌元素(question_card /
// permission_card 元素):
//   正向流  → appendElement 追加 pending 元素 + 整卡翻转 silent=false 响铃
//             (与回合结束翻转区别:此翻转是"需要用户介入"),
//             card_store 存聚合卡 msgId + element_id + sessionId(供反向流定位)。
//   反向流  → 更新聚合卡内对应元素 status(answered/approved/denied/rejected/expired),
//             用户回答后回合继续 → 整卡 silent 恢复 true(不再响铃,回合结束
//             footer 再翻 silent=false 计未读)。
//   清理    → 孤儿交互元素更新聚合卡内元素 expired。
// 开关 false 时完全回退旧逻辑(独立卡)。
// 不持有状态(card_store 是模块级单例,跨实例共享)。错误经注入的 emitter
// (Streamer extends EventEmitter,传 this 作 emitter)上抛。
export class InteractionCards {
  private readonly store: SessionStore
  private readonly router: MessageRouter
  private readonly wanling: WanlingClient
  private readonly toolCard: ToolCardManager
  private readonly emitter: EventEmitter
  // 聚合卡开关:false 回退旧逐条发送(独立 permission/question 卡)。默认 true。
  private readonly aggregateCardEnabled: boolean

  constructor(deps: {
    store: SessionStore
    router: MessageRouter
    wanling: WanlingClient
    toolCard: ToolCardManager
    emitter: EventEmitter
    aggregateCardEnabled?: boolean
  }) {
    this.store = deps.store
    this.router = deps.router
    this.wanling = deps.wanling
    this.toolCard = deps.toolCard
    this.emitter = deps.emitter
    this.aggregateCardEnabled = deps.aggregateCardEnabled ?? true
  }

  // 交互事件 — 正向流（OpenCode 问 → 发 card 到 APP）
  async onPermissionAsked(payload: ApprovalRequestPayload): Promise<void> {
    try {
      const state = await this.store.getOrCreateState(payload.sessionID)
      if (!state) return

      if (this.useAggregate(state)) {
        const element = AggregateCardManager.permissionCard({
          oc_request_id: payload.id,
          action: payload.action,
          resources: payload.resources,
          save: payload.save || [],
          metadata: payload.metadata || {},
          status: "pending",
        }, this.nextSeq(state))
        // pending 交互元素出现 → PATCH 整卡翻转 silent=false 响铃(需要用户介入)
        await this.appendElement(state, element, { silent: false })
        const msgId = await new AggregateCardManager(this.wanling, state).ensureCard()
        await saveCard(payload.id, {
          msgId,
          convId: state.convId,
          type: "permission",
          directory: payload.directory,
          data: { action: payload.action, resources: payload.resources, save: payload.save || [], metadata: payload.metadata || {} },
          elementId: element.element_id,
          sessionId: payload.sessionID,
        })
        this.toolCard.flushPending(state)
        return
      }

      const msgId = await this.router.sendCard(state, "permission_card", {
        oc_request_id: payload.id,
        action: payload.action,
        resources: payload.resources,
        save: payload.save || [],
        metadata: payload.metadata || {},
        status: "pending",
      }, false)

      await saveCard(payload.id, { msgId, convId: state.convId, type: "permission", directory: payload.directory, data: { action: payload.action, resources: payload.resources, save: payload.save || [], metadata: payload.metadata || {} } })

      // permission_card 已创建,现在刷新 pending tool_card（如果有）,确保顺序: 审批卡→工具卡
      this.toolCard.flushPending(state)
    } catch (err) {
      this.emitter.emit("error", err instanceof Error ? err : new Error(String(err)))
    }
  }

  async onQuestionAsked(payload: QuestionAskedPayload): Promise<void> {
    try {
      const state = await this.store.getOrCreateState(payload.sessionID)
      if (!state) return

      if (this.useAggregate(state)) {
        const element = AggregateCardManager.questionCard({
          oc_request_id: payload.id,
          questions: payload.questions,
          status: "pending",
        }, this.nextSeq(state))
        // pending 交互元素出现 → PATCH 整卡翻转 silent=false 响铃(需要用户介入)
        await this.appendElement(state, element, { silent: false })
        const msgId = await new AggregateCardManager(this.wanling, state).ensureCard()
        await saveCard(payload.id, {
          msgId,
          convId: state.convId,
          type: "question",
          directory: payload.directory,
          data: { questions: payload.questions },
          elementId: element.element_id,
          sessionId: payload.sessionID,
        })
        this.toolCard.flushPending(state)
        return
      }

      const msgId = await this.router.sendCard(state, "question_card", {
        oc_request_id: payload.id,
        questions: payload.questions,
        status: "pending",
      }, false)

      await saveCard(payload.id, { msgId, convId: state.convId, type: "question", directory: payload.directory, data: { questions: payload.questions } })

      this.toolCard.flushPending(state)
    } catch (err) {
      this.emitter.emit("error", err instanceof Error ? err : new Error(String(err)))
    }
  }

  // 交互事件 — 反向流（TUI 答 → PATCH 原 card 切终态）
  // 若 getCard 返回 null：正向流 engine 已处理（APP 答 → engine PATCH 后已 deleteCard），跳过
  async onPermissionReplied(payload: PermissionRepliedPayload): Promise<void> {
    try {
      const entry = await getCard(payload.requestID)
      if (!entry) return

      const status = payload.reply === "reject" ? "denied" : "approved"
      // 聚合模式(elementId 已存):更新聚合卡内对应元素 status,不再 PATCH 独立卡
      if (entry.elementId) {
        await this.updateAggregateElement(entry, { oc_request_id: payload.requestID, status, result: payload.reply })
        await deleteCard(payload.requestID)
        return
      }

      await this.wanling.updateMessageContent(entry.msgId, {
        msg_type: "permission_card",
        data: {
          ...(entry.data || {}),
          oc_request_id: payload.requestID,
          status,
          result: payload.reply,
        },
      })
      await deleteCard(payload.requestID)
    } catch (err) {
      this.emitter.emit("error", err instanceof Error ? err : new Error(String(err)))
    }
  }

  async onQuestionReplied(payload: QuestionRepliedPayload): Promise<void> {
    try {
      const entry = await getCard(payload.requestID)
      if (!entry) return

      const result = payload.answers.map((a) => a.join(", ")).join(" / ")
      // 聚合模式(elementId 已存):更新聚合卡内对应元素 status=answered
      if (entry.elementId) {
        await this.updateAggregateElement(entry, { oc_request_id: payload.requestID, status: "answered", result })
        await deleteCard(payload.requestID)
        return
      }

      await this.wanling.updateMessageContent(entry.msgId, {
        msg_type: "question_card",
        data: {
          ...(entry.data || {}),
          oc_request_id: payload.requestID,
          status: "answered",
          result,
        },
      })
      await deleteCard(payload.requestID)
    } catch (err) {
      this.emitter.emit("error", err instanceof Error ? err : new Error(String(err)))
    }
  }

  async onQuestionRejected(payload: QuestionRejectedPayload): Promise<void> {
    try {
      const entry = await getCard(payload.requestID)
      if (!entry) return

      // 聚合模式(elementId 已存):更新聚合卡内对应元素 status=rejected
      if (entry.elementId) {
        await this.updateAggregateElement(entry, { oc_request_id: payload.requestID, status: "rejected", result: "rejected" })
        await deleteCard(payload.requestID)
        return
      }

      await this.wanling.updateMessageContent(entry.msgId, {
        msg_type: "question_card",
        data: {
          ...(entry.data || {}),
          oc_request_id: payload.requestID,
          status: "rejected",
          result: "rejected",
        },
      })
      await deleteCard(payload.requestID)
    } catch (err) {
      this.emitter.emit("error", err instanceof Error ? err : new Error(String(err)))
    }
  }

  // 聚合模式反向流:更新聚合卡内目标元素 status,并按 silent 状态机决定是否恢复响铃。
  // 用户回答后若回合继续(未 done)且无其他 pending 交互 → 整卡 silent 恢复 true
  // (不再响铃,回合结束 footer 再翻 silent=false 计未读);回合已结束或仍有
  // pending 交互 → 不碰 silent(保持当前状态)。
  // session 状态不可用(peekState miss)时无法全量替换 PATCH,跳过更新(回声路径兜底)。
  private async updateAggregateElement(
    entry: CardEntry,
    patchData: Record<string, unknown>,
  ): Promise<void> {
    const state = entry.sessionId ? this.store.peekState(entry.sessionId) : undefined
    // 跨轮防护:state 当前聚合卡必须就是 entry 指向的那张卡(msgId 一致),
    // 否则 element_id 可能被新一轮复用(序号从 1 重计),误更新新卡元素。
    if (!state || state.aggregateCardMsgId !== entry.msgId) {
      console.warn(`[interaction] 聚合卡交互响应:session 状态不可用或跨轮,跳过元素更新: request=${entry.msgId.slice(0, 16)}`)
      return
    }
    const stillPending = (state.aggregateElements ?? []).some(
      (e) => (e.type === "question_card" || e.type === "permission_card")
        && e.element_id !== entry.elementId
        && e.data.status === "pending",
    )
    const restoreSilent = state.aggregateCardState !== "done" && !stillPending
    await new AggregateCardManager(this.wanling, state).updateElement(
      entry.elementId as string,
      patchData,
      restoreSilent ? { silent: true } : undefined,
    )
  }

  async cleanupOrphans(): Promise<void> {
    const cards = getAllCards()
    const entries = Object.entries(cards)
    if (entries.length === 0) return

    // 只清理超过 10 分钟的卡片：近期创建的可能仍在正常处理流程中
    // （APP 刚答 / TUI 刚答但 deleteCard 尚未落盘），避免误覆盖终态。
    const STALE_MS = 10 * 60 * 1000
    const now = Date.now()
    const stale = entries.filter(([, e]) => now - (e.createdAt ?? 0) > STALE_MS)
    if (stale.length === 0) return

    console.log(`[streamer] 启动清理: ${stale.length}/${entries.length} 张超过 10min 的 pending 卡片 → expired`)
    for (const [requestId, entry] of stale) {
      try {
        if (entry.elementId) {
          // 聚合模式:更新聚合卡内对应元素 expired。
          // session 状态不可用(plugin 重启后内存空)/跨轮(state 聚合卡不是 entry
          // 指向的那张)时无法全量替换 PATCH(会丢其他元素),只丢弃本地记账,不反复重试。
          const state = entry.sessionId ? this.store.peekState(entry.sessionId) : undefined
          if (state && state.aggregateCardMsgId === entry.msgId) {
            await new AggregateCardManager(this.wanling, state).updateElement(
              entry.elementId,
              { oc_request_id: requestId, status: "expired" },
            )
          } else {
            console.warn(`[streamer] 聚合卡孤儿元素 session 状态不可用或跨轮,丢弃记账: ${requestId.slice(0, 16)}`)
          }
          deleteCard(requestId)
          continue
        }

        const msgType = entry.type === "permission" ? "permission_card" : "question_card"
        await this.wanling.updateMessageContent(entry.msgId, {
          msg_type: msgType,
          data: { ...(entry.data || {}), status: "expired" },
        })
        deleteCard(requestId)
      } catch (err) {
        console.error(`[streamer] 清理卡片 ${requestId.slice(0, 16)} 失败,下次重试:`, err)
        // 不 deleteCard，保留本地记录供下次 cleanup 重试
      }
    }
    console.log(`[streamer] 孤儿卡片清理完成`)
  }

  // 聚合卡是否对本 state 生效:开关开启且非子 session。
  // 子 session 的 question/permission 恒走独立卡(聚合卡上无法表达 child 层级,
  // 与 tool_card 子 session 不聚合口径一致)。
  private useAggregate(state: SessionState): boolean {
    return this.aggregateCardEnabled && !state.isChildSession
  }

  // 聚合卡元素序号计数器:与 PartDispatcher / ToolCardManager 共用 state.aggregateSeq,
  // question/permission 与 reasoning/markdown/tool/footer 全卡唯一递增。
  private nextSeq(state: SessionState): number {
    const seq = (state.aggregateSeq ?? 0) + 1
    state.aggregateSeq = seq
    return seq
  }

  // 追加聚合卡元素并 PATCH 增量 op(append)。队列/累计由 AggregateCardManager.appendElement
  // 统一维护,与 part_dispatcher / tool_card 共用同一串行队列(state.aggregatePatchQueue),
  // 并发 flush 时按序执行,不互相覆盖丢元素。
  // opts.silent 透传:pending 交互元素传 {silent:false} 单独发 set_silent op 整卡翻转响铃。
  private appendElement(
    state: SessionState,
    element: AggregateElement,
    opts?: { silent?: boolean },
  ): Promise<void> {
    return new AggregateCardManager(this.wanling, state).appendElement(element, opts)
  }
}
