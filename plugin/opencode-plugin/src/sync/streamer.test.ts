import { describe, it, expect, vi, beforeEach, afterEach, afterAll } from "vitest"
import { rmSync } from "fs"

const TMP = `/tmp/wl-st-${Date.now()}`

vi.mock("./mapper.js", () => ({
  findBySessionId: vi.fn(() => undefined),
  upsertSessionMap: vi.fn(),
  drainPendingTuiMessages: vi.fn(() => []),
}))
vi.mock("../config.js", () => ({ configDir: () => TMP }))

afterAll(() => {
  rmSync(TMP, { recursive: true, force: true })
})

const { Streamer } = await import("./streamer.js")
const { _resetInflight } = await import("./ensure_conversation.js")
const { findBySessionId } = await import("./mapper.js")
const { RPCDispatcher } = await import("../rpc/dispatcher.js")
const { PartDispatcher } = await import("./domains/part_dispatcher.js")
import { EventEmitter } from "events"
import type { SessionState } from "./types.js"

function makeStreamer(mainSessionId: string, opts: { dispatcher?: RPCDispatcher; agentId?: string } = {}) {
  const subscriber = { on: vi.fn(), start: vi.fn() } as any
  const wanling = {
    sendTypedMessage: vi.fn(),
    sendCardMessage: vi.fn().mockResolvedValue("msg-id"),
    sendSessionStatus: vi.fn(),
    updateMessageContent: vi.fn().mockResolvedValue(undefined),
    createGroupAsAgent: vi.fn().mockResolvedValue("conv-new"),
    updateConversationTitle: vi.fn(),
    updateSessionMeta: vi.fn().mockResolvedValue(undefined),
    sendAgentSlashCatalog: vi.fn(),
    sendPluginCapabilities: vi.fn(),
    sendStream: vi.fn(),
    // agentId 缺省 = "agent-test";opts.agentId=undefined 时显式删字段(模拟 wanling client 未拿到 agentId)
    agentId: opts.agentId ?? "agent-test",
  } as any
  if (opts.agentId === undefined && "agentId" in opts) delete wanling.agentId
  const opencode = { getSessionTitle: vi.fn().mockResolvedValue(""), getSessionDirectory: vi.fn().mockResolvedValue(""), getClient: vi.fn(() => null) } as any
  const dispatcher = opts.dispatcher ?? new RPCDispatcher()
  const streamer = new Streamer(subscriber, wanling, mainSessionId, { opencode, ownerUserId: "u" } as any, dispatcher)
  return { streamer, wanling, opencode, dispatcher }
}

describe("Streamer 路由判定", () => {
  beforeEach(() => _resetInflight())

  it("非主 session 事件丢弃(不建群不发消息)", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    await (streamer as any).onPartUpdated({
      sessionID: "sess-child",
      part: { type: "text", id: "p1", text: "hi", time: { end: 1 } },
      time: 1,
    })
    expect(wanling.createGroupAsAgent).not.toHaveBeenCalled()
    expect(wanling.sendTypedMessage).not.toHaveBeenCalled()
  })

  it("主 session 首事件触发建群", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: { type: "text", id: "p1", text: "hello", time: { end: 1 } },
      time: 1,
    })
    expect(wanling.createGroupAsAgent).toHaveBeenCalledWith(
      "agent_session", expect.any(String), { userId: "u" },
    )
  })
})

describe("Streamer tool_card PATCH 竞态修复", () => {
  beforeEach(() => _resetInflight())

  it("sendCardMessage 飞行中 completed 事件到达时,应 await inflight 拿到 msgId 后 PATCH", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")

    // 用 deferred 控 sendCardMessage 的 resolve 时机,模拟 WS 往返时延
    let resolveSend: (v: string) => void = () => {}
    const sendPromise = new Promise<string>((r) => { resolveSend = r })
    wanling.sendCardMessage.mockReturnValue(sendPromise)

    // 1) running 事件:setPending + setImmediate 排队 _flushPendingToolCard
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: { type: "tool", id: "p-tool-1", tool: "bash",
        state: { status: "running", input: { command: "ls" } } },
      time: 1,
    })

    // 2) 排空 setImmediate 队列 → _flushPendingToolCard 同步发起 sendCardMessage(promise 仍飞行)
    await new Promise((r) => setImmediate(r))

    // 此时 toolCardMsgIds 还没收到 msgId, completed 事件抢先到达
    const completedP = (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: { type: "tool", id: "p-tool-1", tool: "bash",
        state: { status: "completed", input: { command: "ls" }, output: "done" } },
      time: 2,
    })

    // 3) sendCardMessage 真正 resolve → completed 才能拿到 msgId 做 PATCH
    resolveSend("msg-id-xyz")
    await completedP

    expect(wanling.updateMessageContent).toHaveBeenCalledWith(
      "msg-id-xyz",
      expect.objectContaining({ msg_type: "tool_card" }),
    )
  })
})

describe("Streamer 子 session 透传", () => {
  beforeEach(() => _resetInflight())

  it("childSessionTree 命中时返回子 state,不再丢弃", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    // 模拟 task/running 已建立映射
    const tree = (streamer as any).childSessionTree as Map<string, any>
    const childState = { reasoning: null, text: null, convId: "conv-new", toolPartsSent: new Set(), textPartsFlushed: new Set(), toolCardMsgIds: new Map(), toolCardInflight: new Map() }
    tree.set("sess-child", {
      parentMsgId: "task-msg-1",
      rootMsgId: "task-msg-1",
      depth: 1,
      state: childState,
      parentSessionId: "sess-main",
      hasFirstEvent: false,
    })

    // 子 session 的 text 事件应被处理,不丢弃
    await (streamer as any).onPartUpdated({
      sessionID: "sess-child",
      part: { type: "text", id: "p1", text: "子 agent 输出", time: { end: 1 } },
      time: 1,
    })

    // 应通过 sendTypedMessage 发到主群 conv
    expect(wanling.sendTypedMessage).toHaveBeenCalledWith(
      "conv-new", "markdown",
      expect.objectContaining({ text: "子 agent 输出" }),
      expect.objectContaining({ parentMsgId: "task-msg-1", rootMsgId: "task-msg-1" }),
    )
  })

  it("子 session 首事件触发 parent task 卡片 working PATCH", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    const tree = (streamer as any).childSessionTree as Map<string, any>
    const childState = { reasoning: null, text: null, convId: "conv-new", toolPartsSent: new Set(), textPartsFlushed: new Set(), toolCardMsgIds: new Map(), toolCardInflight: new Map() }
    tree.set("sess-child", {
      parentMsgId: "task-msg-1",
      rootMsgId: "task-msg-1",
      depth: 1,
      state: childState,
      parentSessionId: "sess-main",
      hasFirstEvent: false,
    })

    await (streamer as any).onPartUpdated({
      sessionID: "sess-child",
      part: { type: "text", id: "p1", text: "子 agent 输出", time: { end: 1 } },
      time: 1,
    })

    expect(wanling.updateMessageContent).toHaveBeenCalledWith(
      "task-msg-1",
      expect.objectContaining({ msg_type: "tool_card", data: expect.objectContaining({ status: "working" }) }),
    )
  })

  it("子 session 的 tool_card 创建带 parent/root", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    wanling.sendCardMessage.mockResolvedValue("child-tool-msg-1")

    const tree = (streamer as any).childSessionTree as Map<string, any>
    const childState = { reasoning: null, text: null, convId: "conv-new", toolPartsSent: new Set(), textPartsFlushed: new Set(), toolCardMsgIds: new Map(), toolCardInflight: new Map(), isChildSession: true }
    const childEntry = { parentMsgId: "task-msg-1", rootMsgId: "task-msg-1", depth: 1, state: childState, parentSessionId: "sess-main", hasFirstEvent: true }
    childState.childEntry = childEntry
    tree.set("sess-child", childEntry)

    await (streamer as any).onPartUpdated({
      sessionID: "sess-child",
      part: {
        type: "tool", id: "p-tool-1", tool: "bash", callID: "call-1",
        state: { status: "running", input: { command: "ls" } },
      },
      time: 1,
    })

    await new Promise((r) => setImmediate(r))
    await Promise.resolve()

    expect(wanling.sendCardMessage).toHaveBeenCalledWith(
      "conv-new", "tool_card",
      expect.objectContaining({ name: "bash" }),
      expect.objectContaining({ parentMsgId: "task-msg-1", rootMsgId: "task-msg-1" }),
    )
  })
})

describe("Streamer task 卡片 3 状态机", () => {
  beforeEach(() => _resetInflight())

  it("task/running 建 childSessionTree 映射 + 卡片 starting;子首事件 PATCH working;task/completed PATCH completed", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    wanling.sendCardMessage.mockResolvedValue("task-msg-1")

    // 1) task/running,带 metadata.sessionId
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "tool", id: "p-task-1", tool: "task", callID: "call-1",
        state: {
          status: "running",
          input: { description: "测试任务", subagent_type: "general", prompt: "..." },
          metadata: { parentSessionId: "sess-main", sessionId: "sess-child-1" },
        },
      },
      time: 1,
    })

    // 等待 setImmediate + sendCardMessage
    await new Promise((r) => setImmediate(r))
    await Promise.resolve()

    // 验证：卡片以 starting 创建（sendCardByState 路由第 4 参数为 undefined,父 session 无 parent/root）
    expect(wanling.sendCardMessage).toHaveBeenCalledWith(
      "conv-new", "tool_card",
      expect.objectContaining({
        name: "task",
        status: "starting",
        sub_session_id: "sess-child-1",
      }),
      undefined,
    )

    // 验证：childSessionTree 已建立
    const tree = (streamer as any).childSessionTree as Map<string, any>
    expect(tree.has("sess-child-1")).toBe(true)

    // 2) 子 session 首事件 → PATCH working
    await (streamer as any).onPartUpdated({
      sessionID: "sess-child-1",
      part: { type: "reasoning", id: "p-r-1", text: "思考", time: { start: 1 } },
      time: 2,
    })

    expect(wanling.updateMessageContent).toHaveBeenCalledWith(
      "task-msg-1",
      expect.objectContaining({
        msg_type: "tool_card",
        data: expect.objectContaining({ status: "working" }),
      }),
    )

    // 3) task/completed → PATCH completed + 清理映射
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "tool", id: "p-task-1", tool: "task", callID: "call-1",
        state: {
          status: "completed",
          input: { description: "测试任务", subagent_type: "general", prompt: "..." },
          output: "<task_result>结果</task_result>",
          metadata: { parentSessionId: "sess-main", sessionId: "sess-child-1" },
        },
      },
      time: 3,
    })

    expect(wanling.updateMessageContent).toHaveBeenCalledWith(
      "task-msg-1",
      expect.objectContaining({
        msg_type: "tool_card",
        data: expect.objectContaining({ status: "completed" }),
      }),
    )

    // 验证：childSessionTree 已清理
    expect(tree.has("sess-child-1")).toBe(false)
  })

  it("task/completed PATCH 抛错时保留 childSessionTree + 兜底 timer(让 30min 兜底兜住)", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    wanling.sendCardMessage.mockResolvedValue("task-msg-1")
    // 模拟 completed PATCH 网络失败
    wanling.updateMessageContent.mockRejectedValueOnce(new Error("PATCH 网络抖动"))

    // 1) task/running 建映射
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "tool", id: "p-task-1", tool: "task", callID: "call-1",
        state: {
          status: "running",
          input: { description: "测试", prompt: "..." },
          metadata: { parentSessionId: "sess-main", sessionId: "sess-child-1" },
        },
      },
      time: 1,
    })
    await new Promise((r) => setImmediate(r))
    await Promise.resolve()

    const tree = (streamer as any).childSessionTree as Map<string, any>
    expect(tree.has("sess-child-1")).toBe(true)

    // 2) task/completed,updateMessageContent 会 reject
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "tool", id: "p-task-1", tool: "task", callID: "call-1",
        state: {
          status: "completed",
          input: { description: "测试", prompt: "..." },
          output: "<task_result>结果</task_result>",
          metadata: { parentSessionId: "sess-main", sessionId: "sess-child-1" },
        },
      },
      time: 2,
    })
    errSpy.mockRestore()

    // 验证:PATCH 确实尝试过
    expect(wanling.updateMessageContent).toHaveBeenCalledWith(
      "task-msg-1",
      expect.objectContaining({ data: expect.objectContaining({ status: "completed" }) }),
    )
    // 关键断言:PATCH 失败时保留 childSessionTree + 兜底 timer,
    // 让 30min 兜底机制后续能 PATCH error(避免卡片永卡 working,旧实现 finally 一定
    // cleanup 反而拆掉自己的兜底)
    expect(tree.has("sess-child-1")).toBe(true)
    expect(tree.get("sess-child-1").cleanupTimer).toBeDefined()
  })

  it("task/error PATCH 抛错时保留 childSessionTree + 兜底 timer", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    wanling.sendCardMessage.mockResolvedValue("task-msg-1")
    wanling.updateMessageContent.mockRejectedValueOnce(new Error("PATCH 网络抖动"))

    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "tool", id: "p-task-2", tool: "task", callID: "call-2",
        state: {
          status: "running",
          input: { description: "测试", prompt: "..." },
          metadata: { parentSessionId: "sess-main", sessionId: "sess-child-2" },
        },
      },
      time: 1,
    })
    await new Promise((r) => setImmediate(r))
    await Promise.resolve()

    const tree = (streamer as any).childSessionTree as Map<string, any>

    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "tool", id: "p-task-2", tool: "task", callID: "call-2",
        state: {
          status: "error",
          input: { description: "测试", prompt: "..." },
          error: "子 agent 爆炸",
          metadata: { parentSessionId: "sess-main", sessionId: "sess-child-2" },
        },
      },
      time: 2,
    })
    errSpy.mockRestore()

    expect(wanling.updateMessageContent).toHaveBeenCalledWith(
      "task-msg-1",
      expect.objectContaining({ data: expect.objectContaining({ status: "error" }) }),
    )
    // PATCH 失败时保留 childSessionTree + 兜底 timer(同 completed 分支口径)
    expect(tree.has("sess-child-2")).toBe(true)
    expect(tree.get("sess-child-2").cleanupTimer).toBeDefined()
  })
})

