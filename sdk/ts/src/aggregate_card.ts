import type { AggregatePatchOp } from "./rest.js"

// 聚合卡元素入参:type 由 append 第一参数给定,其余字段进元素 data;
// 可选携带 element_id(同 id 重复 append 自动改发 update,server append 无 upsert)。
export interface AggregateElement {
  type: string
  [key: string]: unknown
}

// footer 元素入参:durationMs 映射协议字段 duration(毫秒);其余字段透传
// (tokens/model/reason 等,见 docs/ai-handbook/aggregate-card.md footer 行)。
export interface AggregateFooter {
  // token 用量 map(wire 为对象而非数值:input/output/cache.read 等键,
  // opencode 发送含嵌套 cache {read,write},hermes 侧为 Dict[str,Any])。
  tokens?: Record<string, unknown>
  durationMs?: number
  model?: string
  [key: string]: unknown
}

export interface AggregateCardOptions {
  /** PATCH 连续失败 3 次后降级为全量替换自愈(hermes degraded,默认开)。 */
  degradedSelfHeal?: boolean
  /** finish 时无实际内容元素则撤回删卡(hermes 空卡清理,默认关;需 io.recall 通道)。 */
  recallEmpty?: boolean
}

// 分卡上限:单卡元素数达 20 时追加新元素前自动开新卡(中间卡收尾不写 footer,
// 只有最后一张卡 finish 写 footer + 翻 silent 计未读)。与 plugin 侧
// MAX_AGGREGATE_ELEMENTS_PER_CARD 保持一致,硬性约束单卡 content 体积。
const MAX_ELEMENTS = 20

// 聚合卡协议 schema 版本,建卡全量 content 携带(缺失视为 1)。
const AGGREGATE_SCHEMA_VER = 1

// 卡内元素的 wire 形态(server 存储/广播格式:{type, element_id, data})。
interface WireElement {
  type: string
  element_id: string
  data: Record<string, unknown>
}

/**
 * 聚合卡高层封装:一次问答一张卡 — 建卡幂等(inflight 缓存防并发双卡)、
 * PATCH 串行队列(吞前次失败防坏链)、同 element_id append 自动改 update、
 * 20 元素自动分卡(set_segment first/middle/last + 跨卡归属映射)、
 * 未就绪元素 update 缓存补发、连续失败降级全量替换自愈(可选)。
 * 状态机对照 plugin/opencode-plugin sync/domains/aggregate_card.ts 迁移,
 * 接口面向 SDK 调用方(io 构造注入,不依赖 client)。
 */
export class AggregateCard {
  // 当前卡消息 id(空串 = 未建卡/已收尾待重建)
  private messageId = ""
  // 建卡请求飞行缓存:并发首调共享同一 Promise,只发一次建卡(防双卡)
  private inflight: Promise<void> | null = null
  // PATCH 串行队列:所有增量 op 按入队顺序执行,前次失败被吞不坏链
  private patchQueue: Promise<unknown> = Promise.resolve()
  // 跨卡归属映射:element_id → 所在卡 id(分卡后旧卡元素 update 仍定位旧卡)
  private elementCardIds = new Map<string, string>()
  // 未就绪元素的 update 缓存:append 落地后合并补发(多次 update 字段合并)
  private pendingUpdates = new Map<string, Record<string, unknown>>()
  // PATCH 连续失败计数(成功清零;连续 3 次且开启自愈 → 降级全量替换)
  private failureCount = 0
  // 本回合收尾标记:finish/interrupt 幂等守卫;再 append 视为新回合重置
  private sealed = false
  // 当前卡本地影子镜像:分卡计数 / 同 id 检测 / update 合并 / 降级全量替换兜底
  private mirror: WireElement[] = []
  // 分卡序号:0=首卡,>0 已切卡;旧卡收尾时按序号打 first/middle,新卡建卡带 last
  private segmentIndex = 0
  // 当前卡 data.segment 标记(降级全量替换时随影子副本携带)
  private currentSegment: "first" | "middle" | "last" | undefined
  // 当前卡状态(降级全量替换时随影子副本携带)
  private cardState: "generating" | "done" = "generating"
  private footerSeq = 0

