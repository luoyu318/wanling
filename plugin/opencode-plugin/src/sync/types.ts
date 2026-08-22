import type { StreamSession } from "@wanling/sdk"
import type { AggregateCardBridge, AggregateElement } from "./domains/aggregate_bridge.js"

export interface SessionState {
  // reasoning holder:timeStart 为 reasoning part 的 time.start(毫秒),供 idle 兜底
  // flushReasoning 估算思考耗时(此时 part.end 未到,用 now - start 近似,对齐 TUI
  // reasoning header 的 duration)。正常路径(part_updated end)用精确 end - start。
  // stream:SDK StreamSession 流式会话(首帧立即/300ms 节流/尾部兜底由 SDK 承担),
  // 惰性创建(delta 到达且非空白);streamId 终态带 _stream_id 用(APP 替换占位),
  // 会话 end 后仍保留。streamEnsure:聚合模式占位 append(REST)飞行中的建会话
  // Promise,防并发首帧双建会话。
  reasoning: { text: string; partID: string; streamId?: string; stream?: StreamSession; streamEnsure?: Promise<void>; seq?: number; timeStart?: number } | null
  text: { text: string; partID: string; streamId?: string; stream?: StreamSession; streamEnsure?: Promise<void>; seq?: number } | null
  // 最终回复 text 终态的缓存(根治:未读锚点 = 真实内容)。
  // text part 终态先于 step-finish 到达,此时不知道是否"回合最终回复"。
  // 缓存到 pendingText,等 step-finish 的 isLoopEnd 判定后再发:
  // - isLoopEnd → 以 silent=false 发(最终回复计未读,成为未读锚点)
  // - 非 isLoopEnd → 以 silent=true 发(中间步骤不打扰)
  // 兜底(flushText / 新 text 打断 / stop)以 silent=true 发,避免滞留。
  // seq:流式预留的聚合卡元素序号(从流式 holder 透传,终态 append 用同一 element_id)。
  pendingText?: { text: string; partID: string; streamId?: string; seq?: number }
  convId: string
  toolPartsSent: Set<string>
  // text/reasoning part 已被 idle 兜底(flushText/flushReasoning)发走终态的 partID 集合。
  // OC 延迟推来的 part_updated(end) 到达时检查,命中则跳过避免重复发终态(两条消息都入库)。
  textPartsFlushed: Set<string>
  toolCardMsgIds: Map<string, string>
  pendingToolCard?: { toolName: string; input: Record<string, unknown>; partId: string; aggregateSeq?: number }
  // 聚合卡 SDK 桥(Task 8 迁移):每 state 惰性一个,承载 SDK AggregateCard 实例
  // (串行队列/镜像/分卡归属/sealed 守卫在桥内),替代原散落 state 的
  // aggregateCardMsgId/aggregateElements/aggregatePatchQueue 等自管字段。
  aggregateCard?: AggregateCardBridge
  // 聚合卡元素序号计数器:element_id 按 type_seq 命名,reasoning/markdown/footer
  // 共用同一计数全局递增,保证 element_id 全卡唯一。回合收尾(bridge.sealRound)归零。
  aggregateSeq?: number
  // 聚合卡流式已占位元素:流式首帧前把目标 markdown/reasoning 元素 append 进卡,
  // 之后帧才能命中。Set 记录已 append 的 element_id,防并发帧重复占位。回合收尾清空。
  aggregateStreamedElementIds?: Set<string>
  // 聚合模式下工具元素定位:partId → 聚合卡内 tool_card element_id。
  // 工具 running 时同步写入(append 前),completed/error 时按 partId 找到目标元素
  // 做全量替换更新 status/output/error/file_diff。非聚合模式不写入。回合收尾清空。
  aggregateToolElementIds?: Map<string, string>
  // sendCardMessage(running) 已发起但 msgId 尚未返回的 inflight Promise。
  // completed/error 事件可能在此窗口到达,通过 await 这条 promise 拿到 msgId。
  toolCardInflight: Map<string, Promise<string>>
  // pendingToolCard 的 child 关联(task 工具用)。
  // wide-review I-1:onPermissionAsked/onQuestionAsked 刷新 pendingToolCard 时调
  // _flushPendingToolCard(state) 无参,若 childSessionId 仅靠参数传递会丢,
  // 导致 childSessionTree 永不注册 → 子 agent 输出全丢。存入 pending 对象本身,
  // 所有 flush 路径(含审批/提问抢占)一致读取。
  pendingChildSessionId?: string
  pendingParentSessionId?: string
  // 是否为子 session(childSessionTree 注册的)。命中即走 sendChildMsg 透传 parent/root
  isChildSession?: boolean
  // 反向引用对应的 ChildSessionEntry,避免每次 sendChildMsg 都查 Map
  childEntry?: ChildSessionEntry
  // 是否为主 session(用户直接对话的 agent 循环),区别于子 agent(Task 工具派生)。
  // idle 时仅主 session 发 step_finish finished=true(响铃 + 计未读),子 session idle 只通知主 agent。
  isMainSession?: boolean
  // 回合结束 footer 暂存(completed 事件驱动收尾):step-finish part 带 cost/tokens/reason
  // 但无 time;assistant_message_completed 带 time 但无 cost/tokens。两个事件互补,
  // step-finish 时暂存到这里,completed 时读取合并算 duration。仅主 session 聚合模式写入。
  footerDraft?: {
    reason: string
    cost: number
    tokens: Record<string, unknown>
  }
}

// 聚合卡元素类型再导出:tool_card/interaction 等调用方从 types.js 引用
// (原从 domains/aggregate_card.js,迁移 SDK 后统一走 bridge 模块)。
export type { AggregateElement }

// 子 session 注册项。Task 7 在 task/running 事件命中时塞入 childSessionTree。
// 本任务只搭框架:验证子 session 事件不再被 getOrCreateState 丢弃,并能透传 parent/root。
export interface ChildSessionEntry {
  parentMsgId: string       // 直接父 task 卡片 msgId
  rootMsgId: string         // 根 task 卡片 msgId(可能 == parentMsgId)
  depth: number             // 0=主, 1=一层子, 2=嵌套
  state: SessionState       // 子 session 自己的 state
  parentSessionId: string   // 父 opencode sessionID
  hasFirstEvent: boolean    // 是否已触发 working PATCH(每个 child 仅一次)
  // task 卡片初始 input + childSessionId,working PATCH 时复用(server UpdateContent 整体替换,
  // 不能只发 status 否则 input/sub_session_id 丢失,APP 渲染空白)。
  taskInput?: Record<string, unknown>
  childSessionId?: string
  // 兜底超时清理句柄:task 崩溃或漏发 completed/error SSE 时,10min 后强制清理避免泄漏。
  // 正常路径(task/completed|error)在 _handleTaskTool 清理前 clearTimeout。
  cleanupTimer?: ReturnType<typeof setTimeout>
  // 聚合模式下 task 卡是聚合卡内 tool_card 元素(非独立消息):
  // aggregateElementId 定位聚合卡内 task 元素,aggregateParentState 承载聚合卡桥
  // (state.aggregateCard)。命中时 working PATCH / 超时兜底 PATCH 走
  // bridge.updateElement,不再 updateMessageContent 独立 task 卡。
  aggregateElementId?: string
  aggregateParentState?: SessionState
}