describe("Streamer childSessionTree 兜底超时", () => {
  beforeEach(() => _resetInflight())
  afterEach(() => { vi.useRealTimers() })

  it("子 session 30min 未完成 → 兜底 timer 清理 + PATCH 父卡片(防 SSE gap 泄漏)", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    wanling.sendCardMessage.mockResolvedValue("task-msg-1")
    wanling.updateMessageContent.mockResolvedValue(undefined)
    // 仅 fake setTimeout/clearTimeout,setImmediate 保持真实(注册链路依赖 setImmediate)
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })

    // 1) task/running 注册 childSessionTree + 设置 30min 兜底 timer
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "tool", id: "p-task-t", tool: "task", callID: "call-t",
        state: {
          status: "running",
          input: { description: "测试", prompt: "..." },
          metadata: { parentSessionId: "sess-main", sessionId: "sess-child-t" },
        },
      },
      time: 1,
    })
    await new Promise((r) => setImmediate(r))
    await Promise.resolve()

    const tree = (streamer as any).childSessionTree as Map<string, any>
    expect(tree.has("sess-child-t")).toBe(true)
    expect(tree.get("sess-child-t").cleanupTimer).toBeDefined()

    // 2) 推进 30min,timer 触发清理 + PATCH 父卡片为 error + 告警日志
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {})
    vi.advanceTimersByTime(30 * 60 * 1000)
    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("子 session 超时未完成"))
    warnSpy.mockRestore()

    expect(tree.has("sess-child-t")).toBe(false)
    // I-N:超时应 PATCH 父卡片为 error,不只删 map
    expect(wanling.updateMessageContent).toHaveBeenCalledWith("task-msg-1", expect.objectContaining({
      msg_type: "tool_card",
      data: expect.objectContaining({ name: "task", status: "error" }),
    }))
  })

  it("正常路径 task/completed 清理时 clearTimeout 撤销兜底 timer(不误触发)", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    wanling.sendCardMessage.mockResolvedValue("task-msg-1")
    // 监视 clearTimeout,断言正常终态清理时调用过(撤销兜底 timer)。
    // 注意:必须先 useFakeTimers 再 spyOn,否则 fake timer 会覆盖 spy 导致记录丢失。
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })
    const clearSpy = vi.spyOn(globalThis, "clearTimeout")

    // task/running 注册 + 设兜底 timer
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "tool", id: "p-task-c", tool: "task", callID: "call-c",
        state: {
          status: "running",
          input: { description: "测试", prompt: "..." },
          metadata: { parentSessionId: "sess-main", sessionId: "sess-child-c" },
        },
      },
      time: 1,
    })
    await new Promise((r) => setImmediate(r))
    await Promise.resolve()

    const tree = (streamer as any).childSessionTree as Map<string, any>
    expect(tree.has("sess-child-c")).toBe(true)
    clearSpy.mockClear()

    // task/completed 正常终态 → cleanupChildSession 撤销 timer + 删除条目
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "tool", id: "p-task-c", tool: "task", callID: "call-c",
        state: {
          status: "completed",
          input: { description: "测试", prompt: "..." },
          output: "ok",
          metadata: { parentSessionId: "sess-main", sessionId: "sess-child-c" },
        },
      },
      time: 2,
    })

    expect(clearSpy).toHaveBeenCalled()
    expect(tree.has("sess-child-c")).toBe(false)

    // 推进 30min,兜底 timer 不应再触发(已被 clearTimeout)
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {})
    vi.advanceTimersByTime(30 * 60 * 1000)
    expect(warnSpy).not.toHaveBeenCalled()
    warnSpy.mockRestore()
    clearSpy.mockRestore()
  })

  it("I-A: task/completed 抢占 setImmediate 时分支 3 同步注册 childSessionTree(防数据丢失)", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    wanling.sendCardMessage.mockResolvedValue("task-msg-preempt")
    wanling.updateMessageContent.mockResolvedValue(undefined)

    // 1) task/running 入 pendingToolCard + 排 setImmediate,但**不让 setImmediate 跑**
    //    (不 await new Promise(setImmediate),模拟 task/completed 在 setImmediate 触发前到达)
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "tool", id: "p-task-preempt", tool: "task", callID: "call-preempt",
        state: {
          status: "running",
          input: { description: "抢占测试", prompt: "..." },
          metadata: { parentSessionId: "sess-main", sessionId: "sess-child-preempt" },
        },
      },
      time: 1,
    })

    // 此时 setImmediate 还在事件队列里,pendingToolCard 仍在
    const state = (streamer as any).sessions.get("sess-main")
    expect(state.pendingToolCard).toBeDefined()

    // 2) task/completed 抢先到达 → _resolveToolCardMsgId 走分支 3 同步消费 pending
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "tool", id: "p-task-preempt", tool: "task", callID: "call-preempt",
        state: {
          status: "completed",
          input: { description: "抢占测试", prompt: "..." },
          output: "preempt result",
          metadata: { parentSessionId: "sess-main", sessionId: "sess-child-preempt" },
        },
      },
      time: 2,
    })

    // 排空 setImmediate(此时 pending 已被分支 3 消费,_flushPendingToolCard 应直接 return)
    await new Promise((r) => setImmediate(r))
    await Promise.resolve()

    // 验证:I-A 修复 — childSessionTree 注册发生过(否则子 session 后续事件全部丢失)。
    // task/completed 的 finally 块会调 cleanupChildSession 清理,所以这里 tree 已清空
    // (注册 → 立刻 cleanup 是正常流程,关键是中间「注册」发生了,子 session 事件在 completed
    // PATCH 期间能命中透传路径)。
    // 用 spy 验证注册日志被打印过(间接证明 _registerChildSession 被调用)
    const logSpy = vi.spyOn(console, "log").mockImplementation(() => {})
    // 重新触发一次抢占场景验证日志(原场景 tree 已被清理,改用 spy 断言)
    wanling.sendCardMessage.mockResolvedValue("task-msg-preempt-2")
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "tool", id: "p-task-preempt-2", tool: "task", callID: "call-preempt-2",
        state: {
          status: "running",
          input: { description: "抢占测试 2", prompt: "..." },
          metadata: { parentSessionId: "sess-main", sessionId: "sess-child-preempt-2" },
        },
      },
      time: 3,
    })
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "tool", id: "p-task-preempt-2", tool: "task", callID: "call-preempt-2",
        state: {
          status: "completed",
          input: { description: "抢占测试 2", prompt: "..." },
          output: "preempt result 2",
          metadata: { parentSessionId: "sess-main", sessionId: "sess-child-preempt-2" },
        },
      },
      time: 4,
    })
    await new Promise((r) => setImmediate(r))
    await Promise.resolve()
    // 注册日志应含 childSessionTree 注册字样 + child session id 前缀
    expect(logSpy).toHaveBeenCalledWith(expect.stringContaining("childSessionTree 注册"))
    expect(logSpy).toHaveBeenCalledWith(expect.stringContaining("sess-child-preempt-2".slice(0, 12)))
    logSpy.mockRestore()

    // 验证:卡片以 starting 创建(不是 running — 分支 3 task 特化),sub_session_id 正确
    expect(wanling.sendCardMessage).toHaveBeenCalledWith(
      "conv-new", "tool_card",
      expect.objectContaining({
        name: "task",
        status: "starting",
        sub_session_id: "sess-child-preempt",
      }),
      undefined,
    )
  })
})

