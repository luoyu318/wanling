import { randomUUID } from "crypto"
import { logger } from "../../utils/logger.js"
import type { EventEmitter } from "events"
import type {
  PartUpdatedPayload,
  PartDeltaPayload,
} from "../../opencode/subscriber.js"
import type { WanlingClient } from "../../wanling/client.js"
import type { SessionState } from "../types.js"
import type { SessionStore } from "../session_store.js"
import type { MessageRouter } from "../messaging.js"
import type { MetaSync } from "./meta_sync.js"
import type { CompactionTracker } from "./compaction.js"
import { AggregateCardManager, type AggregateElement } from "./aggregate_card.js"

// 流式 holder 类型:reasoning/text part 的累积状态(streamId/lastFlushAt/lastFlushedLen/flushTimer
// + 聚合卡元素预留序号 seq)。与 SessionState.reasoning/text 结构一致。
type StreamHolder = NonNullable<SessionState["reasoning"]>

// PartDispatcher:part_updated / part_delta 分发领域模块。
// 职责:reasoning / text / step-finish 三类 part 的状态机分发 + part_delta 增量
// 追加 + flush 缓冲(reasoning/text 兜底输出)+ reasoning/text 流式快照(300ms 节流)。
// tool/compaction case 不在此处:ToolCardManager 和 CompactionTracker 各自订阅 part_updated
// 事件按 part.type 自行过滤处理,本模块的 onPartUpdated switch 只保留 reasoning/text/step-finish。
// 聚合卡改造(Task 3):AGGREGATE_CARD_ENABLED=true(默认)时 reasoning/markdown/step_finish
// 不再发独立消息,而是追加到聚合卡(AggregateCardManager.appendElement 增量 append):
// reasoning 终态 → reasoning 元素;markdown 终态 → markdown 元素(缓存 pendingText 等
// step-finish 判定 silent);step_finish → footer 元素 + 整卡翻转 {set_silent:false,set_state:"done"}。
// 子 session 恒走旧独立消息(保持 parent/root 串树语义);流式 maybeFlushStream/forceFlushStream
// 保留 op=14(正文打字机体验,终态才上聚合卡),聚合模式下帧带 aggregate:{message_id, element_id}
// 指向聚合卡内正在流式的元素(避免 APP 建独立流式占位)。开关 false 时完全回退旧逻辑。
// 聚合卡元素序号(aggregateSeq)/累计(aggregateElements)/patch 串行队列(aggregatePatchQueue)
// 都在 SessionState 上维护,跨 manager 实例共享。不持有状态,错误经注入的 emitter 上抛。
// 流式元素定位(Task 3.5):聚合模式下 op=14 帧带 aggregate:{message_id, element_id} 指向聚合卡内
// 正在流式的元素。element_id 用"预留 seq"(streamSeq 首次推帧时取 nextSeq 并缓存到 holder),
// 流式期间所有帧 + 终态 append 用同一 element_id(APP 按 element_id 定位,若终态换号会导致
// 流式定位断裂 → 内容显示在错误元素)。无 aggregate 字段 = 非聚合模式,APP 走旧独立占位。
// holder.seq 即预留序号;reasoning/text holder 与 pendingText 的 seq 字段见 SessionState。
export class PartDispatcher {
  private readonly store: SessionStore
  private readonly router: MessageRouter
  private readonly metaSync: MetaSync
  private readonly compaction: CompactionTracker
  private readonly emitter: EventEmitter
  private readonly wanling: WanlingClient
  // 聚合卡开关:false 回退旧逐条发送(router.send)。默认 true。
  private readonly aggregateCardEnabled: boolean

  // 流式节流间隔:主 session reasoning/text 累积满 300ms 推一次 STREAM(op=14)全量快照。
  // 首块立即推(用户看到流式瞬间启动),后续 300ms 一次平衡 WS 帧数与流畅度。
  private static readonly FLUSH_INTERVAL_MS = 300

