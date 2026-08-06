import { describe, it, expect, vi, beforeEach } from "vitest"

// v1 SDK mock: ensureServer() 内 client.session.list() 走 v1 SDK(bridge.ts:2,104),
// 不 stub 会真打 localhost:4096 → CI/容器无 opencode 服务时 flaky 或挂。
// session.list 直接 resolve 空数组,表示 OC "已就绪",跳过 spawn 路径。
// v1 OpencodeClient.session 同样是 getter 属性,用对象形式。
vi.mock("@opencode-ai/sdk", () => {
  const sessionMock = {
    list: vi.fn().mockResolvedValue([]),
  }
  return {
    createOpencodeClient: () => ({ session: sessionMock }),
  }
})

// bridge 内部用 v2 SDK 的 createOpencodeClient(bridge.ts 别名为 createOpencodeClientV2)
// 创建 client,我们 mock 整个 SDK v2 模块。
// SDK v2 OpencodeClient 的 session/permission/question 是 getter 属性(返回对象),
// 不是函数,所以 mock 里 session 必须是对象而非工厂函数。
// 注意:导出名是 createOpencodeClient(v2 SDK 沿用同名,bridge 通过 import as 别名使用)。
vi.mock("@opencode-ai/sdk/v2", () => {
  const commandMock = vi.fn()
  const sessionMock = { command: commandMock }
  const clientMock = { session: sessionMock }
  return {
    createOpencodeClient: () => clientMock,
    // 测试中可访问 commandMock 验证调用参数
    __commandMock: commandMock,
  }
})

import { OpencodeBridge } from "./bridge.js"

const { __commandMock: commandMock } = await import("@opencode-ai/sdk/v2") as any

describe("OpencodeBridge runCommand", () => {
  let bridge: OpencodeBridge

  beforeEach(async () => {
    commandMock.mockReset()
    commandMock.mockResolvedValue({ error: undefined })
    bridge = new OpencodeBridge(4096)
    // ensureServer 路径走 mock,跳过真实 spawn
    await bridge.ensureServer()
  })

  it("透传 sessionId/name/args 到 v2 client.session.command", async () => {
    await bridge.runCommand("sess-1", "compact", "保留 env-meta")
    expect(commandMock).toHaveBeenCalledTimes(1)
    const arg = commandMock.mock.calls[0][0]
    expect(arg.sessionID).toBe("sess-1")
    expect(arg.command).toBe("compact")
    expect(arg.arguments).toBe("保留 env-meta")
  })

  it("带 agent/model 时透传, model 序列化为 providerID/modelID 字符串", async () => {
    await bridge.runCommand("sess-1", "new", "", "build", {
      providerID: "zhipuai",
      modelID: "glm-5.2",
    })
    const arg = commandMock.mock.calls[0][0]
    expect(arg.agent).toBe("build")
    expect(arg.model).toBe("zhipuai/glm-5.2")
  })

  it("无 agent/model 时不传这些字段", async () => {
    await bridge.runCommand("sess-1", "init", "")
    const arg = commandMock.mock.calls[0][0]
    expect(arg).not.toHaveProperty("agent")
    expect(arg).not.toHaveProperty("model")
  })
})

describe("OpencodeBridge.summarizeSession", () => {
  let bridge: OpencodeBridge
  let mockClient: { session: { summarize: ReturnType<typeof vi.fn> } }

  beforeEach(() => {
    mockClient = { session: { summarize: vi.fn().mockResolvedValue({}) } }
    bridge = new OpencodeBridge({} as never)
    // requireClient 内部读 this.client,测试里直接塞进去
    ;(bridge as unknown as { client: unknown }).client = mockClient
  })

  it("调 SDK client.session.summarize,path 带 sessionId,body 带 providerID/modelID", async () => {
    await bridge.summarizeSession("ses_abc", "My Coding Plan", "glm-5.2")
    expect(mockClient.session.summarize).toHaveBeenCalledWith({
      path: { id: "ses_abc" },
      body: { providerID: "My Coding Plan", modelID: "glm-5.2" },
    })
  })

  it("404 静默忽略(对称 abortSession/renameSession)", async () => {
    mockClient.session.summarize.mockRejectedValue({
      sdkError: { code: 404 },
    })
    await expect(bridge.summarizeSession("ses_x", "p", "m")).resolves.toBeUndefined()
  })

  it("非 404 错误向上抛", async () => {
    mockClient.session.summarize.mockRejectedValue(new Error("network down"))
    await expect(bridge.summarizeSession("ses_x", "p", "m")).rejects.toThrow("network down")
  })
})

describe("OpencodeBridge.createSession", () => {
  function makeBridgeWithSessionMock(sessionMock: { create: ReturnType<typeof vi.fn> }) {
    const bridge = new OpencodeBridge({} as never)
    ;(bridge as unknown as { client: unknown }).client = { session: sessionMock }
    return bridge
  }

  it("createSession 透传 directory 给 OC SDK", async () => {
    const createMock = vi.fn().mockResolvedValue({ data: { id: "ses-test-123" } })
    const bridge = makeBridgeWithSessionMock({ create: createMock })

    const sessionId = await bridge.createSession("万灵对话", "/home/user/my-project")

    expect(sessionId).toBe("ses-test-123")
    expect(createMock).toHaveBeenCalledTimes(1)
    const args = createMock.mock.calls[0][0]
    expect(args.body.title).toBe("万灵对话")
    expect(args.query.directory).toBe("/home/user/my-project")
  })

  it("createSession 不传 directory 时 query 字段为 undefined", async () => {
    const createMock = vi.fn().mockResolvedValue({ data: { id: "ses-test-456" } })
    const bridge = makeBridgeWithSessionMock({ create: createMock })

    await bridge.createSession("万灵对话")

    const args = createMock.mock.calls[0][0]
    expect(args.body.title).toBe("万灵对话")
    expect(args.query).toBeUndefined()
  })
})

describe("OpencodeBridge.getTurnDuration", () => {
  it("取最后一条 assistant message 的 completed-created(秒),round 1 位小数", async () => {
    const messagesMock = vi.fn().mockResolvedValue({
      data: [
        { info: { role: "user", time: { created: 1000, completed: 1000 } } },
        { info: { role: "assistant", time: { created: 1000, completed: 11234 } } },
      ],
    })
    const bridge = new OpencodeBridge({} as never)
    ;(bridge as unknown as { clientV2: unknown }).clientV2 = {
      session: { messages: messagesMock },
    }

    const duration = await bridge.getTurnDuration("ses-1")
    expect(duration).toBe(10.2) // (11234-1000)/1000 = 10.234 → 10.2
    expect(messagesMock).toHaveBeenCalledWith({ sessionID: "ses-1", limit: 1 })
  })

  it("无 assistant message → 返回 0", async () => {
    const messagesMock = vi.fn().mockResolvedValue({
      data: [{ info: { role: "user", time: { created: 1 } } }],
    })
    const bridge = new OpencodeBridge({} as never)
    ;(bridge as unknown as { clientV2: unknown }).clientV2 = {
      session: { messages: messagesMock },
    }

    expect(await bridge.getTurnDuration("ses-1")).toBe(0)
  })

  it("messages 调用失败 → 返回 0(不抛出)", async () => {
    const messagesMock = vi.fn().mockRejectedValue(new Error("boom"))
    const bridge = new OpencodeBridge({} as never)
    ;(bridge as unknown as { clientV2: unknown }).clientV2 = {
      session: { messages: messagesMock },
    }

    expect(await bridge.getTurnDuration("ses-1")).toBe(0)
  })
})
