import { AggregateCard } from "@wanling/sdk"
import type { WanlingClient } from "../../wanling/client.js"
import type { SessionState } from "../types.js"

// 聚合卡 SDK 接线层(替代原自管 AggregateCardManager):
// 卡生命周期状态机(幂等建卡/串行 PATCH 队列/20 元素自动分卡/同 id append 自动
// update/未就绪 update 缓存补发/降级全量替换自愈/sealed 迟到 update 零流量)
// 全部由 SDK AggregateCard 承担;本模块只做 OC 侧编排:
//   - 元素构造器(element_id 规则 type_seq,OC 全卡共用计数器 state.aggregateSeq)
//   - append/update 后的附加 op(set_silent 翻转响铃,SDK 无公开入口,经 REST 直发)
//   - cardMessageId 捕获(SDK 不公开卡消息 id,而 op=14 流式帧 aggregate 定位
//     与 card_store 记账需要,经建卡 io 回调捕获——对齐 dsh TurnCardSession 模式)
//   - 回合边界清理(footer 收尾时清 aggregateSeq/流式占位 Set/工具元素映射,
//     对齐原 _sealCard 的跨轮 reset,seq 归零后 element_id 复用不受残留干扰)
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

// question_card 元素 data:对齐现有 question_card renderer 消费字段。
// 聚合模式下主 session question 已迁 SDK approvals.ask(独立审批卡),此类型仅供
// 非聚合回退路径(aggregateCardEnabled=false / 子 session)使用。
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

// permission_card 元素 data:对齐现有 permission_card renderer 消费字段。
// permission 路径本任务保留自管(工具审批迁移在 question 验证稳定后单独小步做)。
export type PermissionCardData = {
  oc_request_id: string
  action: string
  resources: string[]
  save?: string[]
  metadata?: Record<string, unknown>
  status?: string
  result?: string
}

// reasoning 元素构造器。finished 标记该思考链是否已终态(内容完整)——APP
// reasoning_renderer 读 finished 决定即使卡片整体 generating 也显示真实内容。
// duration 毫秒:思考耗时(part.time.end - start,对齐 TUI reasoning header),
// 仅终态(finished=true)且有实际耗时(>0)时携带。
export function reasoningElement(text: string, seq: number, finished?: boolean, duration?: number): AggregateElement {
  return {
    type: "reasoning",
    element_id: `reasoning_${seq}`,
    data: {
      text,
      ...(finished !== undefined ? { finished } : {}),
      ...(finished && typeof duration === "number" && duration > 0 ? { duration } : {}),
    },
  }
}

export function toolCardElement(data: ToolCardData, seq: number): AggregateElement {
  return { type: "tool_card", element_id: `tool_card_${seq}`, data }
}

export function markdownElement(text: string, seq: number): AggregateElement {
  return { type: "markdown", element_id: `markdown_${seq}`, data: { text } }
}

export function questionCardElement(data: QuestionCardData, seq: number): AggregateElement {
  return { type: "question_card", element_id: `question_card_${seq}`, data }
}

export function permissionCardElement(data: PermissionCardData, seq: number): AggregateElement {
  return { type: "permission_card", element_id: `permission_card_${seq}`, data }
}

// 聚合卡回合桥:每 SessionState 惰性持有一个实例(state.aggregateCard),
// 跨 manager 调用点(part_dispatcher/tool_card/interaction/session_store/streamer)
// 共享同一 SDK AggregateCard(串行队列/镜像/归属映射在 SDK 实例内不丢)。
export class AggregateCardBridge {
  // 当前卡消息 id:建卡 io 回调捕获(含分卡续卡自动跟随);undefined = 本回合未建卡。
  // public 可写:tool_card 的 task 提前注册测试需要模拟「卡已存在」场景。
  cardMessageId: string | undefined
  // 本回合是否已收尾(finishCard/finalizeCard 置 true;下一次 append 视为新回合翻回)。
  // 对齐原 state.aggregateCardState === "done" 的幂等守卫语义。
  sealed = false
  readonly card: AggregateCard
  // 元素归属卡映射(append 时记录,收尾清空):interaction 反向流/孤儿清理的
  // 跨轮防护(映射未命中 = 真跨轮 element_id 复用,跳过防误更新新卡)。
  readonly elementCardIds = new Map<string, string>()

  constructor(
    private readonly wanling: WanlingClient,
    private readonly state: SessionState,
  ) {
    this.card = new AggregateCard(state.convId, {
      // silent 建卡(回合进行中不打扰,计未读由 finish 翻转 set_silent 承接);
      // 同时捕获卡消息 id 供 op=14 流式 aggregate 定位/card_store 记账。
      sendCard: async (data) => {
        const messageId = await this.wanling.sendCardMessage(this.state.convId, data.msg_type, data.data, { silent: true })
        this.cardMessageId = messageId
        return messageId
      },
      patch: (messageId, op) => this.wanling.patchAggregateMessage(messageId, op),
      updateContent: (messageId, content) => this.wanling.updateMessageContent(messageId, content),
    }, { degradedSelfHeal: true })
  }