  constructor(deps: {
    store: SessionStore
    router: MessageRouter
    metaSync: MetaSync
    compaction: CompactionTracker
    emitter: EventEmitter
    wanling: WanlingClient
    aggregateCardEnabled?: boolean
  }) {
    this.store = deps.store
    this.router = deps.router
    this.metaSync = deps.metaSync
    this.compaction = deps.compaction
    this.emitter = deps.emitter
    this.wanling = deps.wanling
    this.aggregateCardEnabled = deps.aggregateCardEnabled ?? true
  }

  async onPartUpdated(payload: PartUpdatedPayload): Promise<void> {
    try {
      const state = await this.store.getOrCreateState(payload.sessionID)
      if (!state) return

      const part = payload.part

      // 流式补帧:收到非 reasoning/text 的 part_updated(tool/step-start 等,不含 step-finish)=
      // LLM 已切换走,该 part 的 delta 不会再来了。若 state.text/reasoning 还有未推完的
      // 累积值(被 300ms 节流跳过的最后几个 delta),强制补推一帧 op=14 全量快照,让 APP
      // 占位立即显示完整文本。不发终态(终态仍等 part_updated(time.end) 用 OC 权威值)。
      // 注:step-finish 不在此列——它要判定 isLoopEnd 决定 pendingText 的 silent,
      // 若在此强制 flush 会把缓存的最终回复以 silent=true 提前发掉,根治失效。
      if (part.type !== "reasoning" && part.type !== "text" && part.type !== "step-finish") {
        this.forceFlushStream(state, "reasoning")
        this.forceFlushStream(state, "text")
        // 消息顺序修复(tool/text 乱序根因):OC 的 part.updated(text, time.end) 会延迟到
        // 整个 LLM 响应阶段(含工具调用)结束才推。若 text 终态只等 end,markdown 会晚于
        // tool_card 落库,app 按 createdAt 排序显示成「思考→工具→文本」与 TUI 不一致。
        // LLM 已切走到 tool 等 part,当前 text/reasoning 的内容已完整,直接 flush 终态
        // (带 _stream_id 让 APP 替换占位);textPartsFlushed 标记防 OC 延迟推来的 end 重复发。
        this.flushReasoning(state)
        this.flushText(state)
      }

      switch (part.type) {
        case "reasoning":
          if (part.time?.end) {
            // idle 兜底(flushReasoning)可能已发走终态并标记 partID 到 textPartsFlushed。
            // 此时 OC 延迟推来的 part_updated(end) 到达,命中标记则跳过避免重复发终态
            // (否则两条相同消息都入库)。未命中(正常路径 / OC 攒批推送)则正常发。
            if (!state.textPartsFlushed.has(part.id)) {
              const text = part.text || ""
              const sid = state.reasoning?.streamId
              // 补推最后一帧流式(300ms 窗口漏推的尾部 delta),发终态前让 APP 占位补全。
              if (state.reasoning) this.forceFlushStream(state, "reasoning")
              if (text.trim()) {
                if (this.useAggregate(state)) {
                  // 流式已预留 seq 则复用(终态与流式帧同一 element_id),未流式走 nextSeq
                  // duration:思考耗时(part.time.end - start,**毫秒**,对齐 TUI reasoning
                  // header;TUI 用 Locale.duration 把 <1000ms 格式化为「22ms」,故不转秒,
                  // 否则 <100ms 的思考(如纯文本摘要)会被 round 成 0 丢失)。
                  const reasoningDuration = (() => {
                    const start = part.time?.start
                    const end = part.time?.end
                    if (typeof start === "number" && typeof end === "number" && end > start) {
                      return end - start
                    }
                    return undefined
                  })()
                  await this.appendElement(state, AggregateCardManager.reasoning(
                    text,
                    state.reasoning?.seq ?? this.nextSeq(state),
                    true,
                    reasoningDuration,
                  ))
                } else {
                  this.router.send(state, "reasoning",
                    sid && !state.isChildSession ? { text, _stream_id: sid } : { text }, true)
                }
              }
              state.reasoning = null
            }
          } else {
            // 记录 time.start 供 idle 兜底 flushReasoning 估算耗时(part.end 未到)
            state.reasoning = { text: part.text || "", partID: part.id, ...(typeof part.time?.start === "number" ? { timeStart: part.time.start } : {}) }
            this.store.indexPart(part.id, state)
          }
          break

        case "text":
          if (payload.skipUserText) break
          if (part.time?.end) {
            // idle 兜底(flushText)可能已发走终态并标记 partID 到 textPartsFlushed。
            // 此时 OC 延迟推来的 part_updated(end) 到达,命中标记则跳过避免重复发终态
            // (否则两条相同消息都入库)。未命中(正常路径 / OC 攒批推送)则正常发。
            if (!state.textPartsFlushed.has(part.id)) {
              const text = part.text || ""
              const sid = state.text?.streamId
              // 补推最后一帧流式(300ms 窗口漏推的尾部 delta),发终态前让 APP 占位补全。
              if (state.text) this.forceFlushStream(state, "text")
              // 根治(未读锚点=真实内容):text 终态缓存到 pendingText,不立即发。
              // 最终回复(step-finish isLoopEnd)以 silent=false 发(markdown 计未读),
              // 中间步骤以 silent=true 发。子 agent 文本恒 silent=true。
              if (text.trim()) {
                if (!state.isChildSession) {
                  // seq 透传:流式预留的聚合卡元素序号,终态 append 用同一 element_id
                  state.pendingText = { text, partID: part.id, streamId: sid, ...(state.text?.seq !== undefined ? { seq: state.text.seq } : {}) }
                } else {
                  this.router.send(state, "markdown",
                    sid ? { text, _stream_id: sid } : { text }, true)
                }
              }
              state.text = null
            }
          } else {
            // 新 text part 开始:若上一个 text 终态还缓存在 pendingText(未等来 step-finish),
            // 以 silent=true 立即发掉(不打扰),避免被新 part 覆盖丢失。
            if (state.pendingText) {
              this.flushPendingText(state, true)
            }
            state.text = { text: part.text || "", partID: part.id }
            this.store.indexPart(part.id, state)
          }
          break

        case "step-finish": {
          const startTime = part.time?.start
          const endTime = part.time?.end
          let duration = 0
          if (typeof startTime === "number" && typeof endTime === "number") {
            duration = (endTime - startTime) / 1000
          }
          // reason="stop" 且主 session = agent 循环真正结束的信号(opencode 语义)。
          // - silent=false → server 计未读 + bg-service 弹通知(承担响铃职责)
          // - finished=true → APP 渲染 tokens 汇总行
          // 主 session 中间步骤(reason!="stop")和子 session 所有 step-finish 保持 silent=true。
          const isLoopEnd = part.reason === "stop" && !state.isChildSession
          logger.info(`[streamer] step-finish session=${payload.sessionID.slice(0, 12)} isChild=${!!state.isChildSession} reason=${part.reason} isLoopEnd=${isLoopEnd} convId=${state.convId?.slice(0, 8)}`)
          // 根治(未读锚点=真实内容):step-finish 判定时把缓存的最终 text 终态发出。
          // - isLoopEnd(回合结束)→ silent=false,markdown 计未读成为未读锚点
          // - 非 isLoopEnd(中间步骤)→ silent=true,不打扰
          // 兜底:若 text 未走 end 缓存路径(异常时序,state.text 还在累积)先 silent=true 发掉。
          if (state.text) {
            const t = state.text
            state.text = null
            if (t.flushTimer) { clearTimeout(t.flushTimer) }
            if (this.useAggregate(state)) {
              const element = AggregateCardManager.markdown(t.text, t.seq ?? this.nextSeq(state))
              void this.appendElement(state, element).catch((err) => {
                this.emitter.emit("error", err instanceof Error ? err : new Error(String(err)))
              })
            } else {
              this.router.send(state, "markdown",
                t.streamId && !state.isChildSession ? { text: t.text, _stream_id: t.streamId } : { text: t.text }, true)
            }
          }
          this.flushPendingText(state, isLoopEnd ? false : true)
          if (!this.useAggregate(state)) {
            // 非聚合模式 step_finish 恒 silent=true:结束标记不响铃、不计未读、不作未读锚点。
            // 响铃/未读职责由最终文本(flushPendingText isLoopEnd → silent=false)承担,
            // 避免循环结束时两条消息各计一次未读、通知 body 被覆盖成「[完成]」。
            // finished=isLoopEnd 仍保留,APP 照常渲染 tokens 汇总行。
            this.router.send(state, "step_finish", {
              reason: part.reason || "",
              cost: part.cost || 0,
              tokens: part.tokens || {},
              duration,
              finished: isLoopEnd,
            }, true)
          } else if (isLoopEnd) {
            // 聚合模式:step-finish part 带 cost/tokens/reason 但无 time,暂存到
            // state.footerDraft,等 assistant_message_completed(带 completed)到达后由
            // streamer.finalizeCardForSession 合并成完整 footer(耗时 = completed - user.created)。
            // 幂等:同回合可能重推,覆盖为最新值即可。
            state.footerDraft = {
              reason: part.reason || "",
              cost: part.cost || 0,
              tokens: part.tokens || {},
            }
          }
          // 聚合模式:footer 不再在此追加——回合耗时要等 assistant message 的
          // completed 落库(subscriber 的 assistant_message_completed 事件,对齐 TUI
          // final() 判定),由 streamer.finalizeCardForSession 统一收尾(append footer +
          // set_state done + set_silent false + reset)。这里只负责内容/未读/meta。
          // 注意:若 completed 事件缺失(极端异常),onSessionIdle 兜底收尾。
          // 循环结束时主动同步 session_meta:agent 在跑期间 / 跑之前用户可能在 shell
          // 切了 git 分支(OC 不发 vcs.branch.updated),EnvMetaStrip 不刷新。
          // 读 knownFullMeta 缓存 cwd → vcs.get 拉最新 branch → updateSessionMeta。
          // await 而非 fire-and-forget:fetchGitBranch 内部 catch 错误,不会让
          // onPartUpdated 抛错;step_finish 消息已同步发送,后续 vcs.get 几十毫秒
          // 不影响用户看到完成提示。server 收到后广播 SESSION_META_UPDATE → APP 刷新。
          if (isLoopEnd) {
            const stepTokens = part.tokens as
              | { input?: number; output?: number; reasoning?: number; cache?: { read?: number; write?: number } }
              | undefined
            const contextUsed = (stepTokens?.input ?? 0) + (stepTokens?.cache?.read ?? 0)
            await this.metaSync.syncAfterLoopEnd(payload.sessionID, contextUsed)
            // compact 兜底:OC 1.18.3 实际只推一次 compaction part(早期 plan 抓包确认的
            // 「第二次同 partId 带 tail_start_id」在新版本不再出现),导致 case "compaction"
            // 的 seen.done 路径走不到,divider 永远停留在 running 态。
            // 用 step-finish isLoopEnd 作为兜底信号:同 session 有未完成 compaction → PATCH done。
            if (isLoopEnd) {
              await this.compaction.completePending(payload.sessionID)
            }
          }
          break
        }
      }
    } catch (err) {
      this.emitter.emit("error", err instanceof Error ? err : new Error(String(err)))
    }
  }

