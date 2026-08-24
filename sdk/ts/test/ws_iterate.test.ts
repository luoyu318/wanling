/* eslint-disable @typescript-eslint/no-explicit-any */
import { describe, it, expect } from "vitest"
import { EventEmitter } from "events"
import { iterateWebSocket } from "../src/client.js"

/** 最小 ws 形状：EventEmitter + readyState（OPEN=1），足以驱动 iterateWebSocket。 */
function openWs(): any {
  const ws = new EventEmitter()
  ws.readyState = 1
  return ws
}

/** 防挂起护栏：等一个 promise，超时则以明确信息失败。 */
async function orTimeout<T>(p: Promise<T>, ms: number, msg: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout>
  const timeout = new Promise<never>((_, rej) => {
    timer = setTimeout(() => rej(new Error(msg)), ms)
  })
  try {
    return await Promise.race([p, timeout])
  } finally {
    clearTimeout(timer!)
  }
}

describe("iterateWebSocket 帧交付", () => {
  it("同步连发的多条 message 全部交付（同 TCP 段多帧不丢）", async () => {
    const ws = openWs()
    const gen = iterateWebSocket(ws)

    // 消费者先挂起等待（resolve 已就位），再模拟 ws 库行为：
    // 同一 TCP read 回调内同步 emit 两个 message 事件（两帧同段）。
    // 第一帧唤醒等待者，第二帧到达时消费者尚在微任务空窗——必须入队而非丢弃。
    const firstPending = gen.next()
    ws.emit("message", "f1")
    ws.emit("message", "f2")

    const first = await orTimeout(firstPending, 100, "generator 未启动")
    expect(first.value).toBe("f1")

    const second = await orTimeout(
      gen.next(),
      100,
      "第二帧丢失：burst 内后续帧在消费者回到 await 前到达时被静默丢弃",
    )
    expect(second.value).toBe("f2")

    ws.emit("close")
    await gen.return(undefined)
  })

  it("消费者处理期间到达的帧被缓存，逐条交付", async () => {
    const ws = openWs()
    const gen = iterateWebSocket(ws)

    // 启动 generator（挂 listeners）后再 burst 三帧：
    // 第一帧唤醒等待者，后两帧在空窗到达应入队。
    const firstPending = gen.next()
    ws.emit("message", "a")
    ws.emit("message", "b")
    ws.emit("message", "c")

    const r1 = await orTimeout(firstPending, 100, "首帧未交付")
    const r2 = await orTimeout(gen.next(), 100, "次帧未交付")
    const r3 = await orTimeout(gen.next(), 100, "第三帧未交付")
    expect([r1.value, r2.value, r3.value]).toEqual(["a", "b", "c"])

    ws.emit("close")
    await gen.return(undefined)
  })

  it("close 打断等待（原语义保留）", async () => {
    const ws = openWs()
    const gen = iterateWebSocket(ws)
    const pending = gen.next()
    ws.emit("close")
    await expect(pending).rejects.toThrow("WS closed")
  })
})
