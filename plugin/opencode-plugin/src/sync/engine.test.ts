import { describe, it, expect, vi, afterAll, afterEach } from "vitest"
import { rmSync } from "fs"
import { join } from "path"

const TMP = `/tmp/wl-engine-${process.pid}-${Date.now()}`

vi.mock("../config.js", () => ({ configDir: () => TMP }))

afterAll(() => {
  rmSync(TMP, { recursive: true, force: true })
})

// 每个测试前 resetModules + 动态 import engine，确保 engine 与 mapper 共享同一份
// 干净的模块实例（mapper 的内存 cache 也会随之重置）。若用静态 import，engine
// 会绑定 resetModules 之前的旧 mapper，导致 upsertSessionMap 写入对 engine 不可见。
async function freshLoad() {
  vi.resetModules()
  rmSync(join(TMP, "session-maps.json"), { force: true })
  const mod = await import("./engine.js")
  return mod.SyncEngine
}

function makeEngine(SyncEngine: new (...a: any[]) => any, defaultDirectory: string = "", downloader: any = null) {
  const wanling = {
    sendTyping: vi.fn(),
    sendTypedMessage: vi.fn(),
  } as any
  // promptAsync 返回 Promise<void>：bridge.promptAsync 立即返回(204),
  // 实际 LLM 响应走 SSE(streamer 监听),engine 只等投递完成。
  const opencode = {
    getCurrentSession: vi.fn(),
    createSession: vi.fn(),
    promptAsync: vi.fn().mockResolvedValue(undefined),
    runCommand: vi.fn().mockResolvedValue(undefined),
    summarizeSession: vi.fn().mockResolvedValue(undefined),
    renameSession: vi.fn().mockResolvedValue(undefined),
  } as any
  const engine = new SyncEngine(wanling, opencode, defaultDirectory, downloader)
  return { engine, wanling, opencode }
}

describe("SyncEngine handleIncomingMessage session 映射", () => {
  it("未映射 conv 调 createSession 创建新 session（不再用 getCurrentSession 兜底）", async () => {
    const SyncEngine = await freshLoad()
    const { engine, opencode } = makeEngine(SyncEngine)
    opencode.createSession.mockResolvedValue("sess-new-1")

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-A",
      sender_type: "user",
      sender_id: "u1",
      content: { msg_type: "text", data: { text: "hello" } },
    })

    expect(opencode.createSession).toHaveBeenCalledTimes(1)
    expect(opencode.createSession).toHaveBeenCalledWith(expect.stringContaining("万灵"), undefined)
    expect(opencode.getCurrentSession).not.toHaveBeenCalled()
  })

  it("不同 conv 创建不同 session（无 collision）", async () => {
    const SyncEngine = await freshLoad()
    const { engine, opencode } = makeEngine(SyncEngine)
    opencode.createSession.mockResolvedValueOnce("sess-A")
    opencode.createSession.mockResolvedValueOnce("sess-B")

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-A",
      sender_type: "user",
      sender_id: "u1",
      content: { msg_type: "text", data: { text: "hi A" } },
    })
    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-B",
      sender_type: "user",
      sender_id: "u1",
      content: { msg_type: "text", data: { text: "hi B" } },
    })

    expect(opencode.createSession).toHaveBeenCalledTimes(2)
    // 两次 createSession 返回不同 sessionId，各自写入 mapper（无 collision）
    const { getSessionMap } = await import("./mapper.js")
    expect(getSessionMap("conv-A")?.opencodeSessionId).toBe("sess-A")
    expect(getSessionMap("conv-B")?.opencodeSessionId).toBe("sess-B")
  })

  it("已映射 conv 不调 createSession", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-existing",
      opencodeSessionId: "sess-existing",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const { engine, opencode } = makeEngine(SyncEngine)

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-existing",
      sender_type: "user",
      sender_id: "u1",
      content: { msg_type: "text", data: { text: "continue" } },
    })

    expect(opencode.createSession).not.toHaveBeenCalled()
    expect(opencode.promptAsync).toHaveBeenCalledWith("sess-existing", "continue", undefined, undefined)
  })
})

