import { describe, it, expect, vi, beforeEach } from "vitest"

// v1 SDK mock:参照 bridge.test.ts —— session.list resolve 空数组跳过 spawn
vi.mock("@opencode-ai/sdk", () => {
  const sessionMock = { list: vi.fn().mockResolvedValue([]) }
  return { createOpencodeClient: () => ({ session: sessionMock }) }
})

// v2 SDK mock:session.prompt / switchModel / switchAgent
vi.mock("@opencode-ai/sdk/v2", () => {
  const promptMock = vi.fn()
  const switchModelMock = vi.fn()
  const switchAgentMock = vi.fn()
  const sessionMock = {
    prompt: promptMock,
    switchModel: switchModelMock,
    switchAgent: switchAgentMock,
  }
  return {
    createOpencodeClient: () => ({ session: sessionMock }),
    __promptMock: promptMock,
    __switchModelMock: switchModelMock,
    __switchAgentMock: switchAgentMock,
  }
})

import { OpencodeBridge } from "./bridge.js"

const { __promptMock: promptMock, __switchModelMock: switchModelMock, __switchAgentMock: switchAgentMock } =
  (await import("@opencode-ai/sdk/v2")) as any

describe("OpencodeBridge.promptAsync (v2 queue)", () => {
  let bridge: OpencodeBridge

  beforeEach(async () => {
    promptMock.mockReset()
    switchModelMock.mockReset()
    switchAgentMock.mockReset()
    promptMock.mockResolvedValue({ error: undefined, data: { id: "oc-msg-1" } })
    switchModelMock.mockResolvedValue({ error: undefined })
    switchAgentMock.mockResolvedValue({ error: undefined })
    bridge = new OpencodeBridge(4096)
    // ensureServer 路径走 mock,跳过真实 spawn
    await bridge.ensureServer()
  })

  it("calls v2 session.prompt with delivery queue and returns messageID", async () => {
    const result = await bridge.promptAsync("sess-1", "hello")

    expect(promptMock).toHaveBeenCalledWith(
      expect.objectContaining({
        sessionID: "sess-1",
        prompt: { text: "hello" },
        delivery: "queue",
        resume: true,
      }),
    )
    expect(result).toBe("oc-msg-1")
  })

  it("switchModel/switchAgent called before prompt when model/agent provided", async () => {
    await bridge.promptAsync("sess-1", "hello", "build", {
      providerID: "opencode-go",
      modelID: "deepseek-v4-flash",
    })

    expect(switchAgentMock).toHaveBeenCalledWith({
      sessionID: "sess-1",
      agent: "build",
    })
    expect(switchModelMock).toHaveBeenCalledWith({
      sessionID: "sess-1",
      model: { providerID: "opencode-go", id: "deepseek-v4-flash" },
    })
    // prompt 不再带 model/agent(已丢弃,只发 text)
    expect(promptMock).toHaveBeenCalledWith(
      expect.objectContaining({
        prompt: { text: "hello" },
      }),
    )
  })

  it("returns null when v2 response has no id", async () => {
    promptMock.mockResolvedValue({ error: undefined, data: {} })
    const result = await bridge.promptAsync("sess-1", "hello")
    expect(result).toBeNull()
  })
})
