// 排队消息 FIFO 关联:engine(prompt 发送侧)记录「wanling 消息 → opencode 入队顺序」,
// streamer(subscriber 事件侧)按 admitted/prompted 事件顺序消费。
// opencode queue 保序,发送顺序 = 入队顺序 = 调度顺序,故 FIFO 匹配可靠;
// 用 text 校验兜底(顺序命中时文本应一致,不一致告警降级)。
// 模块级瞬态状态(内存),进程重启清空。参照 mapper.ts 的模块级模式。

interface QueuedSent {
  wanlingMsgId: string
  text: string
}

const queues = new Map<string, QueuedSent[]>()

export function enqueueSentMessage(
  sessionId: string,
  wanlingMsgId: string,
  text: string,
): void {
  const list = queues.get(sessionId) ?? []
  list.push({ wanlingMsgId, text })
  queues.set(sessionId, list)
}

export function peekQueue(sessionId: string): Array<QueuedSent> {
  return queues.get(sessionId) ?? []
}

export function dequeueByText(
  sessionId: string,
  text: string,
): { wanlingMsgId: string } | null {
  const list = queues.get(sessionId)
  if (!list || list.length === 0) return null
  const head = list[0]
  if (head.text !== text) {
    console.warn(
      `[queue] 顺序不匹配:队首="${head.text.slice(0, 30)}" 事件文本="${text.slice(0, 30)}"`,
    )
    return null
  }
  list.shift()
  if (list.length === 0) queues.delete(sessionId)
  return { wanlingMsgId: head.wanlingMsgId }
}

export function clearQueue(sessionId: string): void {
  queues.delete(sessionId)
}

export function getQueueLength(sessionId: string): number {
  return queues.get(sessionId)?.length ?? 0
}

export function clearAll(): void {
  queues.clear()
}
