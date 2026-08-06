import { describe, it, expect } from "vitest"
import { EventSubscriber } from "./subscriber.js"

describe("EventSubscriber queue 事件", () => {
  it("prompt.admitted → emit queue_admitted", async () => {
    const mockClient = {
      global: {
        event: async () => ({
          stream: (async function* () {
            yield {
              directory: "/home/u/proj",
              payload: {
                type: "session.next.prompt.admitted",
                properties: {
                  sessionID: "sess-1",
                  messageID: "oc-msg-1",
                  prompt: { text: "hello A" },
                  delivery: "queue",
                },
              },
            }
          })(),
        }),
      },
    } as any

    const sub = new EventSubscriber(mockClient)
    const received: any[] = []
    sub.on("queue_admitted", (p) => received.push(p))
    void sub.start()
    await new Promise((r) => setTimeout(r, 10))

    expect(received).toHaveLength(1)
    expect(received[0]).toEqual({
      sessionID: "sess-1",
      messageID: "oc-msg-1",
      text: "hello A",
    })
    sub.stop()
  })

  it("prompted → emit queue_prompted", async () => {
    const mockClient = {
      global: {
        event: async () => ({
          stream: (async function* () {
            yield {
              directory: "/home/u/proj",
              payload: {
                type: "session.next.prompted",
                properties: {
                  sessionID: "sess-1",
                  messageID: "oc-msg-1",
                  prompt: { text: "hello A" },
                  delivery: "queue",
                },
              },
            }
          })(),
        }),
      },
    } as any

    const sub = new EventSubscriber(mockClient)
    const received: any[] = []
    sub.on("queue_prompted", (p) => received.push(p))
    void sub.start()
    await new Promise((r) => setTimeout(r, 10))

    expect(received).toHaveLength(1)
    expect(received[0]).toEqual({
      sessionID: "sess-1",
      messageID: "oc-msg-1",
      text: "hello A",
    })
    sub.stop()
  })
})