describe("SyncEngine handleIncomingMessage model 透传", () => {
  // APP 端注入 data._model(snake_case WS 协议)→ engine 转 camelCase → opencode body.model
  // 验证 snake→camel 转换的单一真相点在 handleIncomingMessage(不在 bridge)
  it("data._model 透传给 promptAsync(snake_case → camelCase)", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-model-1",
      opencodeSessionId: "sess-model-1",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const { engine, opencode } = makeEngine(SyncEngine)

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-model-1",
      sender_type: "user",
      sender_id: "u1",
      content: {
        msg_type: "text",
        data: {
          text: "你好",
          _mode: "plan",
          _model: { provider_id: "zhipuai", model_id: "glm-5.2-airx" },
        },
      },
    })

    expect(opencode.promptAsync).toHaveBeenCalledWith(
      "sess-model-1",
      "你好",
      "plan",
      { providerID: "zhipuai", modelID: "glm-5.2-airx" },
    )
  })

  it("无 _model 时 promptAsync 第 4 参数 undefined(向后兼容)", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-model-2",
      opencodeSessionId: "sess-model-2",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const { engine, opencode } = makeEngine(SyncEngine)

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-model-2",
      sender_type: "user",
      sender_id: "u1",
      content: { msg_type: "text", data: { text: "你好" } },
    })

    expect(opencode.promptAsync).toHaveBeenCalledWith(
      "sess-model-2",
      "你好",
      undefined,
      undefined)
  })

  // 防御:_model 部分字段缺失(如 APP 端 bug 只传 provider_id)时降级为 undefined,
  // 不传残缺 model 给 opencode(避免 OC 端报 modelID 空错)
  it("_model 缺字段时降级 undefined(不传残缺 model)", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-model-3",
      opencodeSessionId: "sess-model-3",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const { engine, opencode } = makeEngine(SyncEngine)

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-model-3",
      sender_type: "user",
      sender_id: "u1",
      content: {
        msg_type: "text",
        data: {
          text: "你好",
          _model: { provider_id: "zhipuai" },
        },
      },
    })

    expect(opencode.promptAsync).toHaveBeenCalledWith(
      "sess-model-3",
      "你好",
      undefined,
      undefined)
  })
})

describe("SyncEngine prompt 带退避重试", () => {
  afterEach(() => { vi.useRealTimers() })

  it("prompt 首次失败重试后成功,不发「消息投递失败」", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-retry",
      opencodeSessionId: "sess-retry",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const { engine, wanling, opencode } = makeEngine(SyncEngine)
    opencode.promptAsync
      .mockRejectedValueOnce(new Error("fetch failed"))
      .mockResolvedValueOnce(undefined)

    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })

    const p = (engine as any).handleIncomingMessage({
      conversation_id: "conv-retry",
      sender_type: "user",
      sender_id: "u1",
      content: { msg_type: "text", data: { text: "hello" } },
    })
    await vi.runAllTimersAsync()
    await p

    expect(opencode.promptAsync).toHaveBeenCalledTimes(2)
    const failureCall = wanling.sendTypedMessage.mock.calls.find((c: any[]) =>
      typeof c[2]?.text === "string" && c[2].text.includes("消息投递失败"))
    expect(failureCall).toBeUndefined()
  })

  it("prompt 重试 N 次全失败后发「消息投递失败」", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-fail",
      opencodeSessionId: "sess-fail",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const { engine, wanling, opencode } = makeEngine(SyncEngine)
    opencode.promptAsync.mockRejectedValue(new Error("fetch failed"))

    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })

    const p = (engine as any).handleIncomingMessage({
      conversation_id: "conv-fail",
      sender_type: "user",
      sender_id: "u1",
      content: { msg_type: "text", data: { text: "hello" } },
    })
    await vi.runAllTimersAsync()
    await p

    // 初始 1 + 重试 3 = 4 次
    expect(opencode.promptAsync).toHaveBeenCalledTimes(4)
    expect(wanling.sendTypedMessage).toHaveBeenCalledWith(
      "conv-fail", "markdown",
      { text: expect.stringContaining("消息投递失败") },
    )
  })
})

