import type { EventEmitter } from "events"
import { logger } from "../../utils/logger.js"
import type { WanlingClient } from "../../wanling/client.js"
import type { OpencodeBridge } from "../../opencode/bridge.js"
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
import { getAggregateCard, permissionCardElement } from "./aggregate_bridge.js"
import { saveCard, getCard, deleteCard, getAllCards, type CardEntry } from "../card_store.js"
import type { AskResult, ApprovalOption } from "@wanling/sdk"

// InteractionCards:permission / question 交互卡片领域模块。
// 职责:交互卡片的正向流(OpenCode 问 → 发 card 到 APP) + 反向流(TUI 答 → PATCH
// 原 card 切终态) + 启动时孤儿卡片清理(plugin 重启后兜底 PATCH 为 expired)。
//
// Task 8 迁移 SDK 后的双轨:
// - question(主 session 聚合模式)→ SDK Approvals.ask(client.approvals):server 状态机
//   审批卡(独立 card 消息,APP 审批卡 renderer 渲染单选/多选/answers 终态),
//   resolve 后调 opencode.replyQuestion/rejectQuestion 回填 OC。卡片状态翻转
//   (pending → answered/approved/终态)由 server Decide 双写 content 承担,不再
//   嵌入聚合卡元素。
// - permission → 保留自管(聚合模式嵌入聚合卡 permission_card 元素 + card_store 记账;
//   非聚合模式独立卡)。工具审批迁移到 SDK approvals 在 question 验证稳定后单独小步做。
// - 反向流(TUI 答 → SSE 回声)保留:question 回声经 pendingQuestions 登记表去重
//   (TUI 先答 → ask 决议后不再回填 OC);permission 回声经 card_store 定位更新元素/
//   独立卡(TUI 双端场景,isNotFound 去重在 engine 侧)。
// - 子 session 恒走独立卡(question/permission 均不聚合,聚合卡上无法表达 child 层级)。
//   子 session 的 question 走独立 question_card + card_store(engine 反向流消费)。
// 开关 false 时完全回退旧逻辑(独立卡)。
// 不持有可变状态(card_store 是模块级单例,跨实例共享;pendingQuestions 进程内登记)。
// 错误经注入的 emitter(Streamer extends EventEmitter,传 this 作 emitter)上抛。
export class InteractionCards {
  private readonly store: SessionStore
  private readonly router: MessageRouter
  private readonly wanling: WanlingClient
  private readonly opencode: OpencodeBridge
  private readonly toolCard: ToolCardManager
  private readonly emitter: EventEmitter
  // 聚合卡开关:false 回退旧逐条发送(独立 permission/question 卡)。默认 true。
  private readonly aggregateCardEnabled: boolean
  // 进行中的 question ask 登记表:oc_request_id → { settled }(TUI 先答回声置位,
  // ask 决议后检查跳过回填,防 OC question 被二次回复)。ask 决议/超时后条目清理。
  private readonly pendingQuestions = new Map<string, { settled: boolean }>()

  constructor(deps: {
    store: SessionStore
    router: MessageRouter
    wanling: WanlingClient
    opencode: OpencodeBridge
    toolCard: ToolCardManager
    emitter: EventEmitter
    aggregateCardEnabled?: boolean
  }) {
    this.store = deps.store
    this.router = deps.router
    this.wanling = deps.wanling
    this.opencode = deps.opencode
    this.toolCard = deps.toolCard
    this.emitter = deps.emitter
    this.aggregateCardEnabled = deps.aggregateCardEnabled ?? true
  }

