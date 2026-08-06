import type { WanlingClient } from "../../wanling/client.js"
import type { SessionState } from "../types.js"

// 聚合卡元素:聚合卡 message 的 data.elements[] 结构。
// element_id 全局唯一、字母开头、≤20 字符(type_seq 规则,如 reasoning_1)。
// type 由 APP aggregate_card renderer(Task 6)按元素类型分派渲染。
// question_card / permission_card:交互元素嵌入聚合卡(2026-08-06 变更),
// 数据对齐现有 question/permission 卡 renderer 消费字段,聚合卡内不丢字段。
export interface AggregateElement {
  type: "reasoning" | "tool_card" | "markdown" | "compact_divider" | "footer" | "question_card" | "permission_card"
  element_id: string
  data: Record<string, unknown>
}

// tool_card 元素 data:对齐现有 tool_card renderer 消费字段
// (tool_card.ts 发送态 / tool_card_renderer.dart 渲染态),聚合卡内不丢字段。
// 用 type 别名而非 interface:别名带隐式索引签名,可直接赋给 AggregateElement.data。
export type ToolCardData = {
  name: string
  input: Record<string, unknown>
  output?: string
  status?: string
  error?: string
  file_diff?: Record<string, unknown>
  sub_session_id?: string
  duration?: number
}

// footer 元素 data:回合结束汇总行(对齐 step_finish renderer 的 tokens/duration/cost)。
export type FooterData = {
  reason?: string
  cost?: number
  tokens?: { input?: number; output?: number; reasoning?: number; total?: number; cache?: { read?: number; write?: number } }
  duration?: number
  finished?: boolean
}

// question_card 元素 data:对齐现有 question_card renderer 消费字段
// (interaction.ts 发送态,status 由反向流切换 answered/rejected/expired)。
export type QuestionCardData = {
  oc_request_id: string
  questions: Array<{
    question: string
    header: string
    options: Array<{ label: string; description: string }>
    multiple?: boolean
    custom?: boolean
  }>
  status?: string
  result?: string
}

// permission_card 元素 data:对齐现有 permission_card renderer 消费字段
// (interaction.ts 发送态,status 由反向流切换 approved/denied/expired)。
export type PermissionCardData = {
  oc_request_id: string
  action: string
  resources: string[]
  save?: string[]
  metadata?: Record<string, unknown>
  status?: string
  result?: string
}

// AggregateCardManager:聚合卡发送核心领域模块。
// 职责:一次问答一张聚合卡 — ensureCard 建卡(幂等,msgId 存 SessionState 跨实例复用),
// patchElements 全量替换 elements[](非增量 diff)。silent 翻转(回合结束 {silent:false})
// 由 server 端 Task 1 的 IncrUnread 承接,这里只是显式透传。
export class AggregateCardManager {
  constructor(
    private readonly wanling: WanlingClient,
    private readonly state: SessionState,
  ) {}

  // 建聚合卡(空元素,state=generating)返回真实 msgId;已建则复用。
  // sendCardMessage 默认 silent=true(回合进行中不打扰,计未读职责由回合结束翻转承接)。
  // 并发首调竞态修复:sendCardMessage 飞行中把 Promise 缓存到 state.aggregateCardInflight,
  // 共享同一 state 的并发 ensureCard(如 reasoning end 与 text end 同时 flush)await
  // 同一 Promise,只发一次建卡请求(否则双卡)。参考 tool_card.ts 的 toolCardInflight 模式。
  async ensureCard(): Promise<string> {
    if (this.state.aggregateCardMsgId) return this.state.aggregateCardMsgId
    const inflight = this.state.aggregateCardInflight
    if (inflight) {
      try {
        return await inflight
      } catch {
        // 建卡失败:落到下方重新发起(失败后不再复用坏 Promise)
      }
    }
    const promise = this.wanling.sendCardMessage(this.state.convId, "aggregate_card", {
      state: "generating",
      elements: [],
    })
    this.state.aggregateCardInflight = promise
    try {
      const msgId = await promise
      this.state.aggregateCardMsgId = msgId
      return msgId
    } finally {
      if (this.state.aggregateCardInflight === promise) {
        this.state.aggregateCardInflight = undefined
      }
    }
  }