  onPartDelta(payload: PartDeltaPayload): void {
    if (payload.field !== "text") return

    const state = this.store.getPart(payload.partID)
    if (!state) return

    if (state.reasoning?.partID === payload.partID) {
      state.reasoning.text += payload.delta
      this.maybeFlushStream(state, "reasoning")
    } else if (state.text?.partID === payload.partID) {
      state.text.text += payload.delta
      this.maybeFlushStream(state, "text")
    } else {
      this.store.dropPart(payload.partID)
    }
  }

  // 流式节流:主 session 的 reasoning/text 累积满 FLUSH_INTERVAL_MS 推一次 STREAM(op=14)全量快照。
  // 首块立即推(用户看到流式瞬间启动),后续 300ms 一次。子 session 不流式(保持攒满发整条)。
  // streamId 惰性生成:避免空 part(只有 part_updated 无 delta)也建 stream。
  // 守卫用 trim:与终态 case "text"/case "reasoning" 的 `text.trim()` 口径一致,
  // 纯空白(如 OC 在 reasoning 后 / tool_use 前输出的 "\n\n")不建占位,否则终态因
  // trim 为空不发 MESSAGE_CREATE,占位无法被替换 → 永久滞留成空气泡。
  //
  // 尾部兜底定时器:delta 密集时(全在 300ms 窗口内到达),节流只推首块就更新 lastFlushAt,
  // 后续 delta 全跳过。之后 OC 可能数秒不推任何事件(reasoning end 要等整个 LLM 响应结束),
  // APP 占位卡在首块。定时器在 delta 停止 500ms 后兜底 forceFlush 补推完整累积值,
  // 对齐 TUI 的 delta 实时拼接体验。每次 delta 到达重置定时器(滑动窗口)。
  private static readonly FLUSH_TAIL_MS = 500

