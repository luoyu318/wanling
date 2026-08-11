import type { EventEmitter } from "events"
import { logger } from "../../utils/logger.js"
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
    // 分卡跨卡防护:元素归属映射命中(该元素确实在当前 session 的某张聚合卡上,
    // 含分卡后留在旧卡的元素) → 允许回传,updateElement 内部按映射 PATCH 到旧卡。
    // 真跨轮(新一轮 element_id 复用,映射未命中)→ 跳过,防误更新新卡元素。
    // (不再用 aggregateCardMsgId === entry.msgId:分卡后当前卡已指向新卡,旧卡
    // 交互元素回传会被误伤,这是分卡后的回传 bug 根因。)
    const elementId = entry.elementId as string
    const ownerCardId = state?.aggregateElementCardIds?.get(elementId)
    if (!state || !ownerCardId) {
      console.warn(`[interaction] 聚合卡交互响应:session 状态不可用或元素不在归属映射,跳过更新: request=${entry.msgId.slice(0, 16)}`)
      return
    }
    // 仍有 pending 交互判断要覆盖全卡(含分卡后旧卡遗留的 pending 交互):
    // 若还有其它 pending 交互未答 → 不恢复 silent(避免打断用户);
    // 全部答完才恢复。旧卡元素在 aggregateElementCardIds 映射里,但累计
    // aggregateElements 只剩当前卡,这里从映射反查元素集合补齐判断。
    const stillPending = this.hasOtherPending(state, entry.sessionId ?? "", elementId)
    const restoreSilent = state.aggregateCardState !== "done" && !stillPending
    await new AggregateCardManager(this.wanling, state).updateElement(
      elementId,
      patchData,
      restoreSilent ? { silent: true } : undefined,
    )
  }

  // 判断聚合卡序列(含分卡旧卡)中是否存在其它仍 pending 的交互元素。
  // 分卡后 state.aggregateElements 只含当前卡累计,旧卡元素不在其中;
  // 用当前卡累计 + 从 card_store 全量 entry 反查未答交互,避免漏判。
  private hasOtherPending(state: SessionState, sessionId: string, exceptElementId: string): boolean {
    // 当前卡累计内的 pending 交互(除目标元素)
    const currentPending = (state.aggregateElements ?? []).some(
      (e) => (e.type === "question_card" || e.type === "permission_card")
        && e.element_id !== exceptElementId
        && e.data.status === "pending",
    )
    if (currentPending) return true
    // 旧卡遗留 pending 交互:card_store 中仍存活的交互卡(未 deleteCard),
    // 且其元素属于当前 session 的聚合卡序列(映射命中),视为未答完。
    const entries = getAllCards()
    for (const e of Object.values(entries)) {
      if (e.sessionId !== sessionId || !e.elementId) continue
      if (e.elementId === exceptElementId) continue
      if (state.aggregateElementCardIds?.has(e.elementId)) return true
    }
    return false
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

    logger.info(`[streamer] 启动清理: ${stale.length}/${entries.length} 张超过 10min 的 pending 卡片 → expired`)
    for (const [requestId, entry] of stale) {
      try {
        if (entry.elementId) {
          // 聚合模式:更新聚合卡内对应元素 expired。
          // 分卡跨卡防护:元素归属映射命中(含分卡后旧卡元素)才 PATCH;
          // session 状态不可用(plugin 重启后内存空)/映射未命中(真跨轮或
          // 元素已不在聚合卡序列)时只丢弃本地记账,不反复重试。
          const state = entry.sessionId ? this.store.peekState(entry.sessionId) : undefined
          if (state && state.aggregateElementCardIds?.has(entry.elementId)) {
            await new AggregateCardManager(this.wanling, state).updateElement(
              entry.elementId,
              { oc_request_id: requestId, status: "expired" },
            )
          } else {
            console.warn(`[streamer] 聚合卡孤儿元素 session 状态不可用或不在归属映射,丢弃记账: ${requestId.slice(0, 16)}`)
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
    logger.info(`[streamer] 孤儿卡片清理完成`)
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
