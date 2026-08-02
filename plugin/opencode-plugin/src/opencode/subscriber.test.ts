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
