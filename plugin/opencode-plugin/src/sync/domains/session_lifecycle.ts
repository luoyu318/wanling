import type { EventEmitter } from "events"
import { logger } from "../../utils/logger.js"
import type { WanlingClient } from "../../wanling/client.js"
import type { SessionStatusPayload } from "../../opencode/subscriber.js"
import type { SessionStore } from "../session_store.js"
import type { MessageRouter } from "../messaging.js"
import type { PartDispatcher } from "./part_dispatcher.js"

// SessionLifecycle:session 状态/心跳/flush 兜底领域模块。
// 职责:session.status(busy/retry/idle) 透传 + 心跳保活(每 20s 复发 busy 防止
// server 状态指示器提前熄灭) + session.idle flush 兜底(防 part_updated/text
// 漏发 time.end 的残留缓冲丢失)。持有 activeSessions + heartbeatTimer 两个状态。
// 错误经注入的 emitter(Streamer extends EventEmitter,传 this 作 emitter)上抛。
export class SessionLifecycle {
  private readonly store: SessionStore
  private readonly router: MessageRouter
  private readonly wanling: WanlingClient
  private readonly partDispatcher: PartDispatcher
  private readonly emitter: EventEmitter

  // activeSessions/heartbeatTimer public:Streamer 兼容 shim(streamer.test.ts 通过
  // (streamer as any).activeSessions.add / .heartbeatTimer 直接访问)需读取/写入本字段。
  // 与 SessionStore.sessions / MetaSync.providerNames 的 public 暴露同模式(迁移过渡期)。
  public activeSessions: Set<string> = new Set()
  public heartbeatTimer: ReturnType<typeof setInterval> | null = null

  constructor(deps: {
    store: SessionStore
    router: MessageRouter
    wanling: WanlingClient
    partDispatcher: PartDispatcher
    emitter: EventEmitter
  }) {
    this.store = deps.store
    this.router = deps.router
    this.wanling = deps.wanling
    this.partDispatcher = deps.partDispatcher
    this.emitter = deps.emitter
  }

  // session 状态信号(busy/retry/idle)统一入口。
  // - busy/retry:透传给 server,APP 渲染「Agent 思考中」/「重试中(N)」状态。
  // - idle:flush 兜底(防 session.idle 事件丢失);session_idle 事件由 onSessionIdle(Task 4) 主路径处理。
  //   flush 是幂等的:state.reasoning/text flush 后置 null,重复 flush 无操作。
  onSessionStatus(payload: SessionStatusPayload): void {
    const state = this.store.peekState(payload.sessionID)
    // sessions map miss 时回退到 mapper 查 convId:
    // 新会话首个 session.status 事件可能先于 message.part.updated 到达
    //（state 在 onPartUpdated→getOrCreateState 中异步创建，此时尚未存在）。
    const convId = state?.convId ?? this.store.peekConvId(payload.sessionID)
    logger.info(`[streamer] onSessionStatus session=${payload.sessionID.slice(0, 12)}… type=${payload.status.type} state=${!!state} convId=${convId?.slice(0, 8) ?? "miss"}`)
    if (!convId) return

    switch (payload.status.type) {
      case "busy":
        this.activeSessions.add(payload.sessionID)
        this.startHeartbeat()
        this.wanling.sendSessionStatus(convId, "busy")
        break
      case "retry":
        this.activeSessions.add(payload.sessionID)
        this.startHeartbeat()
        this.wanling.sendSessionStatus(convId, "retry", {
          attempt: payload.status.attempt,
          message: payload.status.message,
        })
        break
      case "idle":
        this.activeSessions.delete(payload.sessionID)
        this.stopHeartbeatIfEmpty()
        // opencode 实际通过 session.status type=idle 通知循环结束，
        // 独立的 session.idle 事件不一定发出。
        // 因此 idle 状态直接走 onSessionIdle 完整逻辑（flush + SESSION_STATUS idle + finished 信号）。
        // 如果 session.idle 事件后来也到达，onSessionIdle 会再跑一遍（幂等：flush 无操作、clear 无操作）。
        void this.onSessionIdle(payload.sessionID)
        break
    }
  }