  private maybeFlushStream(state: SessionState, kind: "reasoning" | "text"): void {
    if (state.isChildSession) return
    const holder = kind === "reasoning" ? state.reasoning : state.text
    if (!holder || !holder.text.trim()) return
    if (!holder.streamId) {
      holder.streamId = randomUUID()
      holder.lastFlushAt = 0
    }
    // 重置尾部兜底定时器(滑动窗口:每个 delta 都把"无 delta 超时"推迟 500ms)
    if (holder.flushTimer) clearTimeout(holder.flushTimer)
    const now = Date.now()
    if (holder.lastFlushAt === 0 || now - (holder.lastFlushAt ?? 0) >= PartDispatcher.FLUSH_INTERVAL_MS) {
      this.pushStreamFrame(state, kind, holder)
      holder.lastFlushAt = now
      holder.lastFlushedLen = holder.text.length
    }
    // 设尾部兜底定时器:500ms 内若无新 delta,forceFlush 补推节流跳过的残留内容。
    // 箭头函数捕获 state/kind/holder,holder 可能在定时器触发前被终态置 null,
    // forceFlushStream 内部已有 holder 守卫(null 则 return)。
    holder.flushTimer = setTimeout(() => {
      this.forceFlushStream(state, kind)
    }, PartDispatcher.FLUSH_TAIL_MS)
  }

