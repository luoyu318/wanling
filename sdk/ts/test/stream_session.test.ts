import { describe, expect, it, vi } from "vitest"
import { StreamSession } from "../src/stream_session.js"

describe("StreamSession", () => {
  it("首帧立即 + 300ms 节流 + 尾部兜底", async () => {
    vi.useFakeTimers()
    const frames: string[] = []
    const s = new StreamSession("c1", (_c, f) => frames.push(f.text))
    s.push("a"); vi.advanceTimersByTime(100); s.push("b")
    expect(frames).toEqual(["a"])          // 首帧立即
    vi.advanceTimersByTime(250)
    expect(frames).toEqual(["a"])          // 未到 300ms
    vi.advanceTimersByTime(60)
    expect(frames).toEqual(["a", "ab"])    // 尾部兜底 flush（累积全量快照）
    vi.useRealTimers()
  })

  it("aggregate 定位字段展开 + msg_type 默认 text", () => {
    const frames: Array<Record<string, unknown>> = []
    const s = new StreamSession("c1", (_c, f) => frames.push(f as unknown as Record<string, unknown>), {
      aggregate: { messageId: "m1", elementId: "e1" },
    })
    s.push("x")
    expect(frames[0]).toEqual({
      stream_id: expect.any(String),
      msg_type: "text",
      text: "x",
      aggregate: { message_id: "m1", element_id: "e1" },
    })
  })

  it("end 清 timer 并 flush 余量,后续 push 忽略", () => {
    vi.useFakeTimers()
    const frames: string[] = []
    const s = new StreamSession("c1", (_c, f) => frames.push(f.text))
    s.push("a")           // 首帧立即
    vi.advanceTimersByTime(100)
    s.push("b")           // 节流中,挂兜底 timer
    s.end("final")        // 关闭:清 timer + 立即 flush 余量
    expect(frames).toEqual(["a", "ab"])
    s.push("c")           // 已关闭,忽略
    vi.advanceTimersByTime(1000)
    expect(frames).toEqual(["a", "ab"])
    vi.useRealTimers()
  })

  it("abort 丢弃缓冲不再发帧", () => {
    vi.useFakeTimers()
    const frames: string[] = []
    const s = new StreamSession("c1", (_c, f) => frames.push(f.text))
    s.push("a")           // 首帧立即
    vi.advanceTimersByTime(100)
    s.push("b")           // 节流中,挂兜底 timer
    s.abort()             // 丢弃缓冲
    vi.advanceTimersByTime(1000)
    expect(frames).toEqual(["a"])
    vi.useRealTimers()
  })
})