describe("Streamer M13 测试补齐(嵌套继承 / 失败路径 / 迟到事件)", () => {
  beforeEach(() => _resetInflight())
  afterEach(() => { vi.useRealTimers() })

  it("I-L:嵌套子 agent 的 rootMsgId 从父 childEntry 继承指向最顶层,depth = 父+1", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    wanling.updateMessageContent.mockResolvedValue(undefined)

    // 1) 主 session 起 task-1 → 建 child-1(depth=1, root=parent=task-msg-1)
    wanling.sendCardMessage.mockResolvedValueOnce("task-msg-1")
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "tool", id: "p-task-1", tool: "task", callID: "call-1",
        state: {
          status: "running",
          input: { description: "一层 task", prompt: "..." },
          metadata: { parentSessionId: "sess-main", sessionId: "sess-child-1" },
        },
      },
      time: 1,
    })
    await new Promise((r) => setImmediate(r))
    await Promise.resolve()

    const tree = (streamer as any).childSessionTree as Map<string, any>
    const entry1 = tree.get("sess-child-1")
    expect(entry1).toBeDefined()
    expect(entry1.rootMsgId).toBe("task-msg-1")
    expect(entry1.depth).toBe(1)

    // 2) child-1 内部再起 task-2 → 建 child-2
    wanling.sendCardMessage.mockResolvedValueOnce("task-msg-2")
    await (streamer as any).onPartUpdated({
      sessionID: "sess-child-1",
      part: {
        type: "tool", id: "p-task-2", tool: "task", callID: "call-2",
        state: {
          status: "running",
          input: { description: "二层嵌套 task", prompt: "..." },
          metadata: { parentSessionId: "sess-child-1", sessionId: "sess-child-2" },
        },
      },
      time: 2,
    })
    await new Promise((r) => setImmediate(r))
    await Promise.resolve()

    const entry2 = tree.get("sess-child-2")
    expect(entry2).toBeDefined()
    // 关键:rootMsgId 继承父 childEntry,指向最顶层 task-msg-1(非本次 task-msg-2)
    expect(entry2.rootMsgId).toBe("task-msg-1")
    expect(entry2.parentMsgId).toBe("task-msg-2")
    expect(entry2.depth).toBe(2)
  })

  it("I-M: _flushPendingToolCard 的 sendCardMessage 失败时 emit('error'),不静默吞", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    wanling.sendCardMessage.mockRejectedValueOnce(new Error("WS 断开"))

    const errSpy = vi.fn()
    streamer.on("error", errSpy)

    // 普通 tool running → pendingToolCard + setImmediate flush
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "tool", id: "p-bash-1", tool: "bash", callID: "call-b",
        state: { status: "running", input: { command: "ls" } },
      },
      time: 1,
    })
    await new Promise((r) => setImmediate(r))
    await Promise.resolve()

    expect(errSpy).toHaveBeenCalledTimes(1)
    expect(errSpy.mock.calls[0][0]).toBeInstanceOf(Error)
    expect((errSpy.mock.calls[0][0] as Error).message).toContain("WS 断开")
  })

  it("超时清理后迟到事件走「非主 session 丢弃」分支(返回 null,不建群不发消息)", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    wanling.sendCardMessage.mockResolvedValue("task-msg-late")
    wanling.updateMessageContent.mockResolvedValue(undefined)
    // 仅 fake setTimeout/clearTimeout,setImmediate 保持真实(注册链路依赖 setImmediate)
    vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] })

    // 1) task/running 注册 child + 30min 兜底 timer
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "tool", id: "p-task-late", tool: "task", callID: "call-late",
        state: {
          status: "running",
          input: { description: "迟到测试", prompt: "..." },
          metadata: { parentSessionId: "sess-main", sessionId: "sess-child-late" },
        },
      },
      time: 1,
    })
    await new Promise((r) => setImmediate(r))
    await Promise.resolve()

    const tree = (streamer as any).childSessionTree as Map<string, any>
    expect(tree.has("sess-child-late")).toBe(true)

    // 2) 推进 30min,timer 触发清理
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {})
    vi.advanceTimersByTime(30 * 60 * 1000)
    expect(tree.has("sess-child-late")).toBe(false)
    warnSpy.mockClear()

    // 3) 迟到的子 session 事件 → getOrCreateState 命中「非主 session 丢弃」分支
    await (streamer as any).onPartUpdated({
      sessionID: "sess-child-late",
      part: { type: "reasoning", id: "p-late-r", text: "迟到的思考", time: { start: 1 } },
      time: 2,
    })

    // 断言:warn 输出丢弃日志,且未发任何消息
    expect(warnSpy).toHaveBeenCalledWith(expect.stringContaining("非主 session 事件丢弃"))
    expect(wanling.sendTypedMessage).not.toHaveBeenCalled()

    warnSpy.mockRestore()
  })
})

describe("Streamer wide-review I-1(审批/提问抢占不丢 childSessionTree 注册)", () => {
  beforeEach(() => _resetInflight())

  it("task/running 后 approval_request 抢占 flush,childSessionTree 仍正确注册", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    wanling.sendCardMessage.mockResolvedValue("task-msg-ap")
    wanling.updateMessageContent.mockResolvedValue(undefined)

    // 1) task/running 入 pendingToolCard + 存 childSessionId 到 state.pending*
    //    不 await setImmediate,模拟 approval 在 flush 前到达
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "tool", id: "p-task-ap", tool: "task", callID: "call-ap",
        state: {
          status: "running",
          input: { description: "需权限的 task", prompt: "..." },
          metadata: { parentSessionId: "sess-main", sessionId: "sess-child-ap" },
        },
      },
      time: 1,
    })

    // 2) approval_request 到达 → onPermissionAsked 内调 _flushPendingToolCard(state) 无参
    //    wide-review I-1:修复前 childSessionId 丢失,childSessionTree 永不注册
    //    直接调私有 onPermissionAsked(与现有测试绕过订阅的口径一致)
    await (streamer as any).onPermissionAsked({
      id: "ap-1", sessionID: "sess-main", directory: "/tmp",
      action: "bash", resources: ["**"], source: { type: "tool", messageID: "m1", callID: "call-ap" },
    })
    await new Promise((r) => setImmediate(r))
    await Promise.resolve()

    // 3) 断言:childSessionTree 已注册(修复后从 state.pendingChildSessionId 读取)
    const tree = (streamer as any).childSessionTree as Map<string, any>
    expect(tree.has("sess-child-ap")).toBe(true)
    const entry = tree.get("sess-child-ap")
    expect(entry.parentMsgId).toBe("task-msg-ap")
    expect(entry.depth).toBe(1)

    // 4) 子 session 后续事件应命中透传(不再丢弃)
    wanling.sendTypedMessage.mockClear()
    await (streamer as any).onPartUpdated({
      sessionID: "sess-child-ap",
      part: { type: "text", id: "p-text-ap", text: "子 agent 输出", time: { end: 1 } },
      time: 2,
    })
    expect(wanling.sendTypedMessage).toHaveBeenCalled()
  })
})

describe("Streamer session 状态信号", () => {
  beforeEach(() => _resetInflight())

  it("onSessionStatus busy → 发 SESSION_STATUS busy", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    // 先触发主 session 建群,让 sessions map 有 state
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: { type: "text", id: "p1", text: "hello", time: { end: 1 } },
      time: 1,
    })
    wanling.sendTypedMessage.mockClear()

    ;(streamer as any).onSessionStatus({
      sessionID: "sess-main",
      status: { type: "busy" },
    })
    expect(wanling.sendSessionStatus).toHaveBeenCalledWith(
      expect.any(String), "busy",
    )
  })

  it("onSessionStatus retry → 发 SESSION_STATUS retry 带 attempt/message", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: { type: "text", id: "p1", text: "hello", time: { end: 1 } },
      time: 1,
    })

    ;(streamer as any).onSessionStatus({
      sessionID: "sess-main",
      status: { type: "retry", attempt: 2, message: "timeout" },
    })
    expect(wanling.sendSessionStatus).toHaveBeenCalledWith(
      expect.any(String), "retry",
      { attempt: 2, message: "timeout" },
    )
  })

  it("onSessionStatus sessions map miss + mapper hit → 仍发 SESSION_STATUS busy", () => {
    // 模拟新会话首个 session.status 事件先于 message.part.updated 到达
    // sessions map 无 state,但 mapper 有 session→conv 映射
    vi.mocked(findBySessionId).mockReturnValueOnce({
      wanlingConvId: "conv-from-mapper",
      opencodeSessionId: "sess-new",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    } as any)

    const { streamer, wanling } = makeStreamer("sess-old")
    ;(streamer as any).onSessionStatus({
      sessionID: "sess-new",
      status: { type: "busy" },
    })
    expect(wanling.sendSessionStatus).toHaveBeenCalledWith("conv-from-mapper", "busy")
  })

  it("busy → 启动心跳,每 20s 发一次 SESSION_STATUS busy", async () => {
    vi.useFakeTimers()
    const { streamer, wanling } = makeStreamer("sess-main")
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: { type: "text", id: "p1", text: "hello", time: { end: 1 } },
      time: 1,
    })
    wanling.sendSessionStatus.mockClear()

    ;(streamer as any).onSessionStatus({
      sessionID: "sess-main",
      status: { type: "busy" },
    })
    expect(wanling.sendSessionStatus).toHaveBeenCalledTimes(1)

    vi.advanceTimersByTime(20_000)
    expect(wanling.sendSessionStatus).toHaveBeenCalledTimes(2)

    vi.advanceTimersByTime(20_000)
    expect(wanling.sendSessionStatus).toHaveBeenCalledTimes(3)

    vi.useRealTimers()
  })

  it("idle → 停止心跳,不再发 busy", async () => {
    vi.useFakeTimers()
    const { streamer, wanling } = makeStreamer("sess-main")
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: { type: "text", id: "p1", text: "hello", time: { end: 1 } },
      time: 1,
    })
    wanling.sendSessionStatus.mockClear()

    ;(streamer as any).onSessionStatus({
      sessionID: "sess-main",
      status: { type: "busy" },
    })
    wanling.sendSessionStatus.mockClear()

    ;(streamer as any).onSessionStatus({
      sessionID: "sess-main",
      status: { type: "idle" },
    })
    vi.advanceTimersByTime(60_000)
    // idle 发了一次,心跳不再发 busy
    expect(wanling.sendSessionStatus).toHaveBeenCalledTimes(1)
    expect(wanling.sendSessionStatus).toHaveBeenCalledWith(expect.any(String), "idle")

    vi.useRealTimers()
  })

  it("retry → 也启动心跳,idle 后停止", async () => {
    vi.useFakeTimers()
    const { streamer, wanling } = makeStreamer("sess-main")
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: { type: "text", id: "p1", text: "hello", time: { end: 1 } },
      time: 1,
    })
    wanling.sendSessionStatus.mockClear()

    ;(streamer as any).onSessionStatus({
      sessionID: "sess-main",
      status: { type: "retry", attempt: 1, message: "err" },
    })
    wanling.sendSessionStatus.mockClear()

    vi.advanceTimersByTime(20_000)
    expect(wanling.sendSessionStatus).toHaveBeenCalledWith(expect.any(String), "busy")

    ;(streamer as any).onSessionIdle("sess-main")
    wanling.sendSessionStatus.mockClear()
    vi.advanceTimersByTime(60_000)
    expect(wanling.sendSessionStatus).not.toHaveBeenCalled()

    vi.useRealTimers()
  })

  it("stop() 清除心跳 timer", () => {
    const { streamer } = makeStreamer("sess-main")
    ;(streamer as any).activeSessions.add("sess-main")
    ;(streamer as any)._startHeartbeat()
    expect((streamer as any).heartbeatTimer).not.toBeNull()

    streamer.stop()
    expect((streamer as any).heartbeatTimer).toBeNull()
  })

  it("多次 busy 只启一个 interval", () => {
    const { streamer } = makeStreamer("sess-main")
    ;(streamer as any)._startHeartbeat()
    const t1 = (streamer as any).heartbeatTimer
    ;(streamer as any)._startHeartbeat()
    const t2 = (streamer as any).heartbeatTimer
    expect(t1).toBe(t2)
  })
})