  // 全量替换 elements[](非增量 diff)。
  // state 语义(I3):server 端 UpdateContent 全量替换 data,未显式带 state 的 PATCH
  // (如迟到 tool 终态)会丢 state 字段。故这里维护 state.aggregateCardState 当前值:
  // - opts.state 显式传 → 更新 state.aggregateCardState 并写入 PATCH
  // - opts.state 未传   → 沿用 state.aggregateCardState(建卡默认 generating),
  //   保证回合结束(done)后的迟到 PATCH 不把卡片翻回 generating。
  // silent 翻转时传 {silent:false} → content 显式带 silent:false 触发计未读。
  async patchElements(
    elements: AggregateElement[],
    opts?: { silent?: boolean; state?: "generating" | "done" },
  ): Promise<void> {
    const nextState = opts?.state ?? this.state.aggregateCardState ?? "generating"
    if (opts?.state) this.state.aggregateCardState = opts.state
    const msgId = await this.ensureCard()
    await this.wanling.patchAggregateMessage(
      msgId,
      { state: nextState, elements },
      opts?.silent === undefined ? undefined : { silent: opts.silent },
    )
  }

  static reasoning(text: string, seq: number): AggregateElement {
    return { type: "reasoning", element_id: `reasoning_${seq}`, data: { text } }
  }

  static toolCard(data: ToolCardData, seq: number): AggregateElement {
    return { type: "tool_card", element_id: `tool_card_${seq}`, data }
  }

  static markdown(text: string, seq: number): AggregateElement {
    return { type: "markdown", element_id: `markdown_${seq}`, data: { text } }
  }

  static footer(data: FooterData, seq: number): AggregateElement {
    return { type: "footer", element_id: `footer_${seq}`, data }
  }

  static questionCard(data: QuestionCardData, seq: number): AggregateElement {
    return { type: "question_card", element_id: `question_card_${seq}`, data }
  }

  static permissionCard(data: PermissionCardData, seq: number): AggregateElement {
    return { type: "permission_card", element_id: `permission_card_${seq}`, data }
  }

  // 定位聚合卡内元素并全量替换更新(按 element_id,合并 patchData 到该元素 data)。
  // 与 PartDispatcher.appendElement / ToolCardManager.updateToolElement 同一串行队列
  // (state.aggregatePatchQueue)语义:更新排在其他 append/update 之后执行,
  // 读到的 state.aggregateElements 已含目标元素;并发更新不互相覆盖。
  // silent 语义同 patchElements:显式 {silent:true} 恢复不响铃,
  // {silent:false} 翻转计未读(由 server mergePreservedSilent 尊重显式值)。
  // 元素缺失时不 PATCH(避免用缺失元素的列表全量替换丢其他元素)。
  async updateElement(
    elementId: string,
    patchData: Record<string, unknown>,
    opts?: { silent?: boolean },
  ): Promise<void> {
    const prev = this.state.aggregatePatchQueue ?? Promise.resolve()
    const next = prev.then(async () => {
      const existed = (this.state.aggregateElements ?? []).some((e) => e.element_id === elementId)
      if (!existed) return
      const elements = (this.state.aggregateElements ?? []).map((e) =>
        e.element_id === elementId ? { ...e, data: { ...e.data, ...patchData } } : e,
      )
      this.state.aggregateElements = elements
      await this.patchElements(elements, opts)
    })
    // 队列吞掉前一次失败,保证后续追加不被坏 Promise 阻塞;next 本身仍向调用方传播错误。
    this.state.aggregatePatchQueue = next.catch(() => {})
    return next
  }
}
