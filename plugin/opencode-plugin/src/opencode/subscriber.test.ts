import { describe, it, expect } from "vitest"
import { EventSubscriber } from "./subscriber.js"

describe("EventSubscriber vcs.branch.updated", () => {
  it("解析 vcs.branch.updated 事件并 emit directory+branch", async () => {
    const mockClient = {
      global: {
        event: async () => ({
          stream: (async function* () {
            yield {
              directory: "/home/u/proj",
              payload: {
                type: "vcs.branch.updated",
                properties: { sessionID: "sess-1", branch: "feature/x" },
              },
            }
          })(),
        }),
      },
    } as any

    const sub = new EventSubscriber(mockClient)
    const received: any[] = []
    sub.on("vcs_branch_updated", (p) => received.push(p))
    // start() 内含 while+backoff 永续循环,await 会挂起测试,改用 fire-and-forget
    void sub.start()
    await new Promise((r) => setTimeout(r, 10))

    expect(received).toHaveLength(1)
    expect(received[0]).toEqual({
      sessionID: "sess-1",
      directory: "/home/u/proj",
      branch: "feature/x",
    })
    sub.stop()
  })
})

describe("EventSubscriber 缓存 assistant message time", () => {
  it("message.updated(assistant) 缓存 time,peekMessageTime 可读", async () => {
    const mockClient = {
      global: {
        event: async () => ({
          stream: (async function* () {
            yield {
              directory: "/home/u/proj",
              payload: {
                type: "message.updated",
                properties: {
                  sessionID: "sess-1",
                  info: { role: "assistant", time: { created: 1000, completed: 52000 } },
                },
              },
            }
          })(),
        }),
      },
    } as any

    const sub = new EventSubscriber(mockClient)
    void sub.start()
    await new Promise((r) => setTimeout(r, 10))

    expect(sub.peekMessageTime("sess-1")).toEqual({ created: 1000, completed: 52000 })
    sub.stop()
  })

  it("message.updated(user) 不缓存 assistant time", async () => {
    const mockClient = {
      global: {
        event: async () => ({
          stream: (async function* () {
            yield {
              directory: "/home/u/proj",
              payload: {
                type: "message.updated",
                properties: {
                  sessionID: "sess-1",
                  info: { role: "user", time: { created: 1000 } },
                },
              },
            }
          })(),
        }),
      },
    } as any

    const sub = new EventSubscriber(mockClient)
    void sub.start()
    await new Promise((r) => setTimeout(r, 10))

    expect(sub.peekMessageTime("sess-1")).toBeUndefined()
    sub.stop()
  })
})