describe("Streamer onSessionIdle", () => {
  beforeEach(() => _resetInflight())

  it("主 session idle → 只发 SESSION_STATUS idle,不发 step_finish 占位消息", async () => {
    // 方案 C:响铃通知改由 APP 监听 SESSION_STATUS idle 自己触发,
    // plugin 不再发占位 step_finish 防止消息列表出现空"已完成"行。
    const { streamer, wanling } = makeStreamer("sess-main")
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: { type: "text", id: "p1", text: "hello", time: { end: 1 } },
      time: 1,
    })
    wanling.sendTypedMessage.mockClear()

    await (streamer as any).onSessionIdle("sess-main")

    // 发了 SESSION_STATUS idle(APP 监听此事件自己触发通知)
    expect(wanling.sendSessionStatus).toHaveBeenCalledWith(
      expect.any(String), "idle",
    )
    // 不发任何 step_finish 消息(占位 step_finish 已废弃)
    const stepFinishCalls = wanling.sendTypedMessage.mock.calls.filter(
      (c: any[]) => c[1] === "step_finish",
    )
    expect(stepFinishCalls).toHaveLength(0)
  })

  it("子 session idle → 不发 step_finish finished=true", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    // 先让主 session 建群
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: { type: "text", id: "p1", text: "hello", time: { end: 1 } },
      time: 1,
    })
    // 手动注册一个子 session
    const parentState = (streamer as any).sessions.get("sess-main")
    ;(streamer as any)._registerChildSession(
      parentState, "msg-task-1", "sess-child", "sess-main", { description: "test" },
    )
    wanling.sendTypedMessage.mockClear()

    await (streamer as any).onSessionIdle("sess-child")

    // 不发 step_finish finished=true（子 session idle 不通知用户）
    const calls = wanling.sendTypedMessage.mock.calls
    const finishCall = calls.find(
      (c: any[]) => c[1] === "step_finish" && c[2]?.finished === true,
    )
    expect(finishCall).toBeUndefined()
    // 子 session idle 不发 SESSION_STATUS idle(共享 convId,清了会误灭主 agent 状态)
    expect(wanling.sendSessionStatus).not.toHaveBeenCalled()
  })
})

describe("Streamer 卡片 silent=false", () => {
  beforeEach(() => _resetInflight())

  it("onPermissionAsked → sendCardMessage silent=false", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: { type: "text", id: "p1", text: "hello", time: { end: 1 } },
      time: 1,
    })
    wanling.sendCardMessage.mockClear()

    await (streamer as any).onPermissionAsked({
      id: "req-1",
      sessionID: "sess-main",
      directory: "/tmp",
      action: "bash",
      resources: ["*.sh"],
      source: { type: "tool", messageID: "m1", callID: "c1" },
      save: [],
      metadata: {},
    })

    expect(wanling.sendCardMessage).toHaveBeenCalledWith(
      expect.any(String),
      "permission_card",
      expect.any(Object),
      expect.objectContaining({ silent: false }),
    )
  })

  it("onQuestionAsked → sendCardMessage silent=false", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: { type: "text", id: "p1", text: "hello", time: { end: 1 } },
      time: 1,
    })
    wanling.sendCardMessage.mockClear()

    await (streamer as any).onQuestionAsked({
      id: "req-2",
      sessionID: "sess-main",
      directory: "/tmp",
      questions: [{
        question: "continue?",
        header: "Confirm",
        options: [{ label: "Yes", description: "" }],
      }],
      tool: { messageID: "m2", callID: "c2" },
    })

    expect(wanling.sendCardMessage).toHaveBeenCalledWith(
      expect.any(String),
      "question_card",
      expect.any(Object),
      expect.objectContaining({ silent: false }),
    )
  })

  it("子 session onPermissionAsked → 第 4 参数透传 parentMsgId + rootMsgId + silent=false", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    // 主 session 建群拿 parentState(对齐 Task 4 子 session 测试口径)
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: { type: "text", id: "p1", text: "hello", time: { end: 1 } },
      time: 1,
    })
    const parentState = (streamer as any).sessions.get("sess-main")
    ;(streamer as any)._registerChildSession(
      parentState, "task-msg-1", "sess-child", "sess-main", { description: "子 agent 任务" },
    )
    wanling.sendCardMessage.mockClear()

    // 子 session 触发权限请求 → sendCardByState 走子 session 分支
    await (streamer as any).onPermissionAsked({
      id: "req-child-1",
      sessionID: "sess-child",
      directory: "/tmp",
      action: "bash",
      resources: ["*.sh"],
      source: { type: "tool", messageID: "m1", callID: "c1" },
      save: [],
      metadata: {},
    })

    expect(wanling.sendCardMessage).toHaveBeenCalledWith(
      expect.any(String),
      "permission_card",
      expect.any(Object),
      expect.objectContaining({
        parentMsgId: "task-msg-1",
        rootMsgId: "task-msg-1",
        silent: false,
      }),
    )
  })
})

describe("Streamer step-finish silent 区分循环结束信号", () => {
  beforeEach(() => _resetInflight())

  it("主 session reason=stop → step_finish silent=true + finished=true(结束标记不打扰,未读响铃由最终文本承担)", async () => {
    // reason=stop 是 opencode agent 循环真正结束的语义信号。
    const { streamer, wanling } = makeStreamer("sess-main")
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: { type: "text", id: "p1", text: "hello", time: { end: 1 } },
      time: 1,
    })
    wanling.sendTypedMessage.mockClear()

    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "step-finish", id: "p-finish-1",
        reason: "stop",
        cost: 0.012,
        tokens: { input: 100, output: 50, reasoning: 10, cache: { read: 200, write: 0 }, total: 360 },
      },
      time: 2,
    })

    // step_finish 恒 silent=true:循环结束标记不响铃、不计未读、不作未读锚点,
    // 未读+响铃职责由最终文本(flushPendingText isLoopEnd → silent=false)承担。
    expect(wanling.sendTypedMessage).toHaveBeenCalledWith(
      expect.any(String),
      "step_finish",
      expect.objectContaining({
        reason: "stop",
        cost: 0.012,
        finished: true,
        tokens: expect.objectContaining({ total: 360 }),
      }),
      { silent: true },
    )
  })

  it("主 session reason!=stop(中间步骤) → silent=true(过程信息不打扰)", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: { type: "text", id: "p1", text: "hello", time: { end: 1 } },
      time: 1,
    })
    wanling.sendTypedMessage.mockClear()

    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "step-finish", id: "p-finish-mid",
        reason: "tool",  // 工具调用后的中间步骤,非循环结束
        cost: 0.005,
        tokens: { input: 50, output: 10, reasoning: 0, cache: { read: 0, write: 0 }, total: 60 },
      },
      time: 2,
    })

    // 主 session 走 sendMsg: silent=true → sendTypedMessage 第 4 参数 = {silent:true}
    expect(wanling.sendTypedMessage).toHaveBeenCalledWith(
      expect.any(String),
      "step_finish",
      expect.objectContaining({ finished: false, reason: "tool" }),
      { silent: true },
    )
  })

  it("子 session reason=stop → silent=true(子 agent 结束不打扰用户)", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: { type: "text", id: "p1", text: "hello", time: { end: 1 } },
      time: 1,
    })
    const parentState = (streamer as any).sessions.get("sess-main")
    ;(streamer as any)._registerChildSession(
      parentState, "task-msg-1", "sess-child", "sess-main", { description: "子 agent 任务" },
    )
    wanling.sendTypedMessage.mockClear()

    await (streamer as any).onPartUpdated({
      sessionID: "sess-child",
      part: {
        type: "step-finish", id: "p-finish-child",
        reason: "stop",  // 即使是 stop,子 session 也不通知
        cost: 0.001,
        tokens: { input: 10, output: 5, reasoning: 0, cache: { read: 0, write: 0 }, total: 15 },
      },
      time: 2,
    })

    expect(wanling.sendTypedMessage).toHaveBeenCalledWith(
      expect.any(String),
      "step_finish",
      expect.objectContaining({ finished: false }),
      expect.objectContaining({
        silent: true,
        parentMsgId: "task-msg-1",
        rootMsgId: "task-msg-1",
      }),
    )
  })
})

