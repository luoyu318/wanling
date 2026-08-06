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
  // 主动收尾标记(abort 停止):true 时 APP footer 显示「已停止」而非 tokens 汇总。
  // 仅 finishCard("stop") 置 true;finishCard("interrupt")(排队分段)与正常
  // step-finish 定稿不带此标记。
  stopped?: boolean
  // 回合结束快照:mode(model 模式)/model(模型显示名,modelName ?? modelId)。
  // 消息快照语义:回合结束时的值固化进 footer,不随 sessionMeta 实时态变动。
  mode?: string
  model?: string
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

// 聚合卡增量 PATCH op(server Task A 已支持):content.data 带 op 字段时,
// server 按 op 合并到全量存储、广播带增量;无 op 带 elements 仍是全量替换兼容。
// 增量协议(server applyContentOp):
//   { op:"append", element }                      → 末尾追加元素(无 upsert)
//   { op:"update", element_id, data }             → 整体替换目标元素 data(元素不存在 400)
//   { op:"remove", element_id }                   → 删除元素(不存在幂等跳过)
//   { op:"reorder", order:[...] }                 → 按 order 重排
//   { op:"set_state", state }                     → 改 data.state
//   { op:"set_silent", silent }                   → 改顶层 content.silent(翻转触发未读)
export type AggregatePatchOp =
  | { op: "append"; element: AggregateElement }
  | { op: "update"; element_id: string; data: Record<string, unknown> }
  | { op: "remove"; element_id: string }
  | { op: "reorder"; order: string[] }
  | { op: "set_state"; state: "generating" | "done" }
  | { op: "set_silent"; silent: boolean }

// patchAggregateMessage 的 data 入参:增量 op 或全量替换(兼容,无 op)。
export type AggregatePatchData = AggregatePatchOp | { state?: string; elements: AggregateElement[] }

// 聚合卡协议 schema 版本(data.schema_ver)。从 1 起,缺失视为 1;破坏性协议变更时递增。
// 建卡时写 data.schema_ver=1(全量 content 携带);增量 op 是瞬态指令不携带版本。
// server 合并保留未知字段(schema_ver 天然透传);APP 读本地 content 的 schema_ver,
// > 支持版本时不应用增量(保持现状防误用),等全量替换兜底。未来跨版本共存无需返工。
export const AGGREGATE_SCHEMA_VER = 1

