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
import type { MessageRouter } from "../messaging.js"
import type { ToolCardManager } from "./tool_card.js"
import { saveCard, getCard, deleteCard, getAllCards } from "../card_store.js"

// InteractionCards:permission / question 交互卡片领域模块。
// 职责:交互卡片的正向流(OpenCode 问 → 发 card 到 APP) + 反向流(TUI 答 → PATCH
// 原 card 切终态) + 启动时孤儿卡片清理(plugin 重启后兜底 PATCH 为 expired)。
// 不持有状态(card_store 是模块级单例,跨实例共享)。错误经注入的 emitter
// (Streamer extends EventEmitter,传 this 作 emitter)上抛。
export class InteractionCards {
  private readonly store: SessionStore
  private readonly router: MessageRouter
  private readonly wanling: WanlingClient
  private readonly toolCard: ToolCardManager
  private readonly emitter: EventEmitter

  constructor(deps: {
    store: SessionStore
    router: MessageRouter
    wanling: WanlingClient
    toolCard: ToolCardManager
    emitter: EventEmitter
  }) {
    this.store = deps.store
    this.router = deps.router
    this.wanling = deps.wanling
    this.toolCard = deps.toolCard
    this.emitter = deps.emitter
  }

  // 交互事件 — 正向流（OpenCode 问 → 发 card 到 APP）
  async onPermissionAsked(payload: ApprovalRequestPayload): Promise<void> {
    try {
      const state = await this.store.getOrCreateState(payload.sessionID)
      if (!state) return

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
}