  // 强制补推流式帧:绕过 300ms 节流,把累积值全量推给 APP。
  // 触发时机:onPartUpdated 收到非 reasoning/text 类型(tool/step-start 等)=
  // LLM 已切换走,该 part 的 delta 不会再来,300ms 节流窗口内的残留 delta 需强制补推。
  // 仅在已有 streamId(APP 已建占位)且累积长度 > 上次推的长度(有新内容)时推,
  // 避免重复推相同内容。不清空 holder(终态仍等 part_updated(time.end))。
  private forceFlushStream(state: SessionState, kind: "reasoning" | "text"): void {
    if (state.isChildSession) return
    const holder = kind === "reasoning" ? state.reasoning : state.text
    if (!holder || !holder.streamId) return
    if (holder.flushTimer) { clearTimeout(holder.flushTimer); holder.flushTimer = undefined }
    if (holder.text.length <= (holder.lastFlushedLen ?? 0)) return
    this.pushStreamFrame(state, kind, holder)
    holder.lastFlushedLen = holder.text.length
  }

  // 推一帧 op=14 全量快照。聚合模式下 payload 附加 aggregate:{message_id, element_id}:
  // - element_id = 预留序号的 markdown/reasoning 元素(与终态 append 同一 element_id,APP 定位连续)
  // - message_id 需 ensureCard 异步拿(首次建卡走 REST),fire-and-forget 发送 + 失败 emit error,
  //   与 appendElement 的既有错误处理风格一致;流式帧为瞬态,建卡失败由终态 append 兜底报错
  // 非聚合模式不加 aggregate 字段(APP 走旧独立占位逻辑)。
  private pushStreamFrame(state: SessionState, kind: "reasoning" | "text", holder: StreamHolder): void {
    const prefix: "reasoning" | "markdown" = kind === "reasoning" ? "reasoning" : "markdown"
    const payload = {
      stream_id: holder.streamId as string,
      msg_type: prefix,
      text: holder.text,
    }
    if (!this.useAggregate(state)) {
      this.wanling.sendStream(state.convId, payload)
      return
    }
    const elementId = `${prefix}_${this.streamSeq(state, holder)}`
    const manager = new AggregateCardManager(this.wanling, state)
    void manager.ensureCard().then(async (messageId) => {
      // I1:流式首帧前先确保目标元素已 append 进聚合卡(占位),否则 APP 端
      // _applyAggregateStreamUpdate 因元素不存在丢弃帧 → 整个生成期无中间文本,
      // 直到 step-finish 才一次性出全文。占位元素 PATCH 落地后才发帧(帧能命中)。
      await this.ensureStreamElement(state, holder, prefix)
      this.wanling.sendStream(state.convId, { ...payload, aggregate: { message_id: messageId, element_id: elementId } })
    }).catch((err) => {
      this.emitter.emit("error", err instanceof Error ? err : new Error(String(err)))
    })
  }