  // startHeartbeat/stopHeartbeat/stopHeartbeatIfEmpty public:Streamer 兼容 shim
  // (streamer.test.ts 通过 (streamer as any)._startHeartbeat 直接调用)需转发到本方法。
  startHeartbeat(): void {
    if (this.heartbeatTimer) return
    this.heartbeatTimer = setInterval(() => {
      for (const sessionID of this.activeSessions) {
        const state = this.store.peekState(sessionID)
        const convId = state?.convId ?? this.store.peekConvId(sessionID)
        if (convId) {
          this.wanling.sendSessionStatus(convId, "busy")
        }
      }
    }, 20_000)
  }

  stopHeartbeat(): void {
    if (this.heartbeatTimer) {
      clearInterval(this.heartbeatTimer)
      this.heartbeatTimer = null
    }
  }

  stopHeartbeatIfEmpty(): void {
    if (this.activeSessions.size === 0) {
      this.stopHeartbeat()
    }
  }

  // session.idle 事件处理:opencode agent 循环结束。
  // 1. flush 兜底:防 part_updated/text 漏发 time.end 的残留缓冲丢失。
  // 2. 仅主 session 发 SESSION_STATUS idle(APP 监听此事件自己触发响铃通知)。
  //    子 session idle 只是 task 工具返回,通知主 agent 继续循环,用户不关心;
  //    且子 session 共享主 session 的 convId,发 idle 会误灭主 agent 状态指示器。
  // 与 onSessionStatus 的 idle 分支关系:onSessionIdle 是 session.idle 事件主路径,
  // onSessionStatus 的 flush 是 session_status/idle 的兜底(两者互补,flush 幂等)。
  //
  // 设计:不再发占位 step_finish silent=false 消息——响铃由 APP 监听 SESSION_STATUS
  // idle 自己触发,避免消息列表出现空"已完成"行(原占位消息 data 全空,渲染突兀,
  // 且会覆盖真实回复成为列表最底消息)。
  async onSessionIdle(sessionID: string): Promise<void> {
    // idle 去重:session.status type=idle 和 session.idle 独立事件可能都触发本方法。
    // 5 秒窗口内同一 session 只处理一次,防止重复 flush / 重复发 SESSION_STATUS idle。
    // idleHandled map 已迁入 store,通过 markIdleIfFirst 原子检查+标记。
    if (!this.store.markIdleIfFirst(sessionID)) return

    const state = this.store.peekState(sessionID)

    // sessions map miss 时回退到 mapper(同 onSessionStatus 的回退逻辑)。
    // mapper 命中 = APP 创建的对话 session(非子 session)。
    this.activeSessions.delete(sessionID)
    this.stopHeartbeatIfEmpty()

    if (!state) {
      const convId = this.store.peekConvId(sessionID)
      if (!convId) return
      this.wanling.sendSessionStatus(convId, "idle")
      return
    }

    // 1. flush 缓冲文本
    this.partDispatcher.flushReasoning(state)
    this.partDispatcher.flushText(state)

    // 2. 发 idle 状态(APP 监听 SESSION_STATUS idle 自己触发响铃通知)
    //    sessions.get() 拿到的都是主 session(子 session 在 childSessionTree 中,不入 sessions map)。
    //    因此无需 isMainSession 守卫——能到这里的就是用户关心的对话 session。
    this.wanling.sendSessionStatus(state.convId, "idle")
  }

  // 清理心跳 timer + activeSessions。由 Streamer.stop 调用,store 内的
  // sessions/childSessionTree/partIndex/idleHandled 由 store.stop 自行清理。
  stop(): void {
    this.stopHeartbeat()
    this.activeSessions.clear()
  }
}