// AggregateCardManager:聚合卡发送核心领域模块。
// 职责:一次问答一张聚合卡 — ensureCard 建卡(幂等,msgId 存 SessionState 跨实例复用),
// appendElement 增量 append / updateElement 增量 update。silent 翻转(回合结束
// {set_silent:false})由 server 端 Task 1 的 IncrUnread 承接,这里发增量 op。
// state/silent 不再随 append/update 携带(增量下 server 保留原值),仅在显式翻转时
// 单独发 set_state / set_silent op,根治全量替换丢 state 的 I3 问题。
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
      schema_ver: AGGREGATE_SCHEMA_VER,
      state: "generating",
      elements: [],
    })
    this.state.aggregateCardInflight = promise
    try {
      const msgId = await promise
      this.state.aggregateCardMsgId = msgId
      // 激活聚合卡:建卡后标记 generating,收尾(reset)后保持 done 直到下次建卡。
      // 供 finishCard 幂等守卫与 step-finish cardActive 判断区分「可收尾的活跃卡」
      // 与「已收尾等待开新卡」(避免跨轮残留触发 finishCard 误收尾)。
      this.state.aggregateCardState = "generating"
      return msgId
    } finally {
      if (this.state.aggregateCardInflight === promise) {
        this.state.aggregateCardInflight = undefined
      }
    }
  }

  // 增量 append:维护本地累计 + 串行队列(aggregatePatchQueue)后,发 {op:"append"}。
  // 同 element_id 已存在(流式占位 / 终态补全)时发 {op:"update"} 原位替换 ——
  // server append 无 upsert(总是末尾追加),若占位后终态仍 append 会出双元素。
  // opts.state 显式传 → 单独发 {op:"set_state"} 并维护 state.aggregateCardState;
  // opts.silent !== undefined → 单独发 {op:"set_silent"}。增量下 server 保留原
  // state/silent,不再像全量替换那样每次 PATCH 都带。
  // 竞态补发:append 落地后检查 state.aggregatePendingUpdates 是否有该元素在 append 前
  // 缓存的 update(registerTaskChildEarly 提前注册 → working PATCH 早于 append 落地),
  // 有则合并进本地元素 data 并补发 {op:"update"},避免子 agent 卡片永卡 starting。
  async appendElement(
    element: AggregateElement,
    opts?: { silent?: boolean; state?: "generating" | "done" },
  ): Promise<void> {
    const prev = this.state.aggregatePatchQueue ?? Promise.resolve()
    const next = prev.then(async () => {
      const existed = (this.state.aggregateElements ?? []).some((e) => e.element_id === element.element_id)
      const elements = existed
        ? (this.state.aggregateElements ?? []).map((e) => (e.element_id === element.element_id ? element : e))
        : [...(this.state.aggregateElements ?? []), element]
      this.state.aggregateElements = elements
      const msgId = await this.ensureCard()
      await this.wanling.patchAggregateMessage(
        msgId,
        existed ? { op: "update", element_id: element.element_id, data: element.data } : { op: "append", element },
      )
      // 补发 append 前缓存的 pending update(子 agent working 竞态):合并进元素 data,
      // 更新本地累计并补发 update op,让状态推进不再依赖 updateElement 时的元素已就绪。
      const pending = this.state.aggregatePendingUpdates?.get(element.element_id)
      if (pending) {
        this.state.aggregatePendingUpdates?.delete(element.element_id)
        const mergedData = { ...element.data, ...pending }
        this.state.aggregateElements = (this.state.aggregateElements ?? []).map((e) =>
          e.element_id === element.element_id ? { ...e, data: mergedData } : e,
        )
        await this.wanling.patchAggregateMessage(msgId, {
          op: "update",
          element_id: element.element_id,
          data: mergedData,
        })
      }
      if (opts?.state) {
        this.state.aggregateCardState = opts.state
        await this.wanling.patchAggregateMessage(msgId, { op: "set_state", state: opts.state })
      }
      if (opts?.silent !== undefined) {
        await this.wanling.patchAggregateMessage(msgId, { op: "set_silent", silent: opts.silent })
      }
    })
    // 队列吞掉前一次失败,保证后续追加不被坏 Promise 阻塞;next 本身仍向调用方传播错误。
    this.state.aggregatePatchQueue = next.catch(() => {})
    return next
  }

  // reasoning 元素构造器。finished 标记该思考链是否已终态(内容完整)——
  // 聚合卡元素级 finished(Task 增量修复方案 B):流式占位时 finished=false,
  // 终态 append 时 finished=true。APP reasoning_renderer 读 finished 决定
  // 即使卡片整体 generating(isStreaming=true)也显示真实内容,而非「思考中」动画。
  static reasoning(text: string, seq: number, finished?: boolean): AggregateElement {
    return {
      type: "reasoning",
      element_id: `reasoning_${seq}`,
      data: { text, ...(finished !== undefined ? { finished } : {}) },
    }
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

  // 定位聚合卡内元素并增量更新(按 element_id 发 {op:"update", data:合并后全量})。
  // 与 PartDispatcher.appendElement / ToolCardManager.updateToolElement 同一串行队列
  // (state.aggregatePatchQueue)语义:更新排在其他 append/update 之后执行,
  // 读到的 state.aggregateElements 已含目标元素;并发更新不互相覆盖。
  // server update 是整体替换元素 data(非 merge),故 data 传本地合并后全量,
  // 否则 questions/input 等既有字段会丢。
  // silent 语义:显式 {silent:true} 恢复不响铃,{silent:false} 翻转计未读,
  // 经 {op:"set_silent"} 单独发(增量下 server 保留原值,无需每次携带)。
  // 元素缺失竞态(增量修复):registerTaskChildEarly 提前注册 childSessionTree 后,
  // 子 session 首事件触发的 working PATCH 可能早于聚合卡元素 append 落地(server
  // append 无 upsert,元素此刻尚未入卡)。此时不静默丢弃,把 patchData 缓存到
  // state.aggregatePendingUpdates,由 appendElement 落地后补发 update op——
  // 否则子 agent 卡片永久停在 starting。仅当目标元素从未出现(pending 永不消费)
  // 时兜底保持不 PATCH(server 对不存在元素 update 会 400,本地缓存兜底)。
  async updateElement(
    elementId: string,
    patchData: Record<string, unknown>,
    opts?: { silent?: boolean },
  ): Promise<void> {
    const prev = this.state.aggregatePatchQueue ?? Promise.resolve()
    const next = prev.then(async () => {
      const existed = (this.state.aggregateElements ?? []).some((e) => e.element_id === elementId)
      if (!existed) {
        // 元素未就绪:缓存 pending update,待 append 落地后补发(防 working 竞态丢失)。
        // 多次 update 合并(每次整体替换 data,合并字段),append 后一次补发。
        if (!this.state.aggregatePendingUpdates) this.state.aggregatePendingUpdates = new Map()
        const merged = {
          ...(this.state.aggregatePendingUpdates.get(elementId) ?? {}),
          ...patchData,
        }
        this.state.aggregatePendingUpdates.set(elementId, merged)
        return
      }
      const elements = (this.state.aggregateElements ?? []).map((e) =>
        e.element_id === elementId ? { ...e, data: { ...e.data, ...patchData } } : e,
      )
      this.state.aggregateElements = elements
      const target = elements.find((e) => e.element_id === elementId)
      if (!target) return
      const msgId = await this.ensureCard()
      await this.wanling.patchAggregateMessage(msgId, {
        op: "update",
        element_id: elementId,
        data: target.data,
      })
      if (opts?.silent !== undefined) {
        await this.wanling.patchAggregateMessage(msgId, { op: "set_silent", silent: opts.silent })
      }
    })
    // 队列吞掉前一次失败,保证后续追加不被坏 Promise 阻塞;next 本身仍向调用方传播错误。
    this.state.aggregatePatchQueue = next.catch(() => {})
    return next
  }

  // 聚合卡主动收尾定格:停止(abort)或新回合分段(interrupt)时,旧卡无 loop 结束
  // 的 step-finish footer 数据,由调用方主动补一个简化 footer + set_state done。
  // reason 区分:stop(用户点停止,APP 显示「已停止」)/ interrupt(新回合,无 stopped 标记)。
  // 幂等:整个收尾(守卫+append+reset)放入 aggregatePatchQueue 串行队列,与
  // step-finish 的 footer 定稿同队列顺序执行,消除与正常定稿的竞态:
  // - 正常定稿(step-finish stop)已排在前 → 卡已 done/reset → 此处守卫拦截
  // - 本收尾先执行 → step-finish 的 cardActive 判断看到 done → 跳过重复 footer
  // 收尾后 reset 聚合卡状态但保留 aggregateCardState="done":标志「本卡已收尾」,
  // 下一轮 ensureCard 建新卡时置回 generating("一次问答一张卡"语义)。
  async finishCard(reason: "stop" | "interrupt"): Promise<void> {
    const prev = this.state.aggregatePatchQueue ?? Promise.resolve()
    const next = prev.then(async () => {
      // 守卫在队列内读最新 state:卡已收尾(done)或尚未建卡 → 幂等跳过。
      if (this.state.aggregateCardState === "done") return
      if (!this.state.aggregateCardMsgId) return
      const seq = (this.state.aggregateSeq ?? 0) + 1
      this.state.aggregateSeq = seq
      const footer = AggregateCardManager.footer(
        { reason, stopped: reason === "stop", finished: true },
        seq,
      )
      // 直接 PATCH(不套 appendElement):本任务已排在队列尾部,前面所有元素
      // append/update 均已完成,直接追加 footer + set_state done,避免嵌套队列死锁。
      const msgId = this.state.aggregateCardMsgId
      await this.wanling.patchAggregateMessage(msgId, { op: "append", element: footer })
      await this.wanling.patchAggregateMessage(msgId, { op: "set_state", state: "done" })
      await this.wanling.patchAggregateMessage(msgId, { op: "set_silent", silent: false })
      this.state.aggregateElements = [...(this.state.aggregateElements ?? []), footer]
      // 收尾完成:标记 done + 清空建卡 msgId/序号/累计,让下一轮新建卡
      // (aggregateCardState 保留 done 直到 ensureCard 建新卡,供幂等守卫识别)。
      this.state.aggregateCardState = "done"
      this.state.aggregateCardMsgId = undefined
      this.state.aggregateCardInflight = undefined
      this.state.aggregateSeq = undefined
      this.state.aggregateElements = undefined
    })
    // 队列吞掉前一次失败,保证后续追加不被坏 Promise 阻塞;next 本身仍向调用方传播错误。
    this.state.aggregatePatchQueue = next.catch(() => {})
    return next
  }
}