  // I1 流式占位:把目标元素(reasoning/markdown,用 holder 预留 seq)append 进聚合卡。
  // aggregateStreamedElementIds 同步去重:并发首帧/后续帧到达时只占位一次,
  // 不会重复 append(否则同一 element_id 在卡里出现两次)。
  private async ensureStreamElement(
    state: SessionState,
    holder: StreamHolder,
    prefix: "reasoning" | "markdown",
  ): Promise<void> {
    if (holder.seq === undefined) return
    const elementId = `${prefix}_${holder.seq}`
    if (state.aggregateStreamedElementIds?.has(elementId)) return
    if (!state.aggregateStreamedElementIds) state.aggregateStreamedElementIds = new Set()
    state.aggregateStreamedElementIds.add(elementId)
    const element = prefix === "reasoning"
      ? AggregateCardManager.reasoning(holder.text, holder.seq, false)
      : AggregateCardManager.markdown(holder.text, holder.seq)
    await this.appendElement(state, element)
  }

  // 流式元素预留序号:首次推帧时取"下一个 seq"并缓存到 holder。
  // 之后流式期间所有帧与终态 append 复用 holder.seq,保证 element_id 稳定不随
  // 中途其他元素(如 tool_card / 中途 reasoning 终态)的 append 而漂移。
  private streamSeq(state: SessionState, holder: StreamHolder): number {
    if (holder.seq === undefined) holder.seq = this.nextSeq(state)
    return holder.seq
  }

  // flush 缓冲 reasoning(public 暴露:SessionLifecycle Task 8 单 session flush 调用)。
  flushReasoning(state: SessionState): void {
    if (!state.reasoning?.text.trim()) return
    // 清尾部兜底定时器(终态发出后不再需要补推)
    if (state.reasoning.flushTimer) { clearTimeout(state.reasoning.flushTimer); state.reasoning.flushTimer = undefined }
    // 发终态前先补推最后一帧流式(300ms 节流窗口内漏推的尾部 delta),
    // 让 APP 占位在终态替换前显示完整文本(对齐 TUI 的 delta 实时拼接)。
    this.forceFlushStream(state, "reasoning")
    const sid = state.reasoning.streamId
    if (this.useAggregate(state)) {
      // 思考耗时:flush 时 part.end 未到(LLM 已切走,reasoning 已完整),用 now - timeStart
      // 近似(误差 < 数百 ms,对齐 TUI reasoning duration,**毫秒**)。timeStart 缺失则省略。
      const flushDuration = (() => {
        const start = state.reasoning.timeStart
        if (typeof start === "number") {
          const ms = Date.now() - start
          if (ms > 0) return ms
        }
        return undefined
      })()
      const element = AggregateCardManager.reasoning(
        state.reasoning.text,
        state.reasoning.seq ?? this.nextSeq(state),
        true,
        flushDuration,
      )
      void this.appendElement(state, element).catch((err) => {
        this.emitter.emit("error", err instanceof Error ? err : new Error(String(err)))
      })
    } else {
      this.router.send(state, "reasoning",
        sid && !state.isChildSession ? { text: state.reasoning.text, _stream_id: sid } : { text: state.reasoning.text }, true)
    }
    state.textPartsFlushed.add(state.reasoning.partID)
    state.reasoning = null
  }