describe("SyncEngine handleConvUpdate 标题同步", () => {
  it("已映射 conv + 非空标题 → 调 renameSession 同步到 OC", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-t1",
      opencodeSessionId: "sess-t1",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const { engine, opencode } = makeEngine(SyncEngine)

    await (engine as any).handleConvUpdate({
      conv_id: "conv-t1",
      title: "新会话名",
      avatar_url: "",
    })

    expect(opencode.renameSession).toHaveBeenCalledTimes(1)
    expect(opencode.renameSession).toHaveBeenCalledWith("sess-t1", "新会话名")
  })

  it("空标题(仅改头像的事件)跳过,不调 renameSession", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-t2",
      opencodeSessionId: "sess-t2",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const { engine, opencode } = makeEngine(SyncEngine)

    await (engine as any).handleConvUpdate({
      conv_id: "conv-t2",
      title: "",
      avatar_url: "http://x/a.png",
    })

    expect(opencode.renameSession).not.toHaveBeenCalled()
  })

  it("未映射 conv 跳过(非 OC 同步会话,如普通 user-user 群)", async () => {
    const SyncEngine = await freshLoad()
    const { engine, opencode } = makeEngine(SyncEngine)

    await (engine as any).handleConvUpdate({
      conv_id: "conv-unmapped",
      title: "随便改",
      avatar_url: "",
    })

    expect(opencode.renameSession).not.toHaveBeenCalled()
  })

  it("renameSession 抛错被捕获,emit error 不向上传播", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-t3",
      opencodeSessionId: "sess-t3",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const { engine, opencode } = makeEngine(SyncEngine)
    opencode.renameSession.mockRejectedValueOnce(new Error("OC 500"))
    const errorSpy = vi.fn()
    engine.on("error", errorSpy)

    await (engine as any).handleConvUpdate({
      conv_id: "conv-t3",
      title: "x",
      avatar_url: "",
    })

    // handleConvUpdate 内部 try/catch 吞掉 renameSession 错误只打日志,
    // 不 emit error(与 handleAbort 一致口径,标题同步失败不阻塞主流程)
    expect(errorSpy).not.toHaveBeenCalled()
  })
})

describe("SyncEngine handleIncomingMessage _slash 分支", () => {
  it("data._slash 存在时调 bridge.runCommand 而非 promptAsync", async () => {
    const SyncEngine = await freshLoad()
    const { engine, opencode } = makeEngine(SyncEngine)
    opencode.createSession = vi.fn().mockResolvedValue("sess-new")

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-slash",
      sender_type: "user",
      sender_id: "u1",
      content: {
        msg_type: "text",
        data: {
          text: "",
          _slash: { name: "init", args: "保留 env-meta" },
        },
      },
    })

    // 应调 runCommand
    expect(opencode.runCommand).toHaveBeenCalledTimes(1)
    const [sessId, name, args] = opencode.runCommand.mock.calls[0]
    expect(sessId).toBe("sess-new")
    expect(name).toBe("init")
    expect(args).toBe("保留 env-meta")
    // 不应调 promptAsync
    expect(opencode.promptAsync).not.toHaveBeenCalled()
  })

  it("_slash 与 _mode 互斥:_slash 存在时 _mode 被忽略", async () => {
    const SyncEngine = await freshLoad()
    const { engine, opencode } = makeEngine(SyncEngine)
    opencode.createSession = vi.fn().mockResolvedValue("sess-new")

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-slash-2",
      sender_type: "user",
      sender_id: "u1",
      content: {
        msg_type: "text",
        data: {
          text: "",
          _mode: "build",
          _slash: { name: "init", args: "" },
        },
      },
    })

    expect(opencode.runCommand).toHaveBeenCalledTimes(1)
    const arg = opencode.runCommand.mock.calls[0]
    // name=init, args=""
    expect(arg[1]).toBe("init")
    expect(arg[2]).toBe("")
    // _mode/_model 互斥:agent 参数必须 undefined
    expect(arg[3]).toBeUndefined()
    // 互斥不变量:_slash 存在时 promptAsync 必须不被调
    expect(opencode.promptAsync).not.toHaveBeenCalled()
  })

  it("runCommand 抛错时发 markdown 错误提示", async () => {
    const SyncEngine = await freshLoad()
    const { engine, wanling, opencode } = makeEngine(SyncEngine)
    opencode.createSession = vi.fn().mockResolvedValue("sess-new")
    opencode.runCommand = vi.fn().mockRejectedValue(new Error("OC 拒绝"))
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {})

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-err",
      sender_type: "user",
      sender_id: "u1",
      content: {
        msg_type: "text",
        data: { text: "", _slash: { name: "init", args: "" } },
      },
    })

    expect(wanling.sendTypedMessage).toHaveBeenCalledWith(
      "conv-err", "markdown",
      expect.objectContaining({ text: expect.stringContaining("消息投递失败") }),
    )
    errSpy.mockRestore()
  })
})

