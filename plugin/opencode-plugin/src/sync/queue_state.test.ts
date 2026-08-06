import { describe, it, expect, beforeEach } from "vitest"
import {
  setSessionBusy,
  isSessionBusy,
  enqueuePendingMessage,
  hasPendingMessages,
  dequeueNextMessage,
  getPendingCount,
  clearQueue,
  clearAll,
} from "./queue_state.js"

describe("queue_state 本地排队", () => {
  beforeEach(() => {
    clearAll()
  })

  it("busy 标记:setSessionBusy 控制 isSessionBusy", () => {
    setSessionBusy("sess-1", true)
    expect(isSessionBusy("sess-1")).toBe(true)
    setSessionBusy("sess-1", false)
    expect(isSessionBusy("sess-1")).toBe(false)
  })

  it("enqueue then dequeue in FIFO order", () => {
    enqueuePendingMessage("sess-1", { wanlingMsgId: "msg-1", text: "hello A" })
    enqueuePendingMessage("sess-1", { wanlingMsgId: "msg-2", text: "hello B" })
    expect(getPendingCount("sess-1")).toBe(2)

    const a = dequeueNextMessage("sess-1")
    expect(a).toEqual({ wanlingMsgId: "msg-1", text: "hello A" })
    expect(getPendingCount("sess-1")).toBe(1)

    const b = dequeueNextMessage("sess-1")
    expect(b?.wanlingMsgId).toBe("msg-2")
    expect(hasPendingMessages("sess-1")).toBe(false)
  })

  it("保留 agent/model 透传字段", () => {
    enqueuePendingMessage("sess-1", {
      wanlingMsgId: "msg-1",
      text: "hi",
      agent: "build",
      model: { providerID: "opencode-go", modelID: "deepseek-v4-flash" },
    })
    const m = dequeueNextMessage("sess-1")
    expect(m?.agent).toBe("build")
    expect(m?.model?.modelID).toBe("deepseek-v4-flash")
  })

  it("空队列 dequeue 返回 null", () => {
    expect(dequeueNextMessage("sess-1")).toBeNull()
    expect(hasPendingMessages("sess-1")).toBe(false)
  })

  it("clear 重置队列与 busy 标记", () => {
    setSessionBusy("sess-1", true)
    enqueuePendingMessage("sess-1", { wanlingMsgId: "msg-1", text: "hi" })
    clearQueue("sess-1")
    expect(getPendingCount("sess-1")).toBe(0)
    expect(isSessionBusy("sess-1")).toBe(false)
  })

  it("不同 session 队列隔离", () => {
    enqueuePendingMessage("sess-a", { wanlingMsgId: "m1", text: "a" })
    enqueuePendingMessage("sess-b", { wanlingMsgId: "m2", text: "b" })
    setSessionBusy("sess-a", true)
    expect(getPendingCount("sess-a")).toBe(1)
    expect(getPendingCount("sess-b")).toBe(1)
    expect(isSessionBusy("sess-a")).toBe(true)
    expect(isSessionBusy("sess-b")).toBe(false)
  })
})