  // 追加元素(SDK append:同 element_id 已存在自动改发 update 原位替换)。
  // opts.silent !== undefined → append 后单独发 set_silent op(pending 交互传
  // false 响铃/回答后恢复 true;SDK 无公开入口,经 REST 直发,顺序在 append 之后)。
  async appendElement(
    element: AggregateElement,
    opts?: { silent?: boolean },
  ): Promise<void> {
    // sealed 后 append = 新回合(SDK ensureCard 内部 resetRound 重建卡),
    // 翻回活跃态。本回合未建卡(cardMessageId undefined)由 SDK 首次建卡。
    this.sealed = false
    // data 内携带 type/element_id(SDK AggregateElement 入参形态),SDK append 内部
    // 会拆出 element_id 生成 wire 元素,type 字段被剔除不进 data。
    await this.card.append(element.type, { type: element.type, element_id: element.element_id, ...element.data })
    // 记录元素归属卡:append 落地后的当前卡即归属卡(分卡切卡由 SDK 内部完成,
    // cardMessageId 已随建卡回调更新),供反向流/孤儿清理定位。
    if (this.cardMessageId) {
      this.elementCardIds.set(element.element_id, this.cardMessageId)
    }
    if (opts?.silent !== undefined && this.cardMessageId) {
      await this.wanling.patchAggregateMessage(this.cardMessageId, { op: "set_silent", silent: opts.silent })
    }
  }

  // 更新元素 data(SDK update:当前卡元素与本地镜像合并发全量;分卡旧卡元素按
  // 归属映射 PATCH 旧卡——此时调用方需传全量 data;元素未就绪缓存待 append 补发;
  // sealed 后迟到 update 走 pending 缓存零 wire 流量)。
  // opts.silent !== undefined → 对元素归属卡单独发 set_silent(回答后恢复响铃)。
  async updateElement(
    elementId: string,
    patchData: Record<string, unknown>,
    opts?: { silent?: boolean },
  ): Promise<void> {
    await this.card.update(elementId, patchData)
    if (opts?.silent !== undefined) {
      const ownerCard = this.elementCardIds.get(elementId) ?? this.cardMessageId
      if (ownerCard) {
        await this.wanling.patchAggregateMessage(ownerCard, { op: "set_silent", silent: opts.silent })
      }
    }
  }

  // 聚合卡主动收尾定格:停止(abort)或新回合分段(interrupt)时,旧卡补简化
  // footer + set_state done + set_silent false。幂等(已收尾/未建卡跳过)。
  // stopped 标记仅 stop(用户点停止,APP 显示「已停止」),interrupt 无标记。
  async finishCard(reason: "stop" | "interrupt"): Promise<void> {
    if (this.sealed || !this.cardMessageId) return
    await this.card.finish(reason === "stop" ? { reason: "stop", stopped: true } : { reason: "interrupt" })
    this.sealRound()
  }

  // 回合正常结束的完整收尾(assistant_message_completed 事件驱动):
  // footer 带完整 duration(毫秒,SDK 映射 wire duration)/cost/tokens/mode/model。
  // 幂等:被 finishCard(abort/分段)先收尾时此处静默跳过。
  async finalizeCard(data: {
    reason: string
    duration: number
    cost?: number
    tokens?: Record<string, unknown>
    mode?: string
    model?: string
  }): Promise<void> {
    if (this.sealed || !this.cardMessageId) return
    await this.card.finish({
      reason: data.reason,
      cost: data.cost || 0,
      tokens: data.tokens || {},
      durationMs: data.duration,
      ...(data.mode ? { mode: data.mode } : {}),
      ...(data.model ? { model: data.model } : {}),
    })
    this.sealRound()
  }

  // 回合收尾后的跨轮 reset(对齐原 _sealCard):seq 归零(下一轮 element_id 从 1
  // 重计)、流式占位 Set 清空(否则跨轮首条 thinking 占位被残留阻塞)、工具元素
  // 映射清空、归属映射清空(真跨轮回传由映射未命中守卫拦下)。
  private sealRound(): void {
    this.sealed = true
    this.state.aggregateSeq = undefined
    this.state.aggregateStreamedElementIds = undefined
    this.state.aggregateToolElementIds = undefined
    this.elementCardIds.clear()
  }
}

// 取 state 的聚合卡桥(惰性建,跨调用点共享单例):原 AggregateCardManager
// 「每次调用 new 一个、状态挂 state」的模式改为桥实例常驻 state,SDK 卡状态
// (队列/镜像/归属)不再散落 SessionState 字段。
export function getAggregateCard(state: SessionState, wanling: WanlingClient): AggregateCardBridge {
  state.aggregateCard ??= new AggregateCardBridge(wanling, state)
  return state.aggregateCard
}
