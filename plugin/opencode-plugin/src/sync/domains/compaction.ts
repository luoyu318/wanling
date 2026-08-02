import type { WanlingClient } from "../../wanling/client.js"
import type { PartUpdatedPayload } from "../../opencode/subscriber.js"
import type { SessionState } from "../types.js"
import type { SessionStore } from "../session_store.js"
import type { MessageRouter } from "../messaging.js"

// CompactionTracker:compaction part 处理领域模块。
// 职责:compaction divider 卡片 running/done 状态机 + step-finish loopEnd 兜底 PATCH。
// 依赖 store、router(接口一致性,compaction 经 isChildSession 守卫后直接调 wanling,
// 不走子 session 透传路由)、wanling。
// 持有 compactionParts 状态 map(从 Streamer 迁入)。
export class CompactionTracker {
  private readonly store: SessionStore
  private readonly router: MessageRouter
  private readonly wanling: WanlingClient

  // compaction part 去重:同 part.id 出现 2 次(开始/结束),记录 divider 消息 id。
  // 抓包确认(OC 1.18.3):首次 compaction part 无 tail_start_id(开始),
  // 第二次同 id 带 tail_start_id(结束)。entry 存 sendCardMessage 返回的 msgId 供后续 PATCH。
  private compactionParts = new Map<string, { dividerMsgId: string; done: boolean }>()

  constructor(deps: {
    store: SessionStore
    router: MessageRouter
    wanling: WanlingClient
  }) {
    this.store = deps.store
    this.router = deps.router
    this.wanling = deps.wanling
  }

  // case "compaction" 方法体(从 Streamer.onPartUpdated 逐字迁入)。
  // 抓包确认(OC 1.18.3):compaction part 同 id 出现 2 次
  //   第一次:压缩开始(无 tail_start_id)
  //   第二次:压缩结束(带 tail_start_id)
  // 守卫语义:仅过滤子 agent(task tool 调用产生的子 session)的 compaction,
  // 不影响用户视图。早期实现用 isMainSession 守卫是错的——mainSessionId 是单一
  // 变量,只匹配 plugin 启动那一刻的主 session,对「已存在 conv 复用的旧 OC session」
  // 会误判为非主从而漏发 divider(参见 case "text" 同款注释 line 512)。
  async handlePart(part: PartUpdatedPayload["part"], state: SessionState): Promise<void> {
    if (state.isChildSession) return

    const partId = part.id
    const seen = this.compactionParts.get(partId)
    if (!seen) {
      // 首次:发 compact_divider phase=running,silent=true(过程态不打扰用户)
      this.compactionParts.set(partId, { dividerMsgId: "", done: false })
      const tailStartId = (part as { tail_start_id?: string }).tail_start_id
      if (tailStartId) {
        // 异常时序:首次就带 tail_start_id(理论上不该发生),直接走 done 路径
        this.compactionParts.delete(partId)
        await this.sendDivider(state, "done")
      } else {
        await this.sendDivider(state, "running", partId)
      }
    } else if (!seen.done) {
      // 第二次同 id:PATCH 切 done
      seen.done = true
      await this.patchDivider(seen.dividerMsgId, "done")
      this.compactionParts.delete(partId)
    }
  }

  // 兜底把同 session 内所有未完成的 compaction(divider 处于 running)PATCH 为 done。
  // 触发时机:agent loop isLoopEnd(reason=stop + 非子 agent)。
  // 设计原因:OC 1.18.3 实测只推一次 compaction part(不再有第二次同 id 带 tail_start_id),
  // 单靠 case "compaction" 的 seen.done 路径切不到 done,需要外部信号兜底。
  async completePending(sessionID: string): Promise<void> {
    const pending = [...this.compactionParts.entries()].filter(
      ([_, v]) => !v.done,
    )
    if (pending.length === 0) return
    console.log(`[streamer] compaction 兜底切 done: session=${sessionID.slice(0, 12)}… count=${pending.length}`)
    for (const [partId, entry] of pending) {
      entry.done = true
      try {
        await this.patchDivider(entry.dividerMsgId, "done")
      } catch (err) {
        console.error(`[streamer] compaction 兜底 PATCH 失败 partId=${partId.slice(0, 12)}…: ${err instanceof Error ? err.message : err}`)
      }
      this.compactionParts.delete(partId)
    }
  }

  // 发 compact_divider 消息(running/done/failed 三态),记 partId→msgId 映射。
  // silent 语义:running/done 是过程态不打扰用户(silent=true);
  // failed 是错误终态需响铃(silent=false,MVP 未实现 failed 路径)。
  private async sendDivider(
    state: SessionState,
    phase: "running" | "done" | "failed",
    partId?: string,
  ): Promise<void> {
    const msgId = await this.wanling.sendCardMessage(
      state.convId,
      "compact_divider",
      { phase },
      { silent: phase !== "failed" },
    )
    if (partId) {
      const entry = this.compactionParts.get(partId)
      if (entry) entry.dividerMsgId = msgId
    }
  }

  // PATCH compact_divider 消息切 phase(running→done / →failed)。
  // dividerMsgId 为空(sendCardMessage 未 resolve 异常场景)时 silently 跳过,
  // 由 engine.ts:116 现有 catch 兜底发 markdown 错误消息提示用户。
  private async patchDivider(
    dividerMsgId: string,
    phase: "running" | "done" | "failed",
  ): Promise<void> {
    if (!dividerMsgId) return
    await this.wanling.updateMessageContent(dividerMsgId, {
      msg_type: "compact_divider",
      data: { phase },
    })
  }
}