  // 交互事件 — 正向流（OpenCode 问 → 发 card 到 APP）
  // permission 保留自管:聚合模式嵌入聚合卡元素(pending 交互 → 整卡翻转 silent=false
  // 响铃),card_store 存聚合卡 msgId + element_id + sessionId(供反向流定位)。
  async onPermissionAsked(payload: ApprovalRequestPayload): Promise<void> {
    try {
      const state = await this.store.getOrCreateState(payload.sessionID)
      if (!state) return

      if (this.useAggregate(state)) {
        const element = permissionCardElement({
          oc_request_id: payload.id,
          action: payload.action,
          resources: payload.resources,
          save: payload.save || [],
          metadata: payload.metadata || {},
          status: "pending",
        }, this.nextSeq(state))
        // pending 交互元素出现 → PATCH 整卡翻转 silent=false 响铃(需要用户介入)
        await getAggregateCard(state, this.wanling).appendElement(element, { silent: false })
        const msgId = getAggregateCard(state, this.wanling).cardMessageId
        if (!msgId) {
          throw new Error(`permission 元素追加后聚合卡 msgId 缺失: request=${payload.id}`)
        }
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
        // 子 session:带 sub_session_id 供 APP 精确挂载到对应 task 卡。
        // 聚合卡模式下多个 task 元素共享聚合卡 msgId(parentMsgId 无法区分),
        // 缺此字段会串挂到所有 task 卡下。
        ...(state.isChildSession ? { sub_session_id: state.childEntry?.childSessionId } : {}),
      }, false)

      await saveCard(payload.id, { msgId, convId: state.convId, type: "permission", directory: payload.directory, data: { action: payload.action, resources: payload.resources, save: payload.save || [], metadata: payload.metadata || {} } })

      // permission_card 已创建,现在刷新 pending tool_card（如果有）,确保顺序: 审批卡→工具卡
      this.toolCard.flushPending(state)
    } catch (err) {
      this.emitter.emit("error", err instanceof Error ? err : new Error(String(err)))
    }
  }

  // question 正向流:
  // - 主 session(聚合模式)→ SDK approvals.ask:OC questions 映射审批卡 options
  //   (多问题拍平,option id = 标签;多问题时带 header 前缀防撞),resolve 后回填 OC。
  //   TUI 先答回声(SSE question.replied)会置位 settled,决议后跳过回填(双向去重)。
  // - 子 session / 开关关闭 → 独立 question_card + card_store(engine 反向流消费)。
  async onQuestionAsked(payload: QuestionAskedPayload): Promise<void> {
    try {
      const state = await this.store.getOrCreateState(payload.sessionID)
      if (!state) return

      if (this.useAggregate(state)) {
        await this.askViaApprovals(payload, state)
        return
      }

      const msgId = await this.router.sendCard(state, "question_card", {
        oc_request_id: payload.id,
        questions: payload.questions,
        status: "pending",
        // 子 session:带 sub_session_id 供 APP 精确挂载到对应 task 卡(同上)。
        ...(state.isChildSession ? { sub_session_id: state.childEntry?.childSessionId } : {}),
      }, false)

      await saveCard(payload.id, { msgId, convId: state.convId, type: "question", directory: payload.directory, data: { questions: payload.questions } })

      this.toolCard.flushPending(state)
    } catch (err) {
      this.emitter.emit("error", err instanceof Error ? err : new Error(String(err)))
    }
  }

  // SDK approvals.ask 接线(主 session question):
  // 1. OC questions → 审批卡 options 映射(拍平 + 归属登记,答案回填时按 qIdx 分组)
  // 2. ask 决议 → approved.answers → replyQuestion(按 qIdx 分组);denied/expired →
  //    rejectQuestion(OC 侧可能已超时,404 静默跳过)
  // 3. pendingQuestions.settled(TUI 先答)→ 跳过回填
  // 审批卡创建即 REST 发卡(不等决议),toolCard.flushPending 紧随(审批卡→工具卡顺序)。
  private async askViaApprovals(payload: QuestionAskedPayload, state: SessionState): Promise<void> {
    const questions = payload.questions
    if (questions.length === 0) return
    // 多问题拍平:option id 全卡唯一(单问题直接用 label,多问题带 header 前缀防撞),
    // optionOwners 登记 id → qIdx 供答案分组;multiSelect = 任一问题允许多选。
    const optionOwners = new Map<string, number>()
    const options: ApprovalOption[] = []
    for (let qIdx = 0; qIdx < questions.length; qIdx++) {
      const q = questions[qIdx]
      for (const o of q.options) {
        const id = questions.length > 1 && qIdx > 0 ? `${q.header || `Q${qIdx + 1}`}:${o.label}` : o.label
        optionOwners.set(id, qIdx)
        options.push({ id, label: o.description ? `${o.label} — ${o.description}` : o.label })
      }
    }
    const title = questions.length === 1
      ? (questions[0].header || questions[0].question || "Agent 提问")
      : `Agent 提问(${questions.length} 个问题)`
    const entry = { settled: false }
    this.pendingQuestions.set(payload.id, entry)
    // 发卡(REST)即返回 pending 卡;pendingToolCard 刷新不等决议(工具卡不被答题阻塞)
    const askP = this.wanling.approvals.ask(state.convId, {
      cardType: "question",
      title,
      options,
      multiSelect: questions.some((q) => q.multiple),
      sessionKey: payload.id,
    })
    this.toolCard.flushPending(state)
    let result: AskResult
    try {
      result = await askP
    } catch (err) {
      this.pendingQuestions.delete(payload.id)
      throw err instanceof Error ? err : new Error(String(err))
    }
    this.pendingQuestions.delete(payload.id)
    // TUI 双端:TUI 已答(回声先到置位)→ OC question 已被 TUI 解决,不再回填
    if (entry.settled) {
      logger.info(`[interaction] question ${payload.id.slice(0, 16)} 已由 TUI 答复,跳过回填`)
      return
    }
    try {
      if (result.state === "approved") {
        // answers(option id 列表)按归属分组回填;未覆盖的问题给空数组(该问题未答)
        const answers = Array.from({ length: questions.length }, (_, qIdx) =>
          (result.answers ?? []).filter((a) => optionOwners.get(a) === qIdx))
        await this.opencode.replyQuestion(payload.id, answers, payload.directory)
      } else {
        // denied(用户点拒绝)/ expired(超时):rejectQuestion;OC 侧可能已自行
        // 超时清理,404 类错误静默跳过(与 engine 反向流同款 isNotFound 口径)
        await this.opencode.rejectQuestion(payload.id, payload.directory)
      }
    } catch (err) {
      if (isNotFound(err)) {
        logger.info(`[interaction] question ${payload.id.slice(0, 16)} 已处理(404),跳过`)
        return
      }
      throw err instanceof Error ? err : new Error(String(err))
    }
  }

  // 交互事件 — 反向流（TUI 答 → PATCH 原 card 切终态）
  // 若 getCard 返回 null：正向流 engine 已处理（APP 答 → engine PATCH 后已 deleteCard）,
  // 或 question 走 SDK approvals(无 card_store 记账) → 跳过。
  // 保留自管(本任务边界):permission 聚合元素/独立卡 + 非聚合 question 独立卡。
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
      // SDK approvals 路径的 question:无 card_store 记账,登记表置位(TUI 先答 →
      // ask 决议后跳过回填);APP 先答的回声(我们自己的 replyQuestion 触发)时
      // 登记条目已随决议清理,此处自然跳过 —— 双向回声去重。
      const pending = this.pendingQuestions.get(payload.requestID)
      if (pending) {
        pending.settled = true
        logger.info(`[interaction] question ${payload.requestID.slice(0, 16)} 由 TUI 答复,标记 ask 不再回填`)
        return
      }

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
      const pending = this.pendingQuestions.get(payload.requestID)
      if (pending) {
        pending.settled = true
        logger.info(`[interaction] question ${payload.requestID.slice(0, 16)} 由 TUI 拒绝,标记 ask 不再回填`)
        return
      }

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
  // 用户回答后若回合继续(未收尾)且无其他 pending 交互 → 整卡 silent 恢复 true
  // (不再响铃,回合结束 footer 再翻 silent=false 计未读);回合已结束或仍有
  // pending 交互 → 不碰 silent(保持当前状态)。
  // SDK update 对分卡旧卡元素是整体替换,patchData 由 entry.data(建卡时记账的全量
  // 元素 data)合并补全,不丢 action/resources/questions 等既有字段。
  // session 状态不可用(peekState miss)或元素不在归属映射(真跨轮 element_id 复用)
  // 时跳过更新(回声路径兜底,防误更新新卡元素)。
  private async updateAggregateElement(
    entry: CardEntry,
    patchData: Record<string, unknown>,
  ): Promise<void> {
    const state = entry.sessionId ? this.store.peekState(entry.sessionId) : undefined
    const elementId = entry.elementId as string
    const bridge = state ? getAggregateCard(state, this.wanling) : undefined
    // 分卡跨卡防护:元素归属映射命中(该元素确实在当前 session 的某张聚合卡上,
    // 含分卡后留在旧卡的元素) → 允许回传,bridge.updateElement 内部按 SDK 归属映射
    // PATCH 到旧卡。真跨轮(新一轮 element_id 复用,收尾时映射已清) → 跳过。
    if (!state || !bridge || !bridge.elementCardIds.has(elementId)) {
      console.warn(`[interaction] 聚合卡交互响应:session 状态不可用或元素不在归属映射,跳过更新: request=${entry.msgId.slice(0, 16)}`)
      return
    }
    // 仍有其他 pending 交互(card_store 中仍存活的未答交互卡,含分卡旧卡遗留):
    // 若还有其它 pending 交互未答 → 不恢复 silent(避免打断用户);全部答完才恢复。
    const stillPending = this.hasOtherPending(entry.sessionId ?? "", elementId)
    const restoreSilent = !bridge.sealed && !stillPending
    await bridge.updateElement(
      elementId,
      // 整体替换语义:entry.data(建卡时全量)+ 终态字段,SDK 当前卡元素会再与镜像合并
      { ...(entry.data || {}), ...patchData },
      restoreSilent ? { silent: true } : undefined,
    )
  }

  // 判断聚合卡序列(含分卡旧卡)中是否存在其它仍 pending 的交互元素:
  // card_store 中仍存活的交互卡(未 deleteCard)即未答(pending 交互必 saveCard,
  // 回答/清理必 deleteCard,store 存活集合 = pending 集合)。
  private hasOtherPending(sessionId: string, exceptElementId: string): boolean {
    const entries = getAllCards()
    for (const e of Object.values(entries)) {
      if (e.sessionId !== sessionId || !e.elementId) continue
      if (e.elementId === exceptElementId) continue
      return true
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
          const bridge = state ? getAggregateCard(state, this.wanling) : undefined
          if (state && bridge?.elementCardIds.has(entry.elementId)) {
            await bridge.updateElement(
              entry.elementId,
              { ...(entry.data || {}), oc_request_id: requestId, status: "expired" },
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
  // permission 与 reasoning/markdown/tool/footer 全卡唯一递增。
  private nextSeq(state: SessionState): number {
    const seq = (state.aggregateSeq ?? 0) + 1
    state.aggregateSeq = seq
    return seq
  }
}

/**
 * 判断"未找到"类错误(OC question/permission 请求已被另一端处理或已超时)。
 * 与 engine.ts 的 isNotFound 同口径;interaction 的 ask 回填路径复用。
 */
function isNotFound(err: unknown): boolean {
  const e = err as { sdkError?: { code?: number; status?: number; statusCode?: number }; message?: string }
  const code = e?.sdkError?.code ?? e?.sdkError?.status ?? e?.sdkError?.statusCode
  if (code === 404) return true
  const lower = (e?.message ?? "").toLowerCase()
  return lower.includes("404")
    || lower.includes("not found")
    || lower.includes("does not exist")
    || lower.includes("no longer exists")
    || (lower.includes("session") && lower.includes("ended"))
}