  flushText(state: SessionState): void {
    // 兜底:缓存的最终 text 终态(未等来 step-finish 判定)→ 以 silent=true 发掉,避免滞留。
    this.flushPendingText(state, true)
    if (!state.text?.text.trim()) return
    // 清尾部兜底定时器(终态发出后不再需要补推)
    if (state.text.flushTimer) { clearTimeout(state.text.flushTimer); state.text.flushTimer = undefined }
    // 发终态前先补推最后一帧流式(300ms 节流窗口内漏推的尾部 delta),
    // 让 APP 占位在终态替换前显示完整文本(对齐 TUI 的 delta 实时拼接)。
    this.forceFlushStream(state, "text")
    const sid = state.text.streamId
    if (this.useAggregate(state)) {
      const element = AggregateCardManager.markdown(state.text.text, state.text.seq ?? this.nextSeq(state))
      void this.appendElement(state, element).catch((err) => {
        this.emitter.emit("error", err instanceof Error ? err : new Error(String(err)))
      })
    } else {
      // I-P:子 agent 文本输出强制 silent=true(与 case "text" 同步口径)。
      this.router.send(state, "markdown",
        sid && !state.isChildSession ? { text: state.text.text, _stream_id: sid } : { text: state.text.text }, true)
    }
    state.textPartsFlushed.add(state.text.partID)
    state.text = null
  }

  // 把缓存的最终 text 终态(pendingText)发出。
  // silent 由调用方决定:step-finish isLoopEnd → false(计未读);其余兜底 → true。
  // 聚合卡模式下 silent 参数被忽略:markdown 元素追加时保持原卡 silent,
  // 最终回复的计未读由 step-finish 的整卡翻转 {silent:false} 承接。
  private flushPendingText(state: SessionState, silent: boolean): void {
    if (!state.pendingText) return
    const pt = state.pendingText
    state.pendingText = undefined
    if (this.useAggregate(state)) {
      const element = AggregateCardManager.markdown(pt.text, pt.seq ?? this.nextSeq(state))
      void this.appendElement(state, element).catch((err) => {
        this.emitter.emit("error", err instanceof Error ? err : new Error(String(err)))
      })
    } else {
      this.router.send(state, "markdown",
        pt.streamId ? { text: pt.text, _stream_id: pt.streamId } : { text: pt.text },
        silent)
    }
  }

  // 聚合卡是否对本 state 生效:开关开启且非子 session。
  // 子 session 的 reasoning/text/step_finish 恒走独立消息(保持 parent/root 串树语义,
  // 聚合卡上无法表达 child 层级)。
  private useAggregate(state: SessionState): boolean {
    return this.aggregateCardEnabled && !state.isChildSession
  }

  // 聚合卡元素序号计数器:reasoning/markdown/footer 共用,保证 element_id 全卡唯一递增。
  private nextSeq(state: SessionState): number {
    const seq = (state.aggregateSeq ?? 0) + 1
    state.aggregateSeq = seq
    return seq
  }

  // 追加聚合卡元素并 PATCH 增量 op(append;同 element_id 已存在则 update 原位替换)。
  // 队列(aggregatePatchQueue)/累计(aggregateElements)由 AggregateCardManager.appendElement
  // 统一维护,与 tool_card / interaction 共用同一串行队列,并发 flush 按序执行不覆盖。
  // opts 透传:opts.state → 单独 set_state op;opts.silent → 单独 set_silent op。
  // 返回 Promise 不吞错误:调用方 await 走外层 try/catch,fire-and-forget 处自行 catch emit。
  private appendElement(
    state: SessionState,
    element: AggregateElement,
    opts?: { silent?: boolean; state?: "generating" | "done" },
  ): Promise<void> {
    return new AggregateCardManager(this.wanling, state).appendElement(element, opts)
  }
}
