import { describe, it, expect, beforeEach } from "vitest"
import {
  enqueueSentMessage,
  peekQueue,
  dequeueByText,
  clearQueue,
  getQueueLength,
  clearAll,
} from "./queue_state.js"

describe("queue_state FIFO", () => {
  beforeEach(() => {
    clearAll()
  })

  it("enqueue then dequeue by text in FIFO order", () => {
    enqueueSentMessage("sess-1", "msg-1", "hello A")
    enqueueSentMessage("sess-1", "msg-2", "hello B")
    expect(getQueueLength("sess-1")).toBe(2)

    const a = dequeueByText("sess-1", "hello A")
    expect(a).toEqual({ wanlingMsgId: "msg-1" })
    expect(getQueueLength("sess-1")).toBe(1)

    const b = dequeueByText("sess-1", "hello B")
    expect(b).toEqual({ wanlingMsgId: "msg-2" })
    expect(getQueueLength("sess-1")).toBe(0)
  })

  it("peek returns head without removing", () => {
    enqueueSentMessage("sess-1", "msg-1", "hello A")
    expect(peekQueue("sess-1")).toEqual([
      { wanlingMsgId: "msg-1", text: "hello A" },
    ])
    expect(getQueueLength("sess-1")).toBe(1)
  })

  it("dequeue with mismatched text returns null and keeps queue", () => {
    enqueueSentMessage("sess-1", "msg-1", "hello A")
    expect(dequeueByText("sess-1", "different")).toBeNull()
    expect(getQueueLength("sess-1")).toBe(1)
  })

  it("clear resets per-session queue", () => {
    enqueueSentMessage("sess-1", "msg-1", "hello A")
    clearQueue("sess-1")
    expect(getQueueLength("sess-1")).toBe(0)
  })

  it("different sessions have isolated queues", () => {
    enqueueSentMessage("sess-a", "msg-1", "a1")
    enqueueSentMessage("sess-b", "msg-1", "b1")
    expect(getQueueLength("sess-a")).toBe(1)
    expect(getQueueLength("sess-b")).toBe(1)
    const a = dequeueByText("sess-a", "a1")
    expect(a).toEqual({ wanlingMsgId: "msg-1" })
    expect(getQueueLength("sess-b")).toBe(1)
  })
})