describe("SyncEngine handleIncomingMessage /compact 命令", () => {
  // Task 2: /compact 特判,走 summarizeSession 直击 OC /summarize 真实端点
  it("name=compact 时调 bridge.summarizeSession 而非 runCommand", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "c1",
      opencodeSessionId: "ses_existing",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const { engine, opencode } = makeEngine(SyncEngine)

    await (engine as any).handleIncomingMessage({
      conversation_id: "c1",
      sender_type: "user",
      sender_id: "u1",
      content: {
        msg_type: "text",
        data: {
          text: "",
          _slash: { name: "compact", args: "" },
          _model: { provider_id: "My Coding Plan", model_id: "glm-5.2" },
        },
      },
    })

    expect(opencode.summarizeSession).toHaveBeenCalledWith(
      "ses_existing",
      "My Coding Plan",
      "glm-5.2",
    )
    expect(opencode.runCommand).not.toHaveBeenCalled()
  })

  it("name=compact 缺 _model 时 fail-fast,发失败提示消息", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "c1",
      opencodeSessionId: "ses_existing",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const { engine, wanling, opencode } = makeEngine(SyncEngine)
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {})

    await (engine as any).handleIncomingMessage({
      conversation_id: "c1",
      sender_type: "user",
      sender_id: "u1",
      content: {
        msg_type: "text",
        data: { text: "", _slash: { name: "compact", args: "" } },
      },
    })

    expect(opencode.summarizeSession).not.toHaveBeenCalled()
    const calls = wanling.sendTypedMessage.mock.calls
    expect(
      calls.some(
        (c: any[]) =>
          c[1] === "markdown" && String(c[2]?.text).includes("失败"),
      ),
    ).toBe(true)
    errSpy.mockRestore()
  })

  it("name=其他命令 走原 runCommand 路径不受影响", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "c1",
      opencodeSessionId: "ses_existing",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const { engine, opencode } = makeEngine(SyncEngine)

    await (engine as any).handleIncomingMessage({
      conversation_id: "c1",
      sender_type: "user",
      sender_id: "u1",
      content: {
        msg_type: "text",
        data: { text: "", _slash: { name: "clear", args: "" } },
      },
    })

    expect(opencode.runCommand).toHaveBeenCalled()
    expect(opencode.summarizeSession).not.toHaveBeenCalled()
  })
})

describe("SyncEngine ensureSession _directory 透传", () => {
  it("data._directory 透传给 createSession(优先级最高)", async () => {
    const SyncEngine = await freshLoad()
    const { engine, opencode } = makeEngine(SyncEngine, "/configured/default")
    opencode.createSession.mockResolvedValue("sess-dir-1")

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-dir-1",
      sender_type: "user",
      sender_id: "u1",
      content: {
        msg_type: "text",
        data: { text: "hello", _directory: "/home/user/proj" },
      },
    })

    expect(opencode.createSession).toHaveBeenCalledWith("万灵对话", "/home/user/proj")
  })

  it("data._directory 缺时用 defaultDirectory 兜底", async () => {
    const SyncEngine = await freshLoad()
    const { engine, opencode } = makeEngine(SyncEngine, "/default/dir")
    opencode.createSession.mockResolvedValue("sess-dir-2")

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-dir-2",
      sender_type: "user",
      sender_id: "u1",
      content: { msg_type: "text", data: { text: "hello" } },
    })

    expect(opencode.createSession).toHaveBeenCalledWith("万灵对话", "/default/dir")
  })

  it("data._directory 和 defaultDirectory 都缺时为 undefined(OC 用 PLUGIN_DIR)", async () => {
    const SyncEngine = await freshLoad()
    const { engine, opencode } = makeEngine(SyncEngine)
    opencode.createSession.mockResolvedValue("sess-dir-3")

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-dir-3",
      sender_type: "user",
      sender_id: "u1",
      content: { msg_type: "text", data: { text: "hello" } },
    })

    expect(opencode.createSession).toHaveBeenCalledWith("万灵对话", undefined)
  })
})

// 注意:directory 改造后升级为 conversations.directory 一级列,
// engine.handleIncomingMessage 仍透传 directory 给 OC createSession(OC 才是真相源),
// 但不再写 mapper.directory 字段。旧 session-maps.json 回填逻辑已废弃。

