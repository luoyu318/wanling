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

describe("EventSubscriber 回合耗时数据(user created 缓存 + completed 事件)", () => {
  it("message.updated(user) 缓存 created,peekUserCreated 可读", async () => {
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
                  info: { id: "user-1", role: "user", time: { created: 5000 } },
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

    expect(sub.peekUserCreated("user-1")).toBe(5000)
    sub.stop()
  })

  it("message.updated(assistant) completed + finish 非 tool-calls → emit assistant_message_completed", async () => {
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
                  info: { id: "asst-1", role: "assistant", parentID: "user-1", time: { created: 5100, completed: 52000 }, finish: "stop" },
                },
              },
            }
          })(),
        }),
      },
    } as any

    const sub = new EventSubscriber(mockClient)
    const received: any[] = []
    sub.on("assistant_message_completed", (p) => received.push(p))
    void sub.start()
    await new Promise((r) => setTimeout(r, 10))

    expect(received).toHaveLength(1)
    expect(received[0]).toEqual({
      sessionID: "sess-1",
      messageID: "asst-1",
      parentID: "user-1",
      created: 5100,
      completed: 52000,
    })
    sub.stop()
  })

  it("message.updated(assistant) finish=tool-calls → 不 emit completed(回合未结束)", async () => {
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
                  info: { id: "asst-1", role: "assistant", parentID: "user-1", time: { created: 5100, completed: 52000 }, finish: "tool-calls" },
                },
              },
            }
          })(),
        }),
      },
    } as any

    const sub = new EventSubscriber(mockClient)
    const received: any[] = []
    sub.on("assistant_message_completed", (p) => received.push(p))
    void sub.start()
    await new Promise((r) => setTimeout(r, 10))

    expect(received).toHaveLength(0)
    sub.stop()
  })

  it("message.updated(assistant) 无 completed → 不 emit", async () => {
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
                  info: { id: "asst-1", role: "assistant", parentID: "user-1", time: { created: 5100 }, finish: "stop" },
                },
              },
            }
          })(),
        }),
      },
    } as any

    const sub = new EventSubscriber(mockClient)
    const received: any[] = []
    sub.on("assistant_message_completed", (p) => received.push(p))
    void sub.start()
    await new Promise((r) => setTimeout(r, 10))

    expect(received).toHaveLength(0)
    sub.stop()
  })
})
