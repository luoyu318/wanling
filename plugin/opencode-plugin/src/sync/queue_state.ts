// 本地排队队列:engine(prompt 发送侧)在 session 忙(busy)时把新消息入队,
// session 空闲(idle)时从队列串行发送。排队消息先发 queued_status{queued:true}
// 让 APP 显示「排队中」徽标,取出发送时发 queued:false 移除徽标。
// opencode 1.18.12 的 v2 queue 实测只入队不执行,故排队由 plugin 自管理。
// 模块级瞬态状态(内存),进程重启清空。参照 mapper.ts 的模块级模式。

interface QueuedMessage {
  wanlingMsgId: string
  text: string
  agent?: string
  model?: { providerID: string; modelID: string }
}

const queues = new Map<string, QueuedMessage[]>()
const busySessions = new Set<string>()

// session 忙闲标记:忙 = agent 正在生成(已发 v1 promptAsync,等 idle 翻转)。
export function setSessionBusy(sessionId: string, busy: boolean): void {
  if (busy) {
    busySessions.add(sessionId)
  } else {
    busySessions.delete(sessionId)
  }
}

export function isSessionBusy(sessionId: string): boolean {
  return busySessions.has(sessionId)
}

// 消息入队(等待发送)。返回该消息在队列中的位置(1 起,用于可选位次展示)。
export function enqueuePendingMessage(
  sessionId: string,
  msg: QueuedMessage,
): number {
  const list = queues.get(sessionId) ?? []
  list.push(msg)
  queues.set(sessionId, list)
  return list.length
}

export function hasPendingMessages(sessionId: string): boolean {
  return (queues.get(sessionId)?.length ?? 0) > 0
}

// 取出下一条待发送消息(队首,FIFO)。无待发返回 null。
export function dequeueNextMessage(sessionId: string): QueuedMessage | null {
  const list = queues.get(sessionId)
  if (!list || list.length === 0) return null
  const head = list[0]
  list.shift()
  if (list.length === 0) queues.delete(sessionId)
  return head
}

export function getPendingCount(sessionId: string): number {
  return queues.get(sessionId)?.length ?? 0
}

export function clearQueue(sessionId: string): void {
  queues.delete(sessionId)
  busySessions.delete(sessionId)
}

export function clearAll(): void {
  queues.clear()
  busySessions.clear()
}