describe("SyncEngine handleIncomingMessage image/file/mixed 分支", () => {
  it("image 消息 → downloader 下载 → promptAsync 收到路径提示文本", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-img",
      opencodeSessionId: "sess-img",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const downloader = {
      download: vi.fn().mockResolvedValue({
        path: "/cache/abc.png",
        mime: "image/png",
        filename: "abc.png",
      }),
    }
    const { engine, opencode } = makeEngine(SyncEngine, "", downloader)

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-img",
      sender_type: "user",
      sender_id: "u1",
      content: {
        msg_type: "image",
        data: { file_id: "abc", filename: "cat.png" },
      },
    })

    expect(downloader.download).toHaveBeenCalledWith({
      fileId: "abc",
      expectedExt: ".png",
    })
    expect(opencode.promptAsync).toHaveBeenCalledWith(
      "sess-img",
      "[用户发送了一张图片,位于: /cache/abc.png]",
      undefined,
      undefined,
    )
  })

  it("file 消息 → downloader 下载 → promptAsync 收到文件路径提示", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-file",
      opencodeSessionId: "sess-file",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const downloader = {
      download: vi.fn().mockResolvedValue({
        path: "/cache/rep.pdf",
        mime: "application/pdf",
        filename: "rep.pdf",
      }),
    }
    const { engine, opencode } = makeEngine(SyncEngine, "", downloader)

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-file",
      sender_type: "user",
      sender_id: "u1",
      content: {
        msg_type: "file",
        data: { file_id: "rep", filename: "report.pdf" },
      },
    })

    expect(opencode.promptAsync).toHaveBeenCalledWith(
      "sess-file",
      "[用户发送了一个文件,位于: /cache/rep.pdf]",
      undefined,
      undefined,
    )
  })

  it("mixed 消息按 items 全量下载,路径以「、」拼接进提示", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-mix",
      opencodeSessionId: "sess-mix",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const downloader = {
      download: vi.fn().mockResolvedValue({
        path: "/cache/m.png",
        mime: "image/png",
        filename: "m.png",
      }),
    }
    const { engine, opencode } = makeEngine(SyncEngine, "", downloader)

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-mix",
      sender_type: "user",
      sender_id: "u1",
      content: {
        msg_type: "mixed",
        data: {
          items: [
            { type: "image", file_id: "mix-1", filename: "m.png" },
            { type: "file", file_id: "mix-2" },
          ],
        },
      },
    })

    // 两个条目都下载:图片条目带 expectedExt(从 filename 推),文件条目无
    expect(downloader.download).toHaveBeenNthCalledWith(1, {
      fileId: "mix-1",
      expectedExt: ".png",
    })
    expect(downloader.download).toHaveBeenNthCalledWith(2, {
      fileId: "mix-2",
      expectedExt: undefined,
    })
    expect(opencode.promptAsync).toHaveBeenCalledWith(
      "sess-mix",
      "[用户发送了混合内容,位于: /cache/m.png、/cache/m.png]",
      undefined,
      undefined,
    )
  })

  it("mixed 多附件部分下载失败 → 提示仅含成功路径", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-mix-partial",
      opencodeSessionId: "sess-mix-partial",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const downloader = {
      download: vi
        .fn()
        .mockResolvedValueOnce({
          path: "/cache/ok.png",
          mime: "image/png",
          filename: "ok.png",
        })
        .mockRejectedValueOnce(new Error("download failed")),
    }
    const { engine, opencode } = makeEngine(SyncEngine, "", downloader)

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-mix-partial",
      sender_type: "user",
      sender_id: "u1",
      content: {
        msg_type: "mixed",
        data: {
          items: [
            { type: "image", file_id: "ok-1" },
            { type: "file", file_id: "bad-1" },
          ],
        },
      },
    })

    expect(downloader.download).toHaveBeenCalledTimes(2)
    expect(opencode.promptAsync).toHaveBeenCalledWith(
      "sess-mix-partial",
      "[用户发送了混合内容,位于: /cache/ok.png]",
      undefined,
      undefined,
    )
  })

  it("mixed 带 text 时提示文本携带用户文字", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-mix3",
      opencodeSessionId: "sess-mix3",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const downloader = {
      download: vi.fn().mockResolvedValue({
        path: "/cache/t.png",
        mime: "image/png",
        filename: "t.png",
      }),
    }
    const { engine, opencode } = makeEngine(SyncEngine, "", downloader)

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-mix3",
      sender_type: "user",
      sender_id: "u1",
      content: {
        msg_type: "mixed",
        data: {
          text: "帮我看下这个报错",
          items: [{ type: "image", file_id: "mix-3" }],
        },
      },
    })

    expect(opencode.promptAsync).toHaveBeenCalledWith(
      "sess-mix3",
      "[用户发送了混合内容: 帮我看下这个报错,位于: /cache/t.png]",
      undefined,
      undefined,
    )
  })

  it("mixed 无 text 时提示文本维持原样(不含空冒号)", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-mix4",
      opencodeSessionId: "sess-mix4",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const downloader = {
      download: vi.fn().mockResolvedValue({
        path: "/cache/u.png",
        mime: "image/png",
        filename: "u.png",
      }),
    }
    const { engine, opencode } = makeEngine(SyncEngine, "", downloader)

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-mix4",
      sender_type: "user",
      sender_id: "u1",
      content: {
        msg_type: "mixed",
        data: {
          items: [{ type: "image", file_id: "mix-4" }],
        },
      },
    })

    expect(opencode.promptAsync).toHaveBeenCalledWith(
      "sess-mix4",
      "[用户发送了混合内容,位于: /cache/u.png]",
      undefined,
      undefined,
    )
  })

  it("mixed 顶层 file_id 兜底(items 缺失时)", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-mix2",
      opencodeSessionId: "sess-mix2",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const downloader = {
      download: vi.fn().mockResolvedValue({
        path: "/cache/top.png",
        mime: "image/png",
        filename: "top.png",
      }),
    }
    const { engine } = makeEngine(SyncEngine, "", downloader)

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-mix2",
      sender_type: "user",
      sender_id: "u1",
      content: {
        msg_type: "mixed",
        data: { file_id: "top-id", filename: "top.png" },
      },
    })

    expect(downloader.download).toHaveBeenCalledWith({
      fileId: "top-id",
      expectedExt: ".png",
    })
  })

  it("file_id 缺失时 warn 跳过,不调 downloader/promptAsync", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-noid",
      opencodeSessionId: "sess-noid",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const downloader = { download: vi.fn() }
    const { engine, opencode } = makeEngine(SyncEngine, "", downloader)
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {})

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-noid",
      sender_type: "user",
      sender_id: "u1",
      content: { msg_type: "image", data: {} },
    })

    expect(downloader.download).not.toHaveBeenCalled()
    expect(opencode.promptAsync).not.toHaveBeenCalled()
    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("missing file_id"))
    warnSpy.mockRestore()
  })

  it("下载失败时退化文本,不抛错", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-dlfail",
      opencodeSessionId: "sess-dlfail",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const downloader = {
      download: vi.fn().mockRejectedValue(new Error("http 404")),
    }
    const { engine, opencode } = makeEngine(SyncEngine, "", downloader)
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {})

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-dlfail",
      sender_type: "user",
      sender_id: "u1",
      content: { msg_type: "image", data: { file_id: "broken" } },
    })

    expect(opencode.promptAsync).toHaveBeenCalledWith(
      "sess-dlfail",
      "[用户发送了一张图片,但下载失败]",
      undefined,
      undefined,
    )
    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("download failed"))
    warnSpy.mockRestore()
  })

  it("text 消息回归 — 不调 downloader,走原 promptAsync 路径", async () => {
    const SyncEngine = await freshLoad()
    const { upsertSessionMap } = await import("./mapper.js")
    upsertSessionMap({
      wanlingConvId: "conv-reg",
      opencodeSessionId: "sess-reg",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const downloader = { download: vi.fn() }
    const { engine, opencode } = makeEngine(SyncEngine, "", downloader)

    await (engine as any).handleIncomingMessage({
      conversation_id: "conv-reg",
      sender_type: "user",
      sender_id: "u1",
      content: { msg_type: "text", data: { text: "普通消息" } },
    })

    expect(downloader.download).not.toHaveBeenCalled()
    expect(opencode.promptAsync).toHaveBeenCalledWith(
      "sess-reg", "普通消息", undefined, undefined)
  })
})