describe("Streamer loadProviderNames 上报 AGENT_MODELS", () => {
  beforeEach(() => _resetInflight())

  it("拉完 providers 后构造 4 字段 ModelInfo 数组并调 sendAgentModels", async () => {
    const subscriber = { on: vi.fn(), start: vi.fn() } as any
    const wanling = {
      sendTypedMessage: vi.fn(),
      sendCardMessage: vi.fn(),
      sendSessionStatus: vi.fn(),
      sendAgentModels: vi.fn(),
      updateMessageContent: vi.fn(),
      createGroupAsAgent: vi.fn(),
      updateConversationTitle: vi.fn(),
      agentId: "agent-test-1",
    } as any
    const ocClient = {
      config: {
        providers: vi.fn().mockResolvedValue({
          data: {
            providers: [
              {
                id: "zhipuai",
                name: "Zhipu AI",
                models: {
                  "glm-5.2": { name: "GLM-5.2" },
                  "glm-4.6": {}, // 缺 name,应 fallback 到 model_id
                },
              },
              {
                id: "anthropic", // 缺 name,应 fallback 到 provider id
                models: {
                  "claude-opus-4": { name: "Claude Opus 4" },
                },
              },
            ],
          },
        }),
      },
    } as any
    const opencode = { getClient: () => ocClient, getSessionTitle: vi.fn(), getSessionDirectory: vi.fn().mockResolvedValue("") } as any
    const streamer = new Streamer(subscriber, wanling, "sess-main", { opencode, ownerUserId: "u" } as any, new RPCDispatcher())

    await (streamer as any).loadProviderNames()

    expect(wanling.sendAgentModels).toHaveBeenCalledTimes(1)
    const [agentId, models] = wanling.sendAgentModels.mock.calls[0]
    // agentId 从 wanling client 读取(单一来源,避免 Streamer 持有副本)
    expect(agentId).toBe("agent-test-1")
    // 3 个模型(2 provider),顺序按 providers 数组 + models entries
    expect(models).toHaveLength(3)
    expect(models).toEqual([
      { provider_id: "zhipuai", provider_name: "Zhipu AI", model_id: "glm-5.2", model_name: "GLM-5.2" },
      { provider_id: "zhipuai", provider_name: "Zhipu AI", model_id: "glm-4.6", model_name: "glm-4.6" },
      { provider_id: "anthropic", provider_name: "anthropic", model_id: "claude-opus-4", model_name: "Claude Opus 4" },
    ])
  })

  it("opencode client 不可用时不调 sendAgentModels(早退)", async () => {
    const subscriber = { on: vi.fn(), start: vi.fn() } as any
    const wanling = {
      sendAgentModels: vi.fn(),
      agentId: "agent-test-1",
    } as any
    const opencode = { getClient: () => null, getSessionTitle: vi.fn(), getSessionDirectory: vi.fn().mockResolvedValue("") } as any
    const streamer = new Streamer(subscriber, wanling, "sess-main", { opencode, ownerUserId: "u" } as any, new RPCDispatcher())

    await (streamer as any).loadProviderNames()

    expect(wanling.sendAgentModels).not.toHaveBeenCalled()
  })

  it("loadProviderNames 一并缓存 model.limit.context 供后续 token 百分比计算", async () => {
    const subscriber = { on: vi.fn(), start: vi.fn() } as any
    const wanling = {
      sendAgentModels: vi.fn().mockResolvedValue(undefined),
    } as any
    const opencode = {
      getClient: vi.fn(() => ({
        config: {
          providers: vi.fn(async () => ({
            data: {
              providers: [
                {
                  id: "zhipuai",
                  name: "ZhipuAI",
                  models: {
                    "glm-5.2": {
                      id: "glm-5.2", providerID: "zhipuai", name: "GLM-5.2",
                      api: { id: "glm-5.2", url: "https://api.example.com", npm: "@ai-sdk/x" },
                      capabilities: { temperature: true, reasoning: true, attachment: true, toolcall: true,
                        input: { text: true, audio: false, image: false, video: false, pdf: false },
                        output: { text: true, audio: false, image: false, video: false, pdf: false } },
                      cost: { input: 0.001, output: 0.002, cache: { read: 0.0001, write: 0.0002 } },
                      limit: { context: 128000, output: 4096 },
                      status: "active", options: {}, headers: {}, release_date: "2026-01-01",
                    },
                  },
                },
              ],
            },
          })),
        },
      })) as any,
    } as any
    const streamer = new Streamer(subscriber, wanling, "sess-main", { opencode, ownerUserId: "u" } as any, new RPCDispatcher())

    // 直接调私有方法(vitest 测试惯例)
    await (streamer as any).loadProviderNames()

    const cache = (streamer as any).providerNames as Map<string, any>
    expect(cache.get("zhipuai/glm-5.2")?.contextLimit).toBe(128000)
    expect(cache.get("zhipuai/glm-5.2")?.modelName).toBe("GLM-5.2")
  })

  it("loadProviderNames 自定义 provider contextLimit=0 时从标准 provider 同名 modelId 兜底", async () => {
    const subscriber = { on: vi.fn(), start: vi.fn() } as any
    const wanling = { sendAgentModels: vi.fn().mockResolvedValue(undefined) } as any
    const opencode = {
      getClient: vi.fn(() => ({
        config: {
          providers: vi.fn(async () => ({
            data: {
              providers: [
                {
                  // 标准 provider,有完整 limit
                  id: "zhipuai-coding-plan",
                  name: "Zhipu AI",
                  models: {
                    "glm-5.2": {
                      id: "glm-5.2", providerID: "zhipuai-coding-plan",
                      name: "GLM-5.2",
                      limit: { context: 1000000, output: 131072 },
                    },
                  },
                },
                {
                  // 用户自定义 provider,limit.context=0(常见:用户只配 baseURL+apiKey)
                  id: "MaHe Coding Plan",
                  name: "MaHe Coding Plan",
                  models: {
                    "glm-5.2": {
                      id: "glm-5.2", providerID: "MaHe Coding Plan",
                      name: "GLM-5.2",
                      limit: { context: 0, output: 0 },
                    },
                  },
                },
              ],
            },
          })),
        },
      })) as any,
    } as any
    const streamer = new Streamer(subscriber, wanling, "sess-main", { opencode, ownerUserId: "u" } as any, new RPCDispatcher())

    await (streamer as any).loadProviderNames()

    const cache = (streamer as any).providerNames as Map<string, any>
    // 标准 provider 的 contextLimit 不变
    expect(cache.get("zhipuai-coding-plan/glm-5.2")?.contextLimit).toBe(1000000)
    // 自定义 provider 的 contextLimit 从标准 provider 兜底
    expect(cache.get("MaHe Coding Plan/glm-5.2")?.contextLimit).toBe(1000000)
    // modelName 等其他字段不受影响
    expect(cache.get("MaHe Coding Plan/glm-5.2")?.modelName).toBe("GLM-5.2")
    expect(cache.get("MaHe Coding Plan/glm-5.2")?.providerName).toBe("MaHe Coding Plan")
  })

  it("loadProviderNames 没有同名 model fallback 时 contextLimit 保持 0", async () => {
    const subscriber = { on: vi.fn(), start: vi.fn() } as any
    const wanling = { sendAgentModels: vi.fn().mockResolvedValue(undefined) } as any
    const opencode = {
      getClient: vi.fn(() => ({
        config: {
          providers: vi.fn(async () => ({
            data: {
              providers: [
                {
                  id: "custom",
                  name: "Custom",
                  models: {
                    "my-custom-model": {
                      id: "my-custom-model", providerID: "custom",
                      name: "My Custom",
                      limit: { context: 0, output: 0 },
                    },
                  },
                },
              ],
            },
          })),
        },
      })) as any,
    } as any
    const streamer = new Streamer(subscriber, wanling, "sess-main", { opencode, ownerUserId: "u" } as any, new RPCDispatcher())

    await (streamer as any).loadProviderNames()

    const cache = (streamer as any).providerNames as Map<string, any>
    expect(cache.get("custom/my-custom-model")?.contextLimit).toBe(0)
  })
})

describe("Streamer onSessionUpdated 同步 cwd + vcs.get 拉 branch", () => {
  beforeEach(() => _resetInflight())

  it("onSessionUpdated 同步 cwd 并通过 vcs.get 拉 branch", async () => {
    const { streamer, wanling, opencode } = makeStreamer("sess-main")
    // 让 mapper 命中:sessionID → wanlingConvId
    vi.mocked(findBySessionId).mockReturnValue({
      wanlingConvId: "conv-1",
      opencodeSessionId: "sess-1",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    } as any)
    // mock vcs.get 返 branch
    const vcsGet = vi.fn(async () => ({ data: { branch: "feature/y" } }))
    opencode.getClient = vi.fn(() => ({ vcs: { get: vcsGet } } as any))

    await (streamer as any).onSessionUpdated({
      sessionID: "sess-1",
      title: "",
      mode: "build",
      model: { id: "glm-5.2", providerID: "zhipuai", variant: undefined },
      directory: "/home/u/proj",
    })

    expect(vcsGet).toHaveBeenCalledWith({ query: { directory: "/home/u/proj" } })
    expect(wanling.updateSessionMeta).toHaveBeenCalledTimes(1)
    const [, meta] = wanling.updateSessionMeta.mock.calls[0]
    expect(meta.gitBranch).toBe("feature/y")
  })

  it("vcs.get 失败时 gitBranch 降级为空字符串", async () => {
    const { streamer, wanling, opencode } = makeStreamer("sess-main")
    vi.mocked(findBySessionId).mockReturnValue({
      wanlingConvId: "conv-2",
      opencodeSessionId: "sess-2",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    } as any)
    opencode.getClient = vi.fn(() => ({
      vcs: { get: vi.fn(async () => { throw new Error("not a git repo") }) },
    } as any))
    // 抑制 vcs.get 失败的 console.warn
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {})

    await (streamer as any).onSessionUpdated({
      sessionID: "sess-2",
      title: "",
      mode: "build",
      model: { id: "m", providerID: "p", variant: undefined },
      directory: "/tmp/plain",
    })

    warnSpy.mockRestore()
    expect(wanling.updateSessionMeta).toHaveBeenCalledTimes(1)
    const [, meta] = wanling.updateSessionMeta.mock.calls[0]
    expect(meta.gitBranch).toBe("")
  })

  it("mainSessionId 的 title 变化也同步到 server(不再跳过主 session)", async () => {
    const { streamer, wanling, opencode } = makeStreamer("sess-main")
    vi.mocked(findBySessionId).mockReturnValue({
      wanlingConvId: "conv-main",
      opencodeSessionId: "sess-main",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    } as any)
    opencode.getClient = vi.fn(() => ({
      vcs: { get: vi.fn(async () => ({ data: { branch: "main" } })) },
    } as any))

    await (streamer as any).onSessionUpdated({
      sessionID: "sess-main",
      title: "TUI 改的新名",
      mode: "build",
      model: { id: "m", providerID: "p", variant: undefined },
      directory: "/tmp/x",
    })

    expect(wanling.updateConversationTitle).toHaveBeenCalledWith("conv-main", "TUI 改的新名")
  })
})

describe("Streamer vcs_branch_updated 增量同步", () => {
  beforeEach(() => _resetInflight())

  it("session_updated 已建立 knownFullMeta 缓存,vcs_branch_updated 读缓存拼完整 meta", async () => {
    const { streamer, wanling, opencode } = makeStreamer("sess-main")
    vi.mocked(findBySessionId).mockReturnValue({
      wanlingConvId: "conv-3",
      opencodeSessionId: "sess-3",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    } as any)
    opencode.getClient = vi.fn(() => ({
      vcs: { get: vi.fn(async () => ({ data: { branch: "main" } })) },
    } as any))

    // 1) 先 onSessionUpdated 建立缓存(mode=model-x, gitBranch=main)
    await (streamer as any).onSessionUpdated({
      sessionID: "sess-3",
      title: "",
      mode: "build",
      model: { id: "model-x", providerID: "p", variant: undefined },
      directory: "/home/u/proj",
    })
    wanling.updateSessionMeta.mockClear()

    // 2) vcs_branch_updated 增量切分支
    await (streamer as any).onVcsBranchUpdated({
      sessionID: "sess-3",
      directory: "/home/u/proj",
      branch: "develop",
    })

    expect(wanling.updateSessionMeta).toHaveBeenCalledTimes(1)
    const [, meta] = wanling.updateSessionMeta.mock.calls[0]
    expect(meta.gitBranch).toBe("develop")
    // 关键:读缓存拼完整,mode/model 不丢(防 server 整 JSON 覆盖写覆盖成空)
    expect(meta.mode).toBe("build")
    expect(meta.modelId).toBe("model-x")
  })

  it("缓存未命中(vcs_branch_updated 先于 session_updated 到达)兜底发空壳 meta + cwd+branch", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")
    vi.mocked(findBySessionId).mockReturnValue({
      wanlingConvId: "conv-4",
      opencodeSessionId: "sess-4",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    } as any)

    await (streamer as any).onVcsBranchUpdated({
      sessionID: "sess-4",
      directory: "/home/u/proj",
      branch: "develop",
    })

    expect(wanling.updateSessionMeta).toHaveBeenCalledTimes(1)
    const [, meta] = wanling.updateSessionMeta.mock.calls[0]
    expect(meta.gitBranch).toBe("develop")
    // 锁兜底行为:mode/modelId/variant/modelName/providerName 均发空串,防 server 覆盖写丢字段
    expect(meta.mode).toBe("")
    expect(meta.modelId).toBe("")
    expect(meta.variant).toBe("")
    expect(meta.modelName).toBe("")
    expect(meta.providerName).toBe("")
  })

  it("同 branch 重复事件去重(防 SSE 重连重放)", async () => {
    const { streamer, wanling, opencode } = makeStreamer("sess-main")
    vi.mocked(findBySessionId).mockReturnValue({
      wanlingConvId: "conv-5",
      opencodeSessionId: "sess-5",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    } as any)
    opencode.getClient = vi.fn(() => ({
      vcs: { get: vi.fn(async () => ({ data: { branch: "main" } })) },
    } as any))

    // 先建立缓存
    await (streamer as any).onSessionUpdated({
      sessionID: "sess-5",
      title: "",
      mode: "build",
      model: { id: "m", providerID: "p", variant: undefined },
      directory: "/home/u/proj",
    })
    wanling.updateSessionMeta.mockClear()

    // 同 branch 发两次
    await (streamer as any).onVcsBranchUpdated({
      sessionID: "sess-5", directory: "/home/u/proj", branch: "feature/a",
    })
    await (streamer as any).onVcsBranchUpdated({
      sessionID: "sess-5", directory: "/home/u/proj", branch: "feature/a",
    })

    expect(wanling.updateSessionMeta).toHaveBeenCalledTimes(1)
  })
})

