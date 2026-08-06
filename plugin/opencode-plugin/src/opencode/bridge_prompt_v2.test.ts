import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"

// v1 SDK mock:参照 bridge.test.ts —— session.list resolve 空数组跳过 spawn
vi.mock("@opencode-ai/sdk", () => {
  const sessionMock = { list: vi.fn().mockResolvedValue([]) }
  return { createOpencodeClient: () => ({ session: sessionMock }) }
})

// v2 SDK mock:session.prompt / switchModel / switchAgent
vi.mock("@opencode-ai/sdk/v2", () => {
  const promptMock = vi.fn()
  const sessionMock = { prompt: promptMock }
  return {
    createOpencodeClient: () => ({ session: sessionMock }),
    __promptMock: promptMock,
  }
})

import { OpencodeBridge } from "./bridge.js"

const { __promptMock: promptMock } = (await import("@opencode-ai/sdk/v2")) as any

describe("OpencodeBridge.promptAsync (v2 queue)", () => {
  let bridge: OpencodeBridge

  beforeEach(async () => {
    promptMock.mockReset()
    promptMock.mockResolvedValue({ error: undefined, data: { id: "oc-msg-1" } })
    // fetch 直接调 switchModel/switchAgent 端点
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({
      ok: true,
      text: async () => "",
    }))
    bridge = new OpencodeBridge(4096)
    // ensureServer 路径走 mock,跳过真实 spawn
    await bridge.ensureServer()
  })

  afterEach(() => {
    vi.unstubAllGlobals()
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

  it("switchModel/switchAgent 经 fetch 调用且 prompt 不带 model/agent", async () => {
    const fetchMock = vi.mocked(globalThis.fetch as unknown as ReturnType<typeof vi.fn>)
    await bridge.promptAsync("sess-1", "hello", "build", {
      providerID: "opencode-go",
      modelID: "deepseek-v4-flash",
    })

    // switchAgent → POST /api/session/{id}/agent
    const agentCall = fetchMock.mock.calls[0]
    expect(agentCall[0]).toContain("/api/session/sess-1/agent")
    expect(JSON.parse(agentCall[1].body as string)).toEqual({ agent: "build" })

    // switchModel → POST /api/session/{id}/model
    const modelCall = fetchMock.mock.calls[1]
    expect(modelCall[0]).toContain("/api/session/sess-1/model")
    expect(JSON.parse(modelCall[1].body as string)).toEqual({
      model: { providerID: "opencode-go", id: "deepseek-v4-flash" },
    })

    // prompt 不带 model/agent(已丢弃,只发 text)
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