  constructor(
    private readonly convId: string,
    private readonly io: {
      sendCard: (data: { msg_type: string; data: Record<string, unknown> }) => Promise<string>
      patch: (messageId: string, op: AggregatePatchOp) => Promise<unknown>
      updateContent: (messageId: string, content: { msg_type: string; data: Record<string, unknown>; silent?: boolean }) => Promise<unknown>
      recall?: (messageId: string) => Promise<void>
    },
    private readonly opts: AggregateCardOptions = {},
  ) {}

  // 串行队列:fn 排在先前所有 op 之后执行;队列本身吞掉前次失败(防坏链),
  // fn 自身的错误仍向调用方传播。
  private enqueue<T>(fn: () => Promise<T>): Promise<T> {
    const next = this.patchQueue.then(fn, fn)
    this.patchQueue = next.then(() => undefined, () => undefined)
    return next
  }

  // 建卡幂等:已有卡直接返回;建卡飞行中共享 inflight 防并发双卡;
  // 收尾(sealed)后再调用 = 新回合,重置跨轮瞬态后建新卡(一次问答一张卡)。
  private ensureCard(): Promise<void> {
    if (this.sealed) this.resetRound()
    if (this.messageId !== "") return Promise.resolve()
    this.inflight ??= this.enqueue(async () => {
      // 队列内二次确认:分卡流程可能已在先行任务里建好新卡
      if (this.messageId === "") await this.createCard()
    })
    return this.inflight
  }

  // 直接建卡(仅在串行队列内调用,顺序由队列保证):
  // 分卡续卡(segmentIndex>0)的新卡带 segment "last"(当前为序列末卡,
  // 若后续再切卡,旧卡 sealIntermediateCard 会 set_segment 覆盖为 middle)。
  private async createCard(): Promise<void> {
    this.messageId = await this.io.sendCard({
      msg_type: "aggregate_card",
      data: {
        schema_ver: AGGREGATE_SCHEMA_VER,
        state: "generating",
        elements: [],
        ...(this.segmentIndex > 0 ? { segment: "last" } : {}),
      },
    })
    this.cardState = "generating"
    this.currentSegment = this.segmentIndex > 0 ? "last" : undefined
  }

  // 跨轮重置:清空上一回合全部瞬态(归属映射/pending/分卡序号/镜像),
  // 对齐 opencode _sealCard 收尾 reset——seq 归零后 element_id 复用不受残留干扰。
  private resetRound(): void {
    this.sealed = false
    this.messageId = ""
    this.inflight = null
    this.mirror = []
    this.elementCardIds.clear()
    this.pendingUpdates.clear()
    this.segmentIndex = 0
    this.currentSegment = undefined
    this.cardState = "generating"
    this.footerSeq = 0
  }

