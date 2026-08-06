import { describe, it, expect, vi, beforeEach } from "vitest"

// v1 SDK mock:session.list resolve 空数组跳过 spawn;promptAsync 可断言调用
vi.mock("@opencode-ai/sdk", () => {
  const promptAsyncMock = vi.fn()
  const sessionMock = {
    list: vi.fn().mockResolvedValue([]),
    promptAsync: promptAsyncMock,
  }
  return {
    createOpencodeClient: () => ({ session: sessionMock }),
    __promptAsyncMock: promptAsyncMock,
  }
})

// v2 SDK mock:默认空 client(v1 发送不需要 v2)
vi.mock("@opencode-ai/sdk/v2", () => {
  return {
    createOpencodeClient: () => ({}),
  }
})

import { OpencodeBridge } from "./bridge.js"

const { __promptAsyncMock: promptAsyncMock } = (await import("@opencode-ai/sdk")) as any

describe("OpencodeBridge.promptAsync (v1 发送,回退自 v2 queue)", () => {
  let bridge: OpencodeBridge

  beforeEach(async () => {
    promptAsyncMock.mockReset()
    promptAsyncMock.mockResolvedValue(undefined)
    bridge = new OpencodeBridge(4096)
    // ensureServer 路径走 mock,跳过真实 spawn
    await bridge.ensureServer()
  })

  it("calls v1 session.promptAsync with parts text", async () => {
    const result = await bridge.promptAsync("sess-1", "hello")

    expect(promptAsyncMock).toHaveBeenCalledWith({
      path: { id: "sess-1" },
      body: {
        parts: [{ type: "text", text: "hello" }],
      },
    })
    expect(result).toBeNull()
  })

  it("透传 agent/model 到 v1 body", async () => {
    await bridge.promptAsync("sess-1", "hello", "build", {
      providerID: "opencode-go",
      modelID: "deepseek-v4-flash",
    })

    expect(promptAsyncMock).toHaveBeenCalledWith({
      path: { id: "sess-1" },
      body: {
        agent: "build",
        model: { providerID: "opencode-go", modelID: "deepseek-v4-flash" },
        parts: [{ type: "text", text: "hello" }],
      },
    })
  })
})
