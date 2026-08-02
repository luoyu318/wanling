import type { WanlingClient } from "../wanling/client.js"
import type { SessionState, ChildSessionEntry } from "./types.js"

export class MessageRouter {
  constructor(private wanling: WanlingClient) {}

  // 路由辅助:按 state 来源决定走主 session 还是子 session 透传。
  // reasoning / text / step_finish 都用这个,避免在每个 case 分支重复 if/else。
  // 子 session 专用发送:消息走父 task 卡片所在 conv,且带 parentMsgId/rootMsgId 让 server 串成树。
  // 子 session 的输出和主 session 在同一个 agent_session 群里,通过 parent/root 体现层级关系。
  send(state: SessionState, msgType: string, data: Record<string, unknown>, silent?: boolean): void {
    if (state.isChildSession && state.childEntry) {
      this.sendChild(state.childEntry, msgType, data, silent)
    } else {
      this.wanling.sendTypedMessage(state.convId, msgType, data, silent ? { silent: true } : undefined)
    }
  }

  // sendCardMessage 版的路由辅助:tool_card / permission_card / question_card 创建走这里。
  // 子 session 的卡片同样需要 parent/root 让 server 把卡片串到父 task 下。
  // silent 透传:tool_card 默认静默(不传 → undefined 走 server 默认 silent=true,见 client.ts:220);
  // permission_card / question_card 传 silent=false 让用户被响铃(agent 卡住等待用户介入)。
  // 主 session 路径仅在 silent 显式 false 时构造 options,保留原 undefined 语义避免破坏现有行为。
  sendCard(state: SessionState, msgType: string, data: Record<string, unknown>, silent?: boolean): Promise<string> {
    if (state.isChildSession && state.childEntry) {
      return this.wanling.sendCardMessage(state.convId, msgType, data, {
        silent: silent ?? true,
        parentMsgId: state.childEntry.parentMsgId,
        rootMsgId: state.childEntry.rootMsgId,
      })
    }
    // 主 session:silent=false 时显式传 options 触发响铃;其它情况(默认 silent)走 undefined,
    // 与原 tool_card 行为一致(server 端默认 silent=true)。
    return this.wanling.sendCardMessage(
      state.convId, msgType, data,
      silent === false ? { silent: false } : undefined,
    )
  }

  private sendChild(entry: ChildSessionEntry, msgType: string, data: Record<string, unknown>, silent?: boolean): void {
    this.wanling.sendTypedMessage(
      entry.state.convId, msgType, data,
      { silent, parentMsgId: entry.parentMsgId, rootMsgId: entry.rootMsgId },
    )
  }
}