  /**
   * 追加元素。data 可选携带 element_id:与卡内已有元素同 id 时自动改发
   * update(原位替换,server append 无 upsert,直接 append 会出双元素)。
   * 返回最终 element_id(未携带时自动生成)。
   */
  async append(type: string, data: AggregateElement): Promise<{ id: string }> {
    await this.ensureCard()
    // 拆出显式 element_id;调用方按类型约束携带的 type 字段剔除(以第一参数为准)
    const explicitId = typeof data.element_id === "string" ? data.element_id : undefined
    const elementData: Record<string, unknown> = { ...data }
    delete elementData.element_id
    delete elementData.type
    const elementId = explicitId ?? crypto.randomUUID()
    const element: WireElement = { type, element_id: elementId, data: elementData }
    return this.enqueue(async () => {
      const existed = this.mirror.some((e) => e.element_id === elementId)
      // 分卡:追加新元素(非原位替换)且当前卡已满 → 先收尾旧卡再建新卡。
      // 切卡在串行队列内,与元素追加同序执行,不会并发开卡。
      if (!existed && this.mirror.length >= MAX_ELEMENTS) {
        await this.sealIntermediateCard()
        this.segmentIndex++
      }
      if (this.messageId === "") await this.createCard()
      // 影子镜像先落地(降级全量替换的副本需含本元素);建卡成功后再入镜像,
      // 避免建卡失败时镜像与卡内容漂移
      this.mirror = existed
        ? this.mirror.map((e) => (e.element_id === elementId ? element : e))
        : [...this.mirror, element]
      // 记录元素归属卡:分卡后旧卡元素 update 仍能定位(仅新 append 记录)
      if (!existed) this.elementCardIds.set(elementId, this.messageId)
      await this.tryPatch(
        existed
          ? { op: "update", element_id: elementId, data: element.data }
          : { op: "append", element },
      )
      // 竞态补发:append 前缓存的 pending update(update 早于元素就绪到达),
      // 合并进元素 data 后补发,避免元素永卡初始态。
      const buffered = this.pendingUpdates.get(elementId)
      if (buffered !== undefined) {
        this.pendingUpdates.delete(elementId)
        const merged = { ...element.data, ...buffered }
        this.mirror = this.mirror.map((e) => (e.element_id === elementId ? { ...e, data: merged } : e))
        await this.tryPatch({ op: "update", element_id: elementId, data: merged })
      }
      return { id: elementId }
    })
  }

  /**
   * 更新元素 data。当前卡元素:与本地镜像合并后发全量(server update 是
   * 整体替换而非 merge)。分卡后旧卡元素:经归属映射直接 PATCH 旧卡。
   * 元素未就绪(尚未 append):缓存待 append 落地后补发(多次 update 字段合并)。
   * 本方法不建卡(建卡是 append/finish 的职责,对齐 opencode updateElement:
   * 未就绪元素走 pending 缓存零 wire 流量)。
   */
  async update(elementId: string, data: Record<string, unknown>): Promise<void> {
    await this.enqueue(async () => {
      // sealed 后迟到 update(finish/interrupt 已收尾,如用户停止后工具终态):
      // 守卫在队列内读最新态,不触发 ensureCard 的 resetRound/建新卡(防孤儿
      // generating 卡)、不 PATCH 已收尾卡 —— 走 pending 缓存零 wire 流量,
      // 对齐 opencode 语义(缓存由下一轮 resetRound 清空,不跨轮泄漏)。
      if (this.sealed) {
        this.pendingUpdates.set(elementId, { ...(this.pendingUpdates.get(elementId) ?? {}), ...data })
        return
      }
      const target = this.mirror.find((e) => e.element_id === elementId)
      if (target !== undefined) {
        const merged = { ...target.data, ...data }
        this.mirror = this.mirror.map((e) => (e.element_id === elementId ? { ...e, data: merged } : e))
        await this.tryPatch({ op: "update", element_id: elementId, data: merged })
        return
      }
      // 分卡跨卡定位:归属映射命中旧卡 → 直接 PATCH 旧卡(旧卡无本地镜像,
      // 调用方需传全量 data,与 server 整体替换语义一致)
      const ownerCard = this.elementCardIds.get(elementId)
      if (ownerCard !== undefined && ownerCard !== this.messageId) {
        await this.io.patch(ownerCard, { op: "update", element_id: elementId, data })
        return
      }
      // 元素未就绪:缓存 pending(合并既有缓存),append 落地后一次补发
      this.pendingUpdates.set(elementId, { ...(this.pendingUpdates.get(elementId) ?? {}), ...data })
    })
  }