describe("Streamer step-finish reason=stop 主动同步 session_meta", () => {
  beforeEach(() => _resetInflight())

  it("主 session step-finish reason=stop → vcs.get 拉 branch + updateSessionMeta", async () => {
    // 根因修复:agent 回复时 plugin 不主动同步,导致 EnvMetaStrip 不刷新。
    // 方案 A:step-finish reason=stop(agent 循环结束)时读 knownFullMeta 缓存,
    // 用 cwd 调 vcs.get 拉最新 branch,然后 updateSessionMeta 整体覆盖。
    const { streamer, wanling, opencode } = makeStreamer("sess-main")
    vi.mocked(findBySessionId).mockReturnValue({
      wanlingConvId: "conv-step", opencodeSessionId: "sess-main",
      lastSyncAt: new Date().toISOString(), messageCount: 0,
    } as any)
    const vcsGet = vi.fn(async () => ({ data: { branch: "feature/after-reply" } }))
    opencode.getClient = vi.fn(() => ({ vcs: { get: vcsGet } } as any))

    // 1) 先 onSessionUpdated 建立 knownFullMeta 缓存(mode=model-x, cwd=/home/u/proj, branch=main)
    await (streamer as any).onSessionUpdated({
      sessionID: "sess-main",
      title: "",
      mode: "build",
      model: { id: "model-x", providerID: "p", variant: undefined },
      directory: "/home/u/proj",
    })
    wanling.updateSessionMeta.mockClear()

    // 2) 触发 step-finish reason=stop(主 session 循环结束)
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "step-finish", id: "p-finish-loop",
        reason: "stop",
        cost: 0.01,
        tokens: { total: 100 },
      },
      time: 2,
    })

    // 3) 应主动调 vcs.get 拉最新 branch
    expect(vcsGet).toHaveBeenCalledWith({ query: { directory: "/home/u/proj" } })
    // 4) 调 updateSessionMeta 同步到 server(server 广播 SESSION_META_UPDATE → APP 刷新)
    expect(wanling.updateSessionMeta).toHaveBeenCalledTimes(1)
    const [, meta] = wanling.updateSessionMeta.mock.calls[0]
    expect(meta.gitBranch).toBe("feature/after-reply")
    // 关键:mode/model 从缓存读不丢(防 server 整 JSON 覆盖写丢字段)
    expect(meta.mode).toBe("build")
    expect(meta.modelId).toBe("model-x")
  })

  it("knownFullMeta 缓存未命中(plugin 重启后/未发过 session.updated) → 跳过,不报错", async () => {
    const { streamer, wanling, opencode } = makeStreamer("sess-main")
    vi.mocked(findBySessionId).mockReturnValue({
      wanlingConvId: "conv-step2", opencodeSessionId: "sess-main",
      lastSyncAt: new Date().toISOString(), messageCount: 0,
    } as any)
    const vcsGet = vi.fn(async () => ({ data: { branch: "x" } }))
    opencode.getClient = vi.fn(() => ({ vcs: { get: vcsGet } } as any))

    // 直接 step-finish(无 onSessionUpdated 先调用 → knownFullMeta 缓存空)
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "step-finish", id: "p-finish-nocache",
        reason: "stop", cost: 0, tokens: {},
      },
      time: 1,
    })

    // 缓存空时不应调 vcs.get(无 cwd 可用)也不应 updateSessionMeta
    expect(vcsGet).not.toHaveBeenCalled()
    expect(wanling.updateSessionMeta).not.toHaveBeenCalled()
  })

  it("子 session step-finish reason=stop → 不主动同步(子 agent 不属于用户对话)", async () => {
    const { streamer, wanling, opencode } = makeStreamer("sess-main")
    vi.mocked(findBySessionId).mockReturnValue({
      wanlingConvId: "conv-parent", opencodeSessionId: "sess-main",
      lastSyncAt: new Date().toISOString(), messageCount: 0,
    } as any)
    const vcsGet = vi.fn(async () => ({ data: { branch: "x" } }))
    opencode.getClient = vi.fn(() => ({ vcs: { get: vcsGet } } as any))

    // 建 parent state + 注册 child session
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: { type: "text", id: "p1", text: "hi", time: { end: 1 } },
      time: 1,
    })
    const parentState = (streamer as any).sessions.get("sess-main")
    ;(streamer as any)._registerChildSession(
      parentState, "task-msg-x", "sess-child", "sess-main", { description: "子任务" },
    )
    wanling.updateSessionMeta.mockClear()

    // 子 session step-finish reason=stop
    await (streamer as any).onPartUpdated({
      sessionID: "sess-child",
      part: {
        type: "step-finish", id: "p-finish-child",
        reason: "stop", cost: 0, tokens: {},
      },
      time: 2,
    })

    // 子 session 的 step-finish 不应触发主 session meta 主动同步
    expect(vcsGet).not.toHaveBeenCalled()
    expect(wanling.updateSessionMeta).not.toHaveBeenCalled()
  })

  it("step-finish reason=stop 主动 session.get 拉累计 tokens + 拼 meta 三字段", async () => {
    const { streamer, wanling, opencode } = makeStreamer("sess-main")
    vi.mocked(findBySessionId).mockReturnValue({
      wanlingConvId: "conv-token", opencodeSessionId: "sess-main",
      lastSyncAt: new Date().toISOString(), messageCount: 0,
    } as any)

    // mock vcs.get 拉 branch + session.get 拉累计 tokens + provider 缓存含 contextLimit
    // session.get 同时拉 directory(供 fetchGitBranch 用)
    const vcsGet = vi.fn(async () => ({ data: { branch: "develop" } }))
    const sessionGet = vi.fn(async () => ({
      data: {
        directory: "/home/u/proj",
        tokens: {
          input: 200000, output: 5000, reasoning: 1000,
          cache: { read: 800000, write: 0 },
        },
      },
    }))
    opencode.getClient = vi.fn(() => ({
      vcs: { get: vcsGet },
      session: { get: sessionGet },
    } as any))

    // 1) 先 onSessionUpdated 建缓存(mode=model-x, directory 来自 session.updated 仍可用)
    await (streamer as any).onSessionUpdated({
      sessionID: "sess-main",
      title: "",
      mode: "build",
      model: { id: "glm-5.2", providerID: "zhipuai", variant: undefined },
      directory: "/home/u/proj",
    })
    // 手动注 providerNames 缓存(模拟 loadProviderNames 已建好)
    ;(streamer as any).providerNames.set("zhipuai/glm-5.2", {
      modelName: "GLM-5.2", providerName: "ZhipuAI", contextLimit: 128000,
    })
    wanling.updateSessionMeta.mockClear()

    // 2) step-finish reason=stop 触发(主 session isLoopEnd=true)
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "step-finish", id: "p-finish-token",
        reason: "stop",
        cost: 0.01,
        tokens: {
          input: 100000, output: 2000, reasoning: 500,
          cache: { read: 28000, write: 0 }, total: 130500,
        },
      },
      time: 2,
    })

    // 3) 验证 session.get 被调用拉累计 tokens + directory
    expect(sessionGet).toHaveBeenCalledWith({ path: { id: "sess-main" } })

    // 4) updateSessionMeta 含三字段
    expect(wanling.updateSessionMeta).toHaveBeenCalledTimes(1)
    const [, meta] = wanling.updateSessionMeta.mock.calls[0]
    // tokensTotal = 累计 input+output+reasoning+cache.read+cache.write
    expect(meta.tokensTotal).toBe(200000 + 5000 + 1000 + 800000 + 0)
    // contextUsed = 本次 step_finish 的 input + cache.read
    expect(meta.contextUsed).toBe(100000 + 28000)
    // contextLimit = providerNames 缓存的 model contextLimit
    expect(meta.contextLimit).toBe(128000)
    // 旧字段仍正确(branch 仍同步)
    expect(meta.gitBranch).toBe("develop")
  })

  it("session.get 拉累计 tokens 失败时跳过 token 字段(向后兼容,branch 仍同步)", async () => {
    const { streamer, wanling, opencode } = makeStreamer("sess-main")
    vi.mocked(findBySessionId).mockReturnValue({
      wanlingConvId: "conv-tok2", opencodeSessionId: "sess-main",
      lastSyncAt: new Date().toISOString(), messageCount: 0,
    } as any)
    const vcsGet = vi.fn(async () => ({ data: { branch: "develop" } }))
    const sessionGet = vi.fn(async () => { throw new Error("network error") })
    opencode.getClient = vi.fn(() => ({
      vcs: { get: vcsGet },
      session: { get: sessionGet },
    } as any))
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {})
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {})

    // 先建缓存
    await (streamer as any).onSessionUpdated({
      sessionID: "sess-main", title: "", mode: "build",
      model: { id: "glm-5.2", providerID: "zhipuai", variant: undefined },
      directory: "/home/u/proj",
    })
    ;(streamer as any).providerNames.set("zhipuai/glm-5.2", {
      modelName: "GLM-5.2", providerName: "ZhipuAI", contextLimit: 128000,
    })
    wanling.updateSessionMeta.mockClear()

    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: {
        type: "step-finish", id: "p-fail",
        reason: "stop", cost: 0,
        tokens: { input: 100, output: 10, cache: { read: 0, write: 0 }, total: 110 },
      },
      time: 1,
    })

    warnSpy.mockRestore()
    errSpy.mockRestore()

    // branch 仍同步,token 字段为 0(向后兼容,APP 不渲染)
    expect(wanling.updateSessionMeta).toHaveBeenCalledTimes(1)
    const [, meta] = wanling.updateSessionMeta.mock.calls[0]
    expect(meta.gitBranch).toBe("develop")
    expect(meta.tokensTotal).toBe(0)
    expect(meta.contextUsed).toBe(0)
    expect(meta.contextLimit).toBe(0)
  })
})

describe("Streamer loadSlashCatalog", () => {
  it("成功拉取命令 + 透传 source 字段 + push compact 到 command 类", async () => {
    const { streamer, wanling, opencode } = makeStreamer("sess-main")

    // mock OC command.list 返 3 条(2 command + 1 skill)
    const fakeClient = {
      command: {
        list: vi.fn().mockResolvedValue({
          data: [
            { name: "init", template: "/init", description: "guided setup", source: "command" },
            { name: "review", template: "/review", description: "review changes", source: "command" },
            { name: "agently-mail", template: "/agently-mail", description: "邮件操作", source: "skill" },
          ],
        }),
      },
    }
    opencode.getClient = vi.fn(() => fakeClient as any)

    await (streamer as any).loadSlashCatalog()

    expect(wanling.sendAgentSlashCatalog).toHaveBeenCalledTimes(1)
    const [agentId, commands] = wanling.sendAgentSlashCatalog.mock.calls[0]
    expect(typeof agentId).toBe("string")

    // 4 条 = 3 OC 返回 + 1 plugin push 的 compact
    expect(commands).toHaveLength(4)

    // OC 透传的项含 source 字段,无 has_args
    expect(commands[0]).toEqual({
      name: "init",
      template: "/init",
      description: "guided setup",
      source: "command",
    })
    expect(commands[2]).toEqual({
      name: "agently-mail",
      template: "/agently-mail",
      description: "邮件操作",
      source: "skill",
    })

    // compact 被 push 到末尾,source=command
    const compact = commands.find((c: any) => c.name === "compact")
    expect(compact).toBeDefined()
    expect(compact).toEqual({
      name: "compact",
      template: "/compact",
      description: "压缩上下文",
      source: "command",
    })

    // 确认 has_args 字段已删除(不再透传)
    commands.forEach((c: any) => expect(c).not.toHaveProperty("has_args"))
  })

  it("OC client 未就绪(getClient 返 null)时 silently 跳过", async () => {
    const { streamer, wanling, opencode } = makeStreamer("sess-main")
    opencode.getClient = vi.fn(() => null)

    await (streamer as any).loadSlashCatalog()

    expect(wanling.sendAgentSlashCatalog).not.toHaveBeenCalled()
  })

  it("command.list 抛错时 catch 不抛", async () => {
    const { streamer, wanling, opencode } = makeStreamer("sess-main")
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    const fakeClient = {
      command: {
        list: vi.fn().mockRejectedValue(new Error("network")),
      },
    }
    opencode.getClient = vi.fn(() => fakeClient as any)

    await expect((streamer as any).loadSlashCatalog()).resolves.not.toThrow()
    expect(wanling.sendAgentSlashCatalog).not.toHaveBeenCalled()
    errSpy.mockRestore()
  })

  it("OC 已返 compact 时 plugin 不重复 push(dedup 守卫)", async () => {
    const { streamer, wanling, opencode } = makeStreamer("sess-main")

    // 模拟 OC 未来版本开始在 command.list 返回 compact
    const fakeClient = {
      command: {
        list: vi.fn().mockResolvedValue({
          data: [
            { name: "init", template: "/init", description: "init", source: "command" },
            { name: "compact", template: "/compact", description: "OC 自带 compact", source: "command" },
          ],
        }),
      },
    }
    opencode.getClient = vi.fn(() => fakeClient as any)

    await (streamer as any).loadSlashCatalog()

    expect(wanling.sendAgentSlashCatalog).toHaveBeenCalledTimes(1)
    const [, commands] = wanling.sendAgentSlashCatalog.mock.calls[0]

    // compact 仅 1 条(OC 返回的,plugin 不再 push 第二条)
    const compacts = commands.filter((c: any) => c.name === "compact")
    expect(compacts).toHaveLength(1)
    // 总数 = 2(OC 返回的 init + compact),plugin 未额外 push
    expect(commands).toHaveLength(2)
    // OC 自带的 compact 描述不被 plugin 覆盖
    expect(compacts[0].description).toBe("OC 自带 compact")
  })
})