describe("SyncEngine syncCliToApp silent 对齐", () => {
  it("user 消息(tui_user)带 silent:true,与 proxy 实时路径对齐", async () => {
    const SyncEngine = await freshLoad()
    const { engine, wanling, opencode } = makeEngine(SyncEngine)
    opencode.getMessageHistory = vi.fn().mockResolvedValue([
      { role: "user", text: "终端敲的" },
      { role: "assistant", text: "回复" },
    ])

    await (engine as any).syncCliToApp("conv-x", "sess-x")

    // user → tui_user,必须带 silent:true(与 proxy/http.ts trySyncPrompt 对齐,
    // 否则批量回填的 tui_user 会给 user 产生未读,而实时路径的 tui_user 是 silent)
    expect(wanling.sendTypedMessage).toHaveBeenCalledWith(
      "conv-x", "tui_user", { text: "终端敲的" }, { silent: true },
    )
  })
})

describe("SyncEngine 聚合模式反向流(APP 答 → 跳过独立卡 PATCH,交给 OC echo)", () => {
  it("permission entry 带 elementId → 不 PATCH 独立卡,不 deleteCard(留给 interaction echo 更新聚合元素)", async () => {
    const SyncEngine = await freshLoad()
    const { saveCard, getCard } = await import("./card_store.js")
    const { engine, wanling, opencode } = makeEngine(SyncEngine)
    opencode.replyPermission = vi.fn().mockResolvedValue(undefined)
    wanling.updateMessageContent = vi.fn().mockResolvedValue(undefined)
    saveCard("req-agg-perm", {
      msgId: "agg-card-1",
      convId: "conv-A",
      type: "permission",
      data: { action: "bash", resources: ["*.sh"] },
      elementId: "permission_card_1",
      sessionId: "sess-main",
    })

    await (engine as any).handlePermissionReply("conv-A", { oc_request_id: "req-agg-perm", reply: "once" })

    // 聚合模式:独立卡 PATCH 不再适用(会把聚合卡整个改写坏),交回声处理
    expect(wanling.updateMessageContent).not.toHaveBeenCalled()
    // 不 deleteCard:entry 保留给 permission.replied 回声 → interaction.onPermissionReplied 更新聚合元素
    expect(getCard("req-agg-perm")).not.toBeNull()
    // OC 回复仍正常投递
    expect(opencode.replyPermission).toHaveBeenCalledWith("req-agg-perm", "once", undefined)
  })

  it("question entry 带 elementId(rejected)→ 不 PATCH 独立卡,不 deleteCard", async () => {
    const SyncEngine = await freshLoad()
    const { saveCard, getCard } = await import("./card_store.js")
    const { engine, wanling, opencode } = makeEngine(SyncEngine)
    opencode.rejectQuestion = vi.fn().mockResolvedValue(undefined)
    wanling.updateMessageContent = vi.fn().mockResolvedValue(undefined)
    saveCard("req-agg-q", {
      msgId: "agg-card-1",
      convId: "conv-A",
      type: "question",
      data: { questions: [] },
      elementId: "question_card_2",
      sessionId: "sess-main",
    })

    await (engine as any).handleQuestionReply("conv-A", { oc_request_id: "req-agg-q", rejected: true })

    expect(wanling.updateMessageContent).not.toHaveBeenCalled()
    expect(getCard("req-agg-q")).not.toBeNull()
    expect(opencode.rejectQuestion).toHaveBeenCalledWith("req-agg-q", undefined)
  })

  it("非聚合 entry(无 elementId)→ 保持旧逻辑:对独立卡 updateMessageContent PATCH + deleteCard", async () => {
    const SyncEngine = await freshLoad()
    const { saveCard, getCard } = await import("./card_store.js")
    const { engine, wanling, opencode } = makeEngine(SyncEngine)
    opencode.replyPermission = vi.fn().mockResolvedValue(undefined)
    wanling.updateMessageContent = vi.fn().mockResolvedValue(undefined)
    saveCard("req-standalone", {
      msgId: "perm-msg-1",
      convId: "conv-A",
      type: "permission",
      data: { action: "bash", resources: ["*.sh"] },
    })

    await (engine as any).handlePermissionReply("conv-A", { oc_request_id: "req-standalone", reply: "once" })

    expect(wanling.updateMessageContent).toHaveBeenCalledWith(
      "perm-msg-1",
      expect.objectContaining({
        msg_type: "permission_card",
        data: expect.objectContaining({ status: "approved", result: "once", oc_request_id: "req-standalone" }),
      }),
    )
    expect(getCard("req-standalone")).toBeNull()
  })
})