  /**
   * 回合收尾:追加 footer(durationMs 映射 duration,finished=true)
   * + set_state done + set_silent false(翻转计未读)。幂等:重复调用跳过。
   * recallEmpty 开启且无实际内容元素时撤回删卡(需 io.recall,缺省退化为
   * 无 footer 定格 done 不响铃)。
   */
  async finish(footer: AggregateFooter): Promise<void> {
    if (this.sealed) return
    await this.ensureCard()
    await this.enqueue(async () => {
      // 守卫在队列内读最新态:并发的重复 finish 只收尾一次
      if (this.sealed || this.messageId === "") return
      if (this.recallEmptyCard()) {
        if (this.io.recall !== undefined) {
          await this.io.recall(this.messageId)
        } else {
          this.cardState = "done"
          await this.tryPatch({ op: "set_state", state: "done" })
        }
        this.sealed = true
        return
      }
      const { durationMs, ...rest } = footer
      const footerData: Record<string, unknown> = {
        ...rest,
        finished: true,
        ...(durationMs !== undefined ? { duration: durationMs } : {}),
      }
      this.footerSeq++
      const element: WireElement = { type: "footer", element_id: `footer_${this.footerSeq}`, data: footerData }
      this.mirror = [...this.mirror, element]
      await this.tryPatch({ op: "append", element })
      this.cardState = "done"
      await this.tryPatch({ op: "set_state", state: "done" })
      await this.tryPatch({ op: "set_silent", silent: false })
      this.sealed = true
    })
  }

  /** 用户断卡收尾:与 finish 同语义,footer 标记 reason=interrupt(APP 显示回合被打断)。 */
  async interrupt(): Promise<void> {
    await this.finish({ reason: "interrupt" })
  }

  // PATCH 失败计数:连续 3 次且 degradedSelfHeal(默认开)→ 先经无 op 全量替换
  // 把影子副本整体推 server 收敛(hermes degraded 自愈),append 改写为幂等
  // update(全量已含新元素,防重复)后重试一次;任一 patch 成功即清零计数。
  private async tryPatch(op: AggregatePatchOp): Promise<void> {
    try {
      await this.io.patch(this.messageId, op)
      this.failureCount = 0
    } catch (e) {
      this.failureCount++
      if (!((this.opts.degradedSelfHeal ?? true) && this.failureCount >= 3)) throw e
      await this.degradedReplace()
      const retry: AggregatePatchOp = op.op === "append"
        ? { op: "update", element_id: op.element.element_id, data: op.element.data }
        : op
      await this.io.patch(this.messageId, retry)
      this.failureCount = 0
    }
  }

  // 降级全量替换:当前卡影子副本(elements + state + segment)经 updateContent
  // 整体推 server,收敛增量与全量的差异(silent 由 server 全量替换路径保留原值)。
  private async degradedReplace(): Promise<void> {
    await this.io.updateContent(this.messageId, {
      msg_type: "aggregate_card",
      data: {
        schema_ver: AGGREGATE_SCHEMA_VER,
        state: this.cardState,
        elements: this.mirror,
        ...(this.currentSegment !== undefined ? { segment: this.currentSegment } : {}),
      },
      silent: true,
    })
  }

  // 中间卡收尾(分卡用):旧卡 set_state done + set_segment(first/middle)定格,
  // 不写 footer、不翻 silent(中间卡空态),清当前卡累计让下一元素建新卡;
  // 保留归属映射(旧卡元素 update 仍定位旧卡)。
  private async sealIntermediateCard(): Promise<void> {
    if (this.messageId === "") return
    this.currentSegment = this.segmentIndex === 0 ? "first" : "middle"
    this.cardState = "done"
    await this.tryPatch({ op: "set_state", state: "done" })
    await this.tryPatch({ op: "set_segment", segment: this.currentSegment })
    this.messageId = ""
    this.inflight = null
    this.mirror = []
    this.currentSegment = undefined
  }

  // 空卡判定:recallEmpty 开启且本回合从未成功 append 过内容元素。
  private recallEmptyCard(): boolean {
    return (this.opts.recallEmpty ?? false) && this.elementCardIds.size === 0
  }
}