describe("Streamer loadCapabilities 上报 PLUGIN_CAPABILITIES", () => {
  beforeEach(() => _resetInflight())

  it("agentId 存在 + dispatcher 有 methods 时调 sendPluginCapabilities 上报清单", async () => {
    // 用真实 RPCDispatcher register 几条 method,验证 listMethods 出参格式正确
    const dispatcher = new RPCDispatcher()
    dispatcher.register("echo", async () => "ok", { timeoutHintMs: 3000 })
    dispatcher.register("tool.run", async () => null, { timeoutHintMs: 8000 })

    const { streamer, wanling } = makeStreamer("sess-main", { dispatcher })

    await (streamer as any).loadCapabilities()

    expect(wanling.sendPluginCapabilities).toHaveBeenCalledTimes(1)
    const [agentId, methods] = wanling.sendPluginCapabilities.mock.calls[0]
    expect(agentId).toBe("agent-test")
    expect(methods).toEqual([
      { name: "echo", timeout_hint_ms: 3000 },
      { name: "tool.run", timeout_hint_ms: 8000 },
    ])
  })

  it("agentId 为空字符串时早退,不调 sendPluginCapabilities", async () => {
    const { streamer, wanling } = makeStreamer("sess-main", { agentId: "" })

    await (streamer as any).loadCapabilities()

    expect(wanling.sendPluginCapabilities).not.toHaveBeenCalled()
  })

  it("agentId undefined(未设置)时早退,不调 sendPluginCapabilities", async () => {
    // simulate agentId 还没拿到(扫码配对前 WS 上线早于 agent 注册)
    const { streamer, wanling } = makeStreamer("sess-main", { agentId: undefined })

    await (streamer as any).loadCapabilities()

    expect(wanling.sendPluginCapabilities).not.toHaveBeenCalled()
  })

  it("dispatcher.listMethods 抛错时不向外传播(被 try/catch 吞)", async () => {
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    // 用一个 listMethods 抛错的 stub dispatcher
    const brokenDispatcher = {
      listMethods: vi.fn(() => { throw new Error("dispatcher broken") }),
    } as unknown as RPCDispatcher
    const { streamer, wanling } = makeStreamer("sess-main", { dispatcher: brokenDispatcher })

    await expect((streamer as any).loadCapabilities()).resolves.not.toThrow()

    expect(wanling.sendPluginCapabilities).not.toHaveBeenCalled()
    expect(errSpy).toHaveBeenCalled()
    errSpy.mockRestore()
  })

  it("sendPluginCapabilities 抛错时不向外传播(被 try/catch 吞)", async () => {
    const errSpy = vi.spyOn(console, "error").mockImplementation(() => {})
    const { streamer, wanling } = makeStreamer("sess-main")
    // 模拟 WS 发送时同步抛错(sendPluginCapabilities 实现内 ws.send 失败)
    wanling.sendPluginCapabilities.mockImplementation(() => { throw new Error("ws send failed") })

    await expect((streamer as any).loadCapabilities()).resolves.not.toThrow()

    expect(wanling.sendPluginCapabilities).toHaveBeenCalledTimes(1)
    expect(errSpy).toHaveBeenCalled()
    errSpy.mockRestore()
  })

  it("dispatcher.listMethods 返空数组时仍调 sendPluginCapabilities(空清单合法)", async () => {
    // 边界:没有 register 任何 method 的 dispatcher,listMethods() 返 []
    const { streamer, wanling } = makeStreamer("sess-main")

    await (streamer as any).loadCapabilities()

    expect(wanling.sendPluginCapabilities).toHaveBeenCalledTimes(1)
    const [agentId, methods] = wanling.sendPluginCapabilities.mock.calls[0]
    expect(agentId).toBe("agent-test")
    expect(methods).toEqual([])
  })
})

describe("Streamer compaction part 处理", () => {
  beforeEach(() => {
    _resetInflight()
    // 上游测试(step-finish meta sync)用 mockReturnValue 设了 sticky mapper 命中,
    // 不 reset 会污染本组用例(主 session 应走 ensureConversation 建群,不走 mapper)。
    vi.mocked(findBySessionId).mockReset()
    vi.mocked(findBySessionId).mockReturnValue(undefined)
  })

  it("首次 compaction part → 发 compact_divider phase=running 消息", async () => {
    const { streamer, wanling } = makeStreamer("ses_main")

    await (streamer as any).onPartUpdated({
      sessionID: "ses_main",
      part: {
        id: "prt_comp1",
        messageID: "msg_p1",
        type: "compaction",
        auto: false,
      },
      time: 1784371925711,
    })

    expect(wanling.sendCardMessage).toHaveBeenCalledWith(
      "conv-new",
      "compact_divider",
      { phase: "running" },
      expect.objectContaining({ silent: true }),
    )
  })

  it("第二次同 id compaction part(带 tail_start_id) → PATCH phase=done", async () => {
    const { streamer, wanling } = makeStreamer("ses_main")
    // mock sendCardMessage 返回的 msgId(compact_divider 落库后的 server id),
    // 后续 PATCH 需要引用这个 id。必须在第一次调用前设置(brief 把这行放在第一次调用后是 bug)。
    wanling.sendCardMessage.mockResolvedValue("msg_divider_1")

    // 第一次:发 running
    await (streamer as any).onPartUpdated({
      sessionID: "ses_main",
      part: { id: "prt_comp1", messageID: "msg_p1", type: "compaction", auto: false },
      time: 1,
    })

    // 第二次同 id 带 tail_start_id:PATCH 切 done
    await (streamer as any).onPartUpdated({
      sessionID: "ses_main",
      part: {
        id: "prt_comp1",
        messageID: "msg_p1",
        type: "compaction",
        auto: false,
        // @ts-expect-error 测试扩展字段(PartUpdatedPayload.part 未声明 tail_start_id)
        tail_start_id: "msg_tail",
      },
      time: 2,
    })

    expect(wanling.updateMessageContent).toHaveBeenCalledWith(
      "msg_divider_1",
      expect.objectContaining({
        msg_type: "compact_divider",
        data: expect.objectContaining({ phase: "done" }),
      }),
    )
  })

  it("子 agent 的 compaction part 忽略,不发 divider", async () => {
    const { streamer, wanling } = makeStreamer("ses_main")

    // 先让主 session 落 sessions map(走一次正常事件)
    await (streamer as any).onPartUpdated({
      sessionID: "ses_main",
      part: { type: "text", id: "p_main", text: "seed", time: { end: 1 } },
      time: 1,
    })
    // 注册一个子 agent session
    const parentState = (streamer as any).sessions.get("ses_main")
    ;(streamer as any)._registerChildSession(
      parentState, "msg_task_1", "ses_child", "ses_main", { description: "test" },
    )
    wanling.sendCardMessage.mockClear()

    // 子 session 的 compaction part 应被 isChildSession 守卫 break
    await (streamer as any).onPartUpdated({
      sessionID: "ses_child",
      part: { id: "prt_x", type: "compaction", auto: false },
      time: 1,
    })

    expect(wanling.sendCardMessage).not.toHaveBeenCalled()
  })

  it("OC 实际行为只推一次 compaction part → 依赖 step-finish 兜底切 done", async () => {
    const { streamer, wanling } = makeStreamer("ses_main")
    // 让 sendCardMessage 返回稳定的 divider msgId,后续 PATCH 引用
    wanling.sendCardMessage.mockResolvedValue("msg_divider_1")

    // 1) compaction part 出现一次:发 running divider,partId 进 compactionParts
    await (streamer as any).onPartUpdated({
      sessionID: "ses_main",
      part: { id: "prt_only", messageID: "msg_p1", type: "compaction", auto: false },
      time: 1,
    })

    // 没有第二次 compaction part,直接走 step-finish(isLoopEnd)兜底
    await (streamer as any).onPartUpdated({
      sessionID: "ses_main",
      part: {
        id: "prt_step",
        type: "step-finish",
        reason: "stop",
        time: { start: 1, end: 2 },
        tokens: { input: 100 },
      },
      time: 2,
    })

    // 期望:compact_divider 被 PATCH 切 done
    expect(wanling.updateMessageContent).toHaveBeenCalledWith(
      "msg_divider_1",
      expect.objectContaining({
        msg_type: "compact_divider",
        data: expect.objectContaining({ phase: "done" }),
      }),
    )
  })
})

// 注意:directory 改造后已升级到 conversations.directory 一级列,
// streamer 不再负责 directory 同步(由 ensure_conversation 通过
// getSessionDirectory 拉取 + createGroupAsAgent 透传)。
// 详见 ensure_conversation.test.ts 的 "directory 通过 getSessionDirectory 拉取并透传" 用例。

// PartDispatcher 流式输出单测:直接构造 PartDispatcher + mock store/router/wanling,
// 用 vi.useFakeTimers() 控制 300ms 节流窗口。不走 Streamer 整链(隔离 PartDispatcher 逻辑)。
function makePartDispatcherFixture() {
  const partIndex = new Map<string, SessionState>()
  const state: SessionState = {
    reasoning: null,
    text: null,
    convId: "conv-1",
    toolPartsSent: new Set(),
    textPartsFlushed: new Set(),
    toolCardMsgIds: new Map(),
    toolCardInflight: new Map(),
  }
  // 最小 store mock:getOrCreateState 返共享 state,indexPart 建 partID→state 映射,
  // getPart 读映射(模拟真实 SessionStore 的 part index 行为)。
  const store = {
    getOrCreateState: vi.fn(async () => state),
    indexPart: vi.fn((partID: string, s: SessionState) => { partIndex.set(partID, s) }),
    getPart: vi.fn((partID: string) => partIndex.get(partID)),
    dropPart: vi.fn((partID: string) => { partIndex.delete(partID) }),
  }
  const router = { send: vi.fn() }
  const wanling = { sendStream: vi.fn() }
  const partDispatcher = new PartDispatcher({
    store: store as any,
    router: router as any,
    metaSync: { syncAfterLoopEnd: vi.fn() } as any,
    compaction: { completePending: vi.fn() } as any,
    emitter: new EventEmitter(),
    wanling: wanling as any,
  })
  return { partDispatcher, state, store, router, wanling }
}

