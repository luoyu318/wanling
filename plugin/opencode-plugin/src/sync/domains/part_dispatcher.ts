import { StreamSession } from "@wanling/sdk"
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
import { getAggregateCard, reasoningElement, markdownElement, type AggregateElement } from "./aggregate_bridge.js"

// 流式 holder 类型:reasoning/text part 的累积状态(text/partID + SDK StreamSession
// 流式会话 + 聚合卡元素预留序号 seq)。与 SessionState.reasoning/text 结构一致。
type StreamHolder = NonNullable<SessionState["reasoning"]>

// PartDispatcher:part_updated / part_delta 分发领域模块。
// 职责:reasoning / text / step-finish 三类 part 的状态机分发 + part_delta 增量
// 追加 + flush 缓冲(reasoning/text 兜底输出)+ reasoning/text 流式快照。
// 流式会话(Task 8 迁移 SDK):节流(首帧立即/300ms 间隔)与尾部兜底由 SDK
// StreamSession 承担,本模块只做 holder 累积 + 惰性建会话 + 终态收口:
//   - 聚合模式:占位元素 append(REST)落地后才建会话(帧带 aggregate 定位,
//     element_id 与终态 append 同一预留 seq,APP 定位连续);飞行中 delta 只累积,
//     建会话时以全量快照种子化(协议语义:帧是累积全量快照)。
//   - 非聚合模式:同步建会话首帧立即(保持旧 sendStream 同步语义)。
//   - 终态(endStream = session.end):清 SDK 兜底定时器并 flush 余量;终态消息/
//     元素由调用方带 _stream_id / element_id 发,finalText 不经流式通道。
// 子 session 恒不流式(保持攒满发整条 + parent/root 串树语义)。
// tool/compaction case 不在此处:ToolCardManager 和 CompactionTracker 各自订阅 part_updated
// 事件按 part.type 自行过滤处理,本模块的 onPartUpdated switch 只保留 reasoning/text/step-finish。
// 聚合卡(Task 8 迁移 SDK):AGGREGATE_CARD_ENABLED=true(默认)时 reasoning/markdown/step_finish
// 不再发独立消息,而是经 aggregate_bridge 追加到 SDK AggregateCard:
// reasoning 终态 → reasoning 元素;markdown 终态 → markdown 元素(缓存 pendingText 等
// step-finish 判定 silent);step_finish → footerDraft 暂存(completed 事件收尾)。
// 元素序号(aggregateSeq)/流式占位 Set 在 SessionState 上维护,跨模块共享。
// 不持有状态,错误经注入的 emitter 上抛。
export class PartDispatcher {
  private readonly store: SessionStore
  private readonly router: MessageRouter
  private readonly metaSync: MetaSync
  private readonly compaction: CompactionTracker
  private readonly emitter: EventEmitter
  private readonly wanling: WanlingClient
  // 聚合卡开关:false 回退旧逐条发送(router.send)。默认 true。
  private readonly aggregateCardEnabled: boolean

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
      // LLM 已切换走,该 part 的 delta 不会再来了。收口流式会话(SDK end:flush 节流
      // 窗口内漏推的尾部 delta),让 APP 占位立即显示完整文本。不发终态(终态仍等
      // part_updated(time.end) 用 OC 权威值)。
      // 注:step-finish 不在此列——它要判定 isLoopEnd 决定 pendingText 的 silent,
      // 若在此强制收口会把缓存的最终回复以 silent=true 提前发掉,根治失效。
      if (part.type !== "reasoning" && part.type !== "text" && part.type !== "step-finish") {
        this.endStream(state, "reasoning")
        this.endStream(state, "text")
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
              // 收口流式会话(SDK end:flush 尾部余量),发终态前让 APP 占位补全。
              if (state.reasoning) this.endStream(state, "reasoning")
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
                  await this.appendElement(state, reasoningElement(
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
              // 收口流式会话(SDK end:flush 尾部余量),发终态前让 APP 占位补全。
              if (state.text) this.endStream(state, "text")
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
            // 关闭流式会话不 flush 尾帧:终态 markdown 紧随其后(APP 按 _stream_id/
            // element_id 定位替换),尾帧冗余,对齐旧实现 clear 定时器不补推的语义。
            t.stream?.abort()
            if (this.useAggregate(state)) {
              const element = markdownElement(t.text, t.seq ?? this.nextSeq(state))
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
      this.pushStreamDelta(state, "reasoning", payload.delta)
    } else if (state.text?.partID === payload.partID) {
      state.text.text += payload.delta
      this.pushStreamDelta(state, "text", payload.delta)
    } else {
      this.store.dropPart(payload.partID)
    }
  }

  // 流式 delta 推送(SDK StreamSession 接线):
  // - 会话已建 → session.push(delta)(首帧立即/300ms 节流/尾部兜底由 SDK 承担)。
  // - 未建会话 → 惰性创建。守卫用 trim:与终态 case 的 `text.trim()` 口径一致,
  //   纯空白(如 OC 在 reasoning 后 / tool_use 前输出的 "\n\n")不建占位,否则终态因
  //   trim 为空不发 MESSAGE_CREATE,占位无法被替换 → 永久滞留成空气泡。
  //   - 非聚合模式:同步建会话 + 全量种子 push(保持旧 sendStream 首帧立即语义)。
  //   - 聚合模式:占位 append(REST)落地后才建会话(帧带 aggregate 定位且能命中),
  //     经 streamEnsure 防并发双建;飞行中的 delta 只累积在 holder.text,建会话时
  //     以 holder.text 全量种子化(协议语义:帧是累积全量快照,不丢不重)。
  // 子 session 不流式(保持攒满发整条 + parent/root 串树语义)。
  private pushStreamDelta(state: SessionState, kind: "reasoning" | "text", delta: string): void {
    if (state.isChildSession) return
    const holder = kind === "reasoning" ? state.reasoning : state.text
    if (!holder) return
    if (holder.stream) {
      holder.stream.push(delta)
      return
    }
    if (!holder.text.trim()) return
    if (this.useAggregate(state)) {
      // 防并发双建(首帧占位 REST 飞行中后续 delta 只累积);失败清句柄允许重试
      // 并 emit error(流式为瞬态,终态 append 兜底)。
      if (!holder.streamEnsure) {
        holder.streamEnsure = this.ensureAggregateStream(state, kind, holder).catch((err) => {
          holder.streamEnsure = undefined
          this.emitter.emit("error", err instanceof Error ? err : new Error(String(err)))
        })
      }
      return
    }
    this.attachStreamSession(state, kind, holder).push(holder.text)
  }

  // 挂载 SDK 流式会话到 holder(发送经 wanling.sendStream,op=14 全量快照)。
  // aggregate 定位(聚合模式):帧指向聚合卡内占位元素,APP 不建独立流式占位。
  // 返回 session:调用方拿返回值 push(TS 对 holder.stream 的跨函数收窄不可见)。
  private attachStreamSession(
    state: SessionState,
    kind: "reasoning" | "text",
    holder: StreamHolder,
    aggregate?: { messageId: string; elementId: string },
  ): StreamSession {
    const msgType = kind === "reasoning" ? "reasoning" : "markdown"
    const session = new StreamSession(
      state.convId,
      (convId, frame) => this.wanling.sendStream(convId, frame as { stream_id: string; msg_type: string; text: string; aggregate?: { message_id: string; element_id: string } }),
      { msgType, ...(aggregate !== undefined ? { aggregate } : {}) },
    )
    holder.stream = session
    holder.streamId = session.streamId
    return session
  }

  // 聚合模式建流式会话(异步):先取预留 seq → 占位元素 append 进聚合卡
  // (I1:占位 PATCH 落地后帧才能命中,否则 APP 端 _applyAggregateStreamUpdate 因
  // 元素不存在丢弃帧 → 整个生成期无中间文本)→ 建会话(aggregate 定位指向
  // 占位元素)→ 全量种子 push。
  private async ensureAggregateStream(
    state: SessionState,
    kind: "reasoning" | "text",
    holder: StreamHolder,
  ): Promise<void> {
    const prefix = kind === "reasoning" ? "reasoning" : "markdown"
    const seq = this.streamSeq(state, holder)
    const elementId = `${prefix}_${seq}`
    // 同步去重:并发首帧只占位一次(占位 append 携带当前累积文本)
    if (!state.aggregateStreamedElementIds) state.aggregateStreamedElementIds = new Set()
    if (!state.aggregateStreamedElementIds.has(elementId)) {
      state.aggregateStreamedElementIds.add(elementId)
      const element = prefix === "reasoning"
        ? reasoningElement(holder.text, seq, false)
        : markdownElement(holder.text, seq)
      await this.appendElement(state, element)
    }
    const bridge = getAggregateCard(state, this.wanling)
    if (!bridge.cardMessageId) {
      throw new Error("aggregate stream: 聚合卡 message id 不可用(建卡未完成)")
    }
    this.attachStreamSession(state, kind, holder, { messageId: bridge.cardMessageId, elementId })
    holder.stream?.push(holder.text)
  }

  // 收口流式会话:flush=true(SDK end,清兜底定时器并 flush 余量,发终态前让
  // APP 占位补全)或 flush=false(SDK abort,丢弃尾帧——终态紧随其后,替换占位)。
  // holder.streamId 保留(终态消息/元素定位复用),会话关闭后 push 不再生效。
  private endStream(state: SessionState, kind: "reasoning" | "text", flush = true): void {
    if (state.isChildSession) return
    const holder = kind === "reasoning" ? state.reasoning : state.text
    const session = holder?.stream
    if (!session) return
    if (flush) {
      void session.end(holder?.text ?? "")
    } else {
      session.abort()
    }
  }

  // 流式元素预留序号:首次推帧时取"下一个 seq"并缓存到 holder。
  // 之后流式期间所有帧与终态 append 复用 holder.seq,保证 element_id 稳定不随
  // 中途其他元素(如 tool_card / 中途 reasoning 终态)的 append 而漂移。
  private streamSeq(state: SessionState, holder: StreamHolder): number {
    if (holder.seq === undefined) holder.seq = this.nextSeq(state)
    return holder.seq
  }

  // flush 缓冲 reasoning(public 暴露:SessionLifecycle 单 session flush 调用)。
  flushReasoning(state: SessionState): void {
    if (!state.reasoning?.text.trim()) return
    // 收口流式会话(SDK end:flush 尾部余量),让 APP 占位在终态替换前显示完整文本。
    this.endStream(state, "reasoning")
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
      const element = reasoningElement(
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
    // 收口流式会话(SDK end:flush 尾部余量),让 APP 占位在终态替换前显示完整文本。
    this.endStream(state, "text")
    const sid = state.text.streamId
    if (this.useAggregate(state)) {
      const element = markdownElement(state.text.text, state.text.seq ?? this.nextSeq(state))
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
      const element = markdownElement(pt.text, pt.seq ?? this.nextSeq(state))
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

  // 追加聚合卡元素(SDK AggregateCard.append:同 element_id 已存在自动改 update)。
  // 队列/镜像/分卡由 SDK 卡实例(state.aggregateCard 桥持有)统一维护,与 tool_card /
  // interaction 共用同一实例,并发 flush 按序执行不覆盖。
  // opts 透传:opts.silent → append 后单独 set_silent op(pending 交互响铃/恢复)。
  // 返回 Promise 不吞错误:调用方 await 走外层 try/catch,fire-and-forget 处自行 catch emit。
  private appendElement(
    state: SessionState,
    element: AggregateElement,
    opts?: { silent?: boolean },
  ): Promise<void> {
    return getAggregateCard(state, this.wanling).appendElement(element, opts)
  }
}
