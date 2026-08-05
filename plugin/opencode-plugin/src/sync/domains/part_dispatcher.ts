import { randomUUID } from "crypto"
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

// PartDispatcher:part_updated / part_delta 分发领域模块。
// 职责:reasoning / text / step-finish 三类 part 的状态机分发 + part_delta 增量
// 追加 + flush 缓冲(reasoning/text 兜底输出)+ reasoning/text 流式快照(300ms 节流)。
// tool/compaction case 不在此处:ToolCardManager 和 CompactionTracker 各自订阅 part_updated
// 事件按 part.type 自行过滤处理,本模块的 onPartUpdated switch 只保留 reasoning/text/step-finish。
// 不持有状态(reasoning/text 在 SessionState 上,partIndex 在 store)。
// 错误经注入的 emitter(Streamer extends EventEmitter,传 this 作 emitter)上抛。
export class PartDispatcher {
  private readonly store: SessionStore
  private readonly router: MessageRouter
  private readonly metaSync: MetaSync
  private readonly compaction: CompactionTracker
  private readonly emitter: EventEmitter
  private readonly wanling: WanlingClient

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
  }) {
    this.store = deps.store
    this.router = deps.router
    this.metaSync = deps.metaSync
    this.compaction = deps.compaction
    this.emitter = deps.emitter
    this.wanling = deps.wanling
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
              console.log(`[SSE-DBG] part_updated reasoning END sid=${sid ?? "-"} ocLen=${text.length} child=${!!state.isChildSession} head=${JSON.stringify(text.slice(0, 30))}`)
              if (text.trim()) this.router.send(state, "reasoning",
                sid && !state.isChildSession ? { text, _stream_id: sid } : { text }, true)
              state.reasoning = null
            }
          } else {
            state.reasoning = { text: part.text || "", partID: part.id }
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
              console.log(`[SSE-DBG] part_updated text END sid=${sid ?? "-"} ocLen=${text.length} child=${!!state.isChildSession} head=${JSON.stringify(text.slice(0, 30))}`)
              // 根治(未读锚点=真实内容):text 终态缓存到 pendingText,不立即发。
              // 最终回复(step-finish isLoopEnd)以 silent=false 发(markdown 计未读),
              // 中间步骤以 silent=true 发。子 agent 文本恒 silent=true。
              if (text.trim()) {
                if (!state.isChildSession) {
                  state.pendingText = { text, partID: part.id, streamId: sid }
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
              const pt = state.pendingText
              state.pendingText = undefined
              this.router.send(state, "markdown",
                pt.streamId ? { text: pt.text, _stream_id: pt.streamId } : { text: pt.text }, true)
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
          console.log(`[streamer] step-finish session=${payload.sessionID.slice(0, 12)} isChild=${!!state.isChildSession} reason=${part.reason} isLoopEnd=${isLoopEnd} convId=${state.convId?.slice(0, 8)}`)
          // 根治(未读锚点=真实内容):step-finish 判定时把缓存的最终 text 终态发出。
          // - isLoopEnd(回合结束)→ silent=false,markdown 计未读成为未读锚点
          // - 非 isLoopEnd(中间步骤)→ silent=true,不打扰
          // 兜底:若 text 未走 end 缓存路径(异常时序,state.text 还在累积)先 silent=true 发掉。
          if (state.text) {
            const t = state.text
            state.text = null
            if (t.flushTimer) { clearTimeout(t.flushTimer) }
            this.router.send(state, "markdown",
              t.streamId && !state.isChildSession ? { text: t.text, _stream_id: t.streamId } : { text: t.text }, true)
          }
          this.flushPendingText(state, isLoopEnd ? false : true)
          // step_finish 恒 silent=true:结束标记不响铃、不计未读、不作未读锚点。
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
      console.log(`[SSE-DBG] part_delta reasoning part=${payload.partID.slice(0, 8)} dLen=${payload.delta.length} accLen=${state.reasoning.text.length}`)
      this.maybeFlushStream(state, "reasoning")
    } else if (state.text?.partID === payload.partID) {
      state.text.text += payload.delta
      console.log(`[SSE-DBG] part_delta text part=${payload.partID.slice(0, 8)} dLen=${payload.delta.length} accLen=${state.text.text.length}`)
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
      console.log(`[SSE-DBG] maybeFlushStream PUSH sid=${holder.streamId} kind=${kind} len=${holder.text.length} first=${holder.lastFlushAt === 0}`)
      this.wanling.sendStream(state.convId, {
        stream_id: holder.streamId,
        msg_type: kind === "reasoning" ? "reasoning" : "markdown",
        text: holder.text,
      })
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
    console.log(`[SSE-DBG] forceFlushStream 补推 sid=${holder.streamId} kind=${kind} len=${holder.text.length} prev=${holder.lastFlushedLen ?? 0}`)
    this.wanling.sendStream(state.convId, {
      stream_id: holder.streamId,
      msg_type: kind === "reasoning" ? "reasoning" : "markdown",
      text: holder.text,
    })
    holder.lastFlushedLen = holder.text.length
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
    console.log(`[SSE-DBG] FLUSH(reasoning)兜底 sid=${sid ?? "-"} accLen=${state.reasoning.text.length} head=${JSON.stringify(state.reasoning.text.slice(0, 30))}`)
    this.router.send(state, "reasoning",
      sid && !state.isChildSession ? { text: state.reasoning.text, _stream_id: sid } : { text: state.reasoning.text }, true)
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
    console.log(`[SSE-DBG] FLUSH(text)兜底 sid=${sid ?? "-"} accLen=${state.text.text.length} head=${JSON.stringify(state.text.text.slice(0, 30))}`)
    // I-P:子 agent 文本输出强制 silent=true(与 case "text" 同步口径)。
    this.router.send(state, "markdown",
      sid && !state.isChildSession ? { text: state.text.text, _stream_id: sid } : { text: state.text.text }, true)
    state.textPartsFlushed.add(state.text.partID)
    state.text = null
  }

  // 把缓存的最终 text 终态(pendingText)发出。
  // silent 由调用方决定:step-finish isLoopEnd → false(计未读);其余兜底 → true。
  private flushPendingText(state: SessionState, silent: boolean): void {
    if (!state.pendingText) return
    const pt = state.pendingText
    state.pendingText = undefined
    console.log(`[SSE-DBG] FLUSH(pendingText) silent=${silent} ocLen=${pt.text.length} head=${JSON.stringify(pt.text.slice(0, 30))}`)
    this.router.send(state, "markdown",
      pt.streamId ? { text: pt.text, _stream_id: pt.streamId } : { text: pt.text },
      silent)
  }
}