describe("PartDispatcher 流式输出", () => {
  beforeEach(() => { vi.useFakeTimers() })
  afterEach(() => { vi.useRealTimers() })

  it("主 session part_delta 首块立即推 op=14,后续 300ms 节流", async () => {
    const { partDispatcher, state, wanling } = makePartDispatcherFixture()
    state.isChildSession = false
    state.convId = "conv-1"

    // 创建 reasoning part(无 end → 进入 state.reasoning 槽 + indexPart)
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "reasoning", id: "p-1", text: "开始", time: { start: 1 } },
      time: 1,
    })

    // 首块 delta 立即推全量快照
    partDispatcher.onPartDelta({ sessionID: "sess-1", messageID: "m-1", partID: "p-1", field: "text", delta: "思" })
    expect(wanling.sendStream).toHaveBeenCalledTimes(1)
    expect(wanling.sendStream).toHaveBeenCalledWith("conv-1", {
      stream_id: expect.any(String),
      msg_type: "reasoning",
      text: "开始思",
    })

    // 300ms 内第二块被节流(不推)
    partDispatcher.onPartDelta({ sessionID: "sess-1", messageID: "m-1", partID: "p-1", field: "text", delta: "考" })
    expect(wanling.sendStream).toHaveBeenCalledTimes(1)

    // 推进 300ms 后再推
    vi.advanceTimersByTime(300)
    partDispatcher.onPartDelta({ sessionID: "sess-1", messageID: "m-1", partID: "p-1", field: "text", delta: "中" })
    expect(wanling.sendStream).toHaveBeenCalledTimes(2)
  })

  it("子 session 不流式(streamId 不生成,sendStream 不调)", async () => {
    const { partDispatcher, state, wanling } = makePartDispatcherFixture()
    state.isChildSession = true
    await partDispatcher.onPartUpdated({
      sessionID: "sess-child",
      part: { type: "text", id: "p-2", text: "子", time: { start: 1 } },
      time: 1,
    })
    partDispatcher.onPartDelta({ sessionID: "sess-child", messageID: "m-2", partID: "p-2", field: "text", delta: "agent" })
    expect(wanling.sendStream).not.toHaveBeenCalled()
  })

  it("终态 part.end 附 _stream_id 缓存到 pendingText(根治:等 step-finish 判定 silent)", async () => {
    const { partDispatcher, state, router } = makePartDispatcherFixture()
    state.isChildSession = false
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1", part: { type: "text", id: "p-1", text: "", time: { start: 1 } }, time: 1,
    })
    partDispatcher.onPartDelta({ sessionID: "sess-1", messageID: "m-1", partID: "p-1", field: "text", delta: "回复" })
    const streamId = state.text?.streamId
    expect(streamId).toBeTruthy()

    // part.end → 终态消息缓存到 pendingText(附 _stream_id,等 step-finish 判定后发出)
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "text", id: "p-1", text: "回复", time: { start: 1, end: 2 } },
      time: 2,
    })
    expect(state.pendingText?.text).toBe("回复")
    expect(state.pendingText?.streamId).toBe(streamId)
    expect(router.send).not.toHaveBeenCalled()
    // state.text 清空(streamId 随之释放)
    expect(state.text).toBeNull()
  })

  // ===== 根治:最终回复 markdown 非静默(未读锚点 = 真实内容)=====
  // 背景:agent 最终回复的 markdown 被 silent=true 标记(不计未读),server 只能用
  // step_finish 哨兵(finished=true,silent 缺失)作未读锚点 → APP 定位到哨兵,
  // 前面的 markdown 开头被截。根治:text 终态缓存到 pendingText,等 step-finish
  // 判定 isLoopEnd 后再发——最终回复以 silent=false 发(markdown 成为未读载体),
  // 中间步骤以 silent=true 发(不打扰)。
  it("text 终态缓存到 pendingText(不立即发),等 step-finish 判定", async () => {
    const { partDispatcher, state, router } = makePartDispatcherFixture()
    state.isChildSession = false

    // text start + delta → end
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1", part: { type: "text", id: "p-1", text: "", time: { start: 1 } }, time: 1,
    })
    partDispatcher.onPartDelta({ sessionID: "sess-1", messageID: "m-1", partID: "p-1", field: "text", delta: "最终回复" })
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1", part: { type: "text", id: "p-1", text: "最终回复", time: { start: 1, end: 2 } }, time: 2,
    })

    // 断言:text 终态已缓存到 pendingText,未立即发(等 isLoopEnd 判定)
    expect(state.pendingText?.text).toBe("最终回复")
    expect(router.send).not.toHaveBeenCalled()
  })

  it("step-finish isLoopEnd → 缓存 text 以 silent=false 发(最终回复成为未读载体)", async () => {
    const { partDispatcher, state, router } = makePartDispatcherFixture()
    state.isChildSession = false

    await partDispatcher.onPartUpdated({
      sessionID: "sess-1", part: { type: "text", id: "p-1", text: "", time: { start: 1 } }, time: 1,
    })
    partDispatcher.onPartDelta({ sessionID: "sess-1", messageID: "m-1", partID: "p-1", field: "text", delta: "最终回复" })
    const streamId = state.text?.streamId
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1", part: { type: "text", id: "p-1", text: "最终回复", time: { start: 1, end: 2 } }, time: 2,
    })
    router.send.mockClear()

    // step-finish isLoopEnd(reason=stop,主 session)
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: {
        type: "step-finish", id: "p-finish-1", reason: "stop",
        cost: 0.01, tokens: { total: 100 },
      },
      time: 3,
    })

    // 断言:缓存的 markdown 以 silent=false 发(_stream_id 保留让 APP 替换占位)
    expect(router.send).toHaveBeenCalledWith(
      state, "markdown",
      { text: "最终回复", _stream_id: streamId },
      false, // silent=false → 最终回复计未读
    )
    expect(state.pendingText).toBeUndefined()
  })

  it("step-finish 非 isLoopEnd → 缓存 text 以 silent=true 发(中间步骤不打扰)", async () => {
    const { partDispatcher, state, router } = makePartDispatcherFixture()
    state.isChildSession = false

    await partDispatcher.onPartUpdated({
      sessionID: "sess-1", part: { type: "text", id: "p-1", text: "", time: { start: 1 } }, time: 1,
    })
    partDispatcher.onPartDelta({ sessionID: "sess-1", messageID: "m-1", partID: "p-1", field: "text", delta: "中间小结" })
    const streamId = state.text?.streamId
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1", part: { type: "text", id: "p-1", text: "中间小结", time: { start: 1, end: 2 } }, time: 2,
    })
    router.send.mockClear()

    // step-finish 非 isLoopEnd(reason=tool,中间步骤)
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: {
        type: "step-finish", id: "p-finish-mid", reason: "tool",
        cost: 0.005, tokens: { total: 60 },
      },
      time: 3,
    })

    // 断言:缓存的 markdown 以 silent=true 发
    expect(router.send).toHaveBeenCalledWith(
      state, "markdown",
      { text: "中间小结", _stream_id: streamId },
      true,
    )
    expect(state.pendingText).toBeUndefined()
  })

  it("无 text 终态(纯工具回合)→ isLoopEnd 不发 markdown,仅 step_finish(silent=true)", async () => {
    const { partDispatcher, state, router } = makePartDispatcherFixture()
    state.isChildSession = false

    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: {
        type: "step-finish", id: "p-finish-1", reason: "stop",
        cost: 0.01, tokens: { total: 100 },
      },
      time: 3,
    })

    // 断言:无缓存 text → 只发 step_finish(silent=true,结束标记不响铃不计未读)
    expect(router.send).toHaveBeenCalledTimes(1)
    expect(router.send).toHaveBeenCalledWith(
      state, "step_finish",
      expect.objectContaining({ finished: true, reason: "stop" }),
      true,
    )
  })
})

describe("Streamer 消息顺序(text 终态先于 tool_card 落库,对齐 TUI 思考/文本/工具)", () => {
  beforeEach(() => _resetInflight())

  it("PartDispatcher:text 累积未 end 时收到 tool part,应 flush text 终态并防迟到的 text end 重复发送", async () => {
    const { partDispatcher, state, router } = makePartDispatcherFixture()
    state.isChildSession = false
    state.convId = "conv-1"

    // text start + delta 累积(无 end → 不发终态,只建流式占位)
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1", part: { type: "text", id: "p-1", text: "", time: { start: 1 } }, time: 1,
    })
    partDispatcher.onPartDelta({ sessionID: "sess-1", messageID: "m-1", partID: "p-1", field: "text", delta: "你好" })
    partDispatcher.onPartDelta({ sessionID: "sess-1", messageID: "m-1", partID: "p-1", field: "text", delta: "世界" })

    // 收到 tool part(LLM 已从文本切走,text end 尚未推来)
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "tool", id: "p-tool-1", tool: "bash", state: { status: "running", input: { command: "ls" } } },
      time: 2,
    })

    // 断言:markdown 终态已发(完整文本)+ 标记 textPartsFlushed + 槽清空
    expect(router.send).toHaveBeenCalledWith(
      state, "markdown",
      expect.objectContaining({ text: "你好世界" }),
      true,
    )
    expect(state.textPartsFlushed.has("p-1")).toBe(true)
    expect(state.text).toBeNull()

    // 后续 OC 延迟推 text end → 命中 textPartsFlushed,不重复发送
    router.send.mockClear()
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1", part: { type: "text", id: "p-1", text: "你好世界", time: { start: 1, end: 2 } }, time: 3,
    })
    expect(router.send).not.toHaveBeenCalled()
  })

  it("Streamer 整链:text 未 end 时收到 tool running,markdown 终态应先于 tool_card 落库", async () => {
    const { streamer, wanling } = makeStreamer("sess-main")

    // 主 session 首事件建群
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main", part: { type: "text", id: "p-t1", text: "", time: { start: 1 } }, time: 1,
    })

    // 手动塞入已累积完整但未 end 的 text(模拟 delta 流式结束、text end 未到)
    const sessions = (streamer as any).sessions as Map<string, any>
    const state = sessions.get("sess-main")
    state.text = { text: "完整的文本", partID: "p-t1", streamId: "sid-1", lastFlushedAt: 0, lastFlushedLen: 0 }

    // tool running 到达
    await (streamer as any).onPartUpdated({
      sessionID: "sess-main",
      part: { type: "tool", id: "p-tool-1", tool: "bash", state: { status: "running", input: { command: "ls" } } },
      time: 2,
    })
    await new Promise((r) => setImmediate(r))

    // markdown 终态应先于 tool_card 落库(对齐 TUI:思考→文本→工具)
    const markdownIdx = wanling.sendTypedMessage.mock.invocationCallOrder[0]
    const cardIdx = wanling.sendCardMessage.mock.invocationCallOrder[0]
    expect(markdownIdx).toBeDefined()
    expect(cardIdx).toBeDefined()
    expect(markdownIdx).toBeLessThan(cardIdx)
    expect(wanling.sendTypedMessage).toHaveBeenCalledWith(
      "conv-new", "markdown",
      expect.objectContaining({ text: "完整的文本" }),
      expect.any(Object),
    )
  })
})
