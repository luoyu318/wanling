import { describe, it, expect, vi } from "vitest"
import { EventEmitter } from "events"
import { ToolCardManager } from "./tool_card.js"
import { getAggregateCard, toolCardElement } from "./aggregate_bridge.js"
import { MessageRouter } from "../messaging.js"
import { SessionStore } from "../session_store.js"
import type { WanlingClient } from "../../wanling/client.js"
import type { SessionState } from "../types.js"

// ToolCardManager 聚合卡改造单测:mock store/router/wanling,直接断言
// 普通 tool + task 在聚合开关开/关、子 session 三种场景下的行为差异。
// 聚合模式:主 session 的 task 卡作为聚合卡内 tool_card 元素(含 sub_session_id),
// childSessionTree 以聚合卡 msgId 为 parentMsgId;子 session 恒不聚合(独立卡串树)。
function makeFixture(opts: { aggregateCardEnabled?: boolean } = {}) {
  const state: SessionState = {
    reasoning: null,
    text: null,
    convId: "conv-1",
    toolPartsSent: new Set(),
    textPartsFlushed: new Set(),
    toolCardMsgIds: new Map(),
    toolCardInflight: new Map(),
  }
  const store = {
    registerChild: vi.fn(),
    cleanupChild: vi.fn(),
    getChild: vi.fn(),
  }
  const router = {
    send: vi.fn(),
    sendCard: vi.fn().mockResolvedValue("tool-msg-1"),
  }
  const wanling: WanlingClient & {
    sendCardMessage: ReturnType<typeof vi.fn>
    patchAggregateMessage: ReturnType<typeof vi.fn>
    updateMessageContent: ReturnType<typeof vi.fn>
  } = {
    sendCardMessage: vi.fn().mockResolvedValue("card-1"),
    patchAggregateMessage: vi.fn().mockResolvedValue(undefined),
    updateMessageContent: vi.fn().mockResolvedValue(undefined),
  } as any
  const manager = new ToolCardManager({
    store: store as any,
    router: router as any,
    wanling: wanling as any,
    emitter: new EventEmitter(),
    aggregateCardEnabled: opts.aggregateCardEnabled ?? true,
  })
  return { manager, state, store, router, wanling }
}

function toolPart(
  id: string,
  tool: string,
  status: string,
  extra: Record<string, unknown> = {},
): { id: string; type: string; tool: string; state: Record<string, unknown> } {
  return { id, type: "tool", tool, state: { status, ...extra } }
}

function lastPatch(wanling: ReturnType<typeof makeFixture>["wanling"]) {
  const calls = wanling.patchAggregateMessage.mock.calls
  return calls[calls.length - 1]
}

// 真实 SessionStore + ToolCardManager fixture(聚合开):session_store 的 working/
// 超时兜底 PATCH 走真实 childSessionTree 注册链路,断言全量 data 不丢字段。
function makeRealFixture(childTimeoutMs: number) {
  const wanling = {
    sendCardMessage: vi.fn().mockResolvedValue("card-1"),
    patchAggregateMessage: vi.fn().mockResolvedValue(undefined),
    updateMessageContent: vi.fn().mockResolvedValue(undefined),
    sendTypedMessage: vi.fn(),
  } as any
  const router = new MessageRouter(wanling)
  const store = new SessionStore({
    mainSessionId: "sess-main",
    ensureDeps: {} as any,
    wanling,
    router,
    childTimeoutMs,
  })
  const manager = new ToolCardManager({
    store,
    router,
    wanling,
    emitter: new EventEmitter(),
    aggregateCardEnabled: true,
  })
  const state: SessionState = {
    reasoning: null,
    text: null,
    convId: "conv-1",
    toolPartsSent: new Set(),
    textPartsFlushed: new Set(),
    toolCardMsgIds: new Map(),
    toolCardInflight: new Map(),
  }
  return { wanling, store, manager, state }
}

describe("ToolCardManager 聚合模式 task 提前注册(childSessionTree 竞态修复)", () => {
  it("task running 同步注册 childSessionTree(不等 append PATCH),子 session 事件到达不再被丢弃", async () => {
    // 真实 SessionStore + 真实 ToolCardManager:验证注册时机早于 append PATCH 完成,
    // 子 session 首事件在竞态窗口内到达时 getOrCreateState 能命中 childSessionTree。
    const wanling = {
      sendCardMessage: vi.fn().mockResolvedValue("card-1"),
      patchAggregateMessage: vi.fn().mockResolvedValue(undefined),
      updateMessageContent: vi.fn().mockResolvedValue(undefined),
      sendTypedMessage: vi.fn(),
    } as any
    const router = new MessageRouter(wanling)
    const store = new SessionStore({
      mainSessionId: "sess-main",
      ensureDeps: {} as any,
      wanling,
      router,
      childTimeoutMs: 60_000,
    })
    const manager = new ToolCardManager({
      store,
      router,
      wanling,
      emitter: new EventEmitter(),
      aggregateCardEnabled: true,
    })
    const state: SessionState = {
      reasoning: null,
      text: null,
      convId: "conv-1",
      toolPartsSent: new Set(),
      textPartsFlushed: new Set(),
      toolCardMsgIds: new Map(),
      toolCardInflight: new Map(),
    }

    // task running:注册必须在 append PATCH 完成前同步发生
    await manager.onPartUpdated(
      toolPart("p-task-1", "task", "running", {
        input: { description: "子任务", prompt: "..." },
        metadata: { parentSessionId: "sess-main", sessionId: "sess-child" },
      }),
      state, "sess-main",
    )

    // append PATCH 尚未完成(setImmediate 未排空),子 session 已注册
    const child = store.getChild("sess-child")
    expect(child).toBeDefined()
    // 注册时聚合卡 msgId 未就绪(首次工具即 task)→ 先用占位 id
    expect(child!.parentMsgId).toBe("pending-aggregate-card")

    // 子 session 首事件此刻到达 → getOrCreateState 命中 childSessionTree,不再丢弃
    const childState = await store.getOrCreateState("sess-child")
    expect(childState).not.toBeNull()
    expect(childState?.convId).toBe("conv-1")
    expect(childState?.isChildSession).toBe(true)

    // append 完成后,占位 parentMsgId/rootMsgId 补成真实聚合卡 msgId
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    expect(child!.parentMsgId).toBe("card-1")
    expect(child!.rootMsgId).toBe("card-1")

    // 清理兜底 timer,避免测试悬挂
    store.stop()
  })

  it("聚合卡已建(aggregateCardMsgId 就绪)时 task running 用真实 msgId 注册,无占位", async () => {
    const wanling = {
      sendCardMessage: vi.fn().mockResolvedValue("card-exists"),
      patchAggregateMessage: vi.fn().mockResolvedValue(undefined),
      updateMessageContent: vi.fn().mockResolvedValue(undefined),
      sendTypedMessage: vi.fn(),
    } as any
    const router = new MessageRouter(wanling)
    const store = new SessionStore({
      mainSessionId: "sess-main",
      ensureDeps: {} as any,
      wanling,
      router,
      childTimeoutMs: 60_000,
    })
    const manager = new ToolCardManager({
      store,
      router,
      wanling,
      emitter: new EventEmitter(),
      aggregateCardEnabled: true,
    })
    const state: SessionState = {
      reasoning: null,
      text: null,
      convId: "conv-1",
      toolPartsSent: new Set(),
      textPartsFlushed: new Set(),
      toolCardMsgIds: new Map(),
      toolCardInflight: new Map(),
    }
    // 思考/正文已先追加 → 聚合卡已建:预设 bridge 的卡消息 id(惰性桥复用)
    getAggregateCard(state, wanling as any).cardMessageId = "card-exists"

    await manager.onPartUpdated(
      toolPart("p-task-1", "task", "running", {
        input: { description: "子任务", prompt: "..." },
        metadata: { parentSessionId: "sess-main", sessionId: "sess-child" },
      }),
      state, "sess-main",
    )

    const child = store.getChild("sess-child")
    expect(child).toBeDefined()
    // 真实 msgId 直接可用,无需占位
    expect(child!.parentMsgId).toBe("card-exists")
    expect(child!.rootMsgId).toBe("card-exists")

    // append 完成后不破坏已就绪的 parentMsgId
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    expect(child!.parentMsgId).toBe("card-exists")
    expect(child!.rootMsgId).toBe("card-exists")

    store.stop()
  })

  it("聚合模式子 session 首事件 working PATCH 携带全量 data(name/input/sub_session_id 不丢)", async () => {
    const { wanling, store, manager, state } = makeRealFixture(60_000)
    await manager.onPartUpdated(
      toolPart("p-task-1", "task", "running", {
        input: { description: "子任务", prompt: "..." },
        metadata: { parentSessionId: "sess-main", sessionId: "sess-child" },
      }),
      state, "sess-main",
    )
    // 等 append 落地(元素进 SDK 镜像)后再触发首事件
    await new Promise((r) => setImmediate(r))
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })

    await store.getOrCreateState("sess-child")

    // 全量 data:partial {status:"working"} 会把分卡旧卡元素整体替换丢 name/input
    expect(lastPatch(wanling)).toEqual([
      "card-1",
      {
        op: "update",
        element_id: "tool_card_1",
        data: { name: "task", input: { description: "子任务", prompt: "..." }, status: "working", sub_session_id: "sess-child" },
      },
    ])
    store.stop()
  })

  it("聚合模式子 session 超时兜底 PATCH 携带全量 data(分卡旧卡整体替换不丢字段)", async () => {
    const { wanling, store, manager, state } = makeRealFixture(30)
    await manager.onPartUpdated(
      toolPart("p-task-1", "task", "running", {
        input: { description: "子任务", prompt: "..." },
        metadata: { parentSessionId: "sess-main", sessionId: "sess-child" },
      }),
      state, "sess-main",
    )
    await new Promise((r) => setImmediate(r))
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })

    // 不 cleanupChild,30ms 兜底 timer 触发超时 PATCH
    const warnSpy = vi.spyOn(console, "warn").mockImplementation(() => {})
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBeGreaterThanOrEqual(2)
    })
    warnSpy.mockRestore()

    expect(lastPatch(wanling)).toEqual([
      "card-1",
      {
        op: "update",
        element_id: "tool_card_1",
        data: {
          name: "task",
          input: { description: "子任务", prompt: "..." },
          output: "子 Agent 超时未完成(>30min)",
          status: "error",
          sub_session_id: "sess-child",
        },
      },
    ])
    store.stop()
  })
})

describe("ToolCardManager 聚合模式(工具 running/completed/error 走聚合卡元素)", () => {
  it("工具 running → 聚合卡追加 tool_card 元素(status:running),不再发独立卡", async () => {
    const { manager, state, router, wanling } = makeFixture()
    await manager.onPartUpdated(
      toolPart("p-bash-1", "bash", "running", { input: { command: "ls" } }),
      state, "sess-1",
    )
    // 排空 setImmediate + 串行队列,等 appendToolElement 落地
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    const [msgId, body] = lastPatch(wanling)
    expect(msgId).toBe("card-1")
    expect(body).toEqual({
      op: "append",
      element: toolCardElement({ name: "bash", input: { command: "ls" }, status: "running" }, 1),
    })
    // 不再发独立 tool_card(sendCard 不被调)
    expect(router.sendCard).not.toHaveBeenCalled()
  })

  it("工具 completed → 更新聚合卡内目标元素 status:completed + output(增量 update,非独立卡 PATCH)", async () => {
    const { manager, state, wanling } = makeFixture()
    await manager.onPartUpdated(
      toolPart("p-bash-1", "bash", "running", { input: { command: "ls" } }),
      state, "sess-1",
    )
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    await manager.onPartUpdated(
      toolPart("p-bash-1", "bash", "completed", { input: { command: "ls" }, output: "done" }),
      state, "sess-1",
    )
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    })
    const [, body] = lastPatch(wanling)
    expect(body).toEqual({
      op: "update",
      element_id: "tool_card_1",
      data: { name: "bash", input: { command: "ls" }, output: "done", status: "completed" },
    })
    // 不再对独立 tool 卡发 updateMessageContent PATCH
    expect(wanling.updateMessageContent).not.toHaveBeenCalled()
  })

  it("edit 工具 completed → 目标元素带 file_diff", async () => {
    const { manager, state, wanling } = makeFixture()
    await manager.onPartUpdated(
      toolPart("p-edit-1", "edit", "running", { input: { filePath: "/tmp/a.txt", oldString: "old", newString: "new" } }),
      state, "sess-1",
    )
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    await manager.onPartUpdated(
      toolPart("p-edit-1", "edit", "completed", { input: { filePath: "/tmp/a.txt", oldString: "old", newString: "new" }, output: "ok" }),
      state, "sess-1",
    )
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    })
    const [, body] = lastPatch(wanling)
    expect(body.op).toBe("update")
    expect(body.data.status).toBe("completed")
    expect(body.data.output).toBe("ok")
    expect(body.data.file_diff).toEqual(
      expect.objectContaining({ file: "a.txt" }),
    )
  })

  it("I3 收尾后迟到工具 completed:零 wire 流量(不 PATCH 已收尾卡/不建孤儿卡)", async () => {
    const { manager, state, wanling } = makeFixture()
    // 工具 running 元素 append 落地(建卡 + append)
    await manager.onPartUpdated(
      toolPart("p-bash-1", "bash", "running", { input: { command: "ls" } }),
      state, "sess-1",
    )
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    // 真实收尾(finalizeCard:footer + set_state done + set_silent false,
    // sealRound 清工具元素映射 + bridge/SDK 双双 sealed)
    await getAggregateCard(state, wanling as any).finalizeCard({ reason: "stop", duration: 1 })
    const baseline = wanling.patchAggregateMessage.mock.calls.length
    // 回合结束后,迟到的 tool completed 事件:定位映射已清 + SDK sealed 缓存双防线,
    // 不再 PATCH 已收尾卡(增量下不误建新卡/不翻回 generating)
    await manager.onPartUpdated(
      toolPart("p-bash-1", "bash", "completed", { input: { command: "ls" }, output: "done" }),
      state, "sess-1",
    )
    await new Promise((r) => setImmediate(r))
    expect(wanling.patchAggregateMessage.mock.calls.length).toBe(baseline)
    expect(wanling.sendCardMessage).toHaveBeenCalledTimes(1)
  })

  it("工具 error → 更新目标元素 status:error + error 字段", async () => {
    const { manager, state, wanling } = makeFixture()
    await manager.onPartUpdated(
      toolPart("p-bash-1", "bash", "running", { input: { command: "ls" } }),
      state, "sess-1",
    )
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    await manager.onPartUpdated(
      toolPart("p-bash-1", "bash", "error", { input: { command: "ls" }, error: "boom" }),
      state, "sess-1",
    )
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    })
    const [, body] = lastPatch(wanling)
    expect(body).toEqual({
      op: "update",
      element_id: "tool_card_1",
      data: { name: "bash", input: { command: "ls" }, error: "boom", status: "error" },
    })
  })

  it("tool element_id 与 reasoning/markdown 共用序号计数器(全卡唯一)", async () => {
    const { manager, state, wanling } = makeFixture()
    state.aggregateSeq = 2
    await manager.onPartUpdated(
      toolPart("p-bash-1", "bash", "running", { input: { command: "ls" } }),
      state, "sess-1",
    )
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    const [, body] = lastPatch(wanling)
    expect(body).toEqual({
      op: "append",
      element: toolCardElement({ name: "bash", input: { command: "ls" }, status: "running" }, 3),
    })
    expect(state.aggregateSeq).toBe(3)
  })

  it("completed 抢占 setImmediate(running flush 未执行):同步补发元素后再更新,最终 status:completed", async () => {
    const { manager, state, wanling } = makeFixture()
    await manager.onPartUpdated(
      toolPart("p-bash-1", "bash", "running", { input: { command: "ls" } }),
      state, "sess-1",
    )
    // 不排空 setImmediate,completed 立即到达(等效旧逻辑 resolveMsgId 分支 3 抢占窗口)
    await manager.onPartUpdated(
      toolPart("p-bash-1", "bash", "completed", { input: { command: "ls" }, output: "done" }),
      state, "sess-1",
    )
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    })
    // 之后 setImmediate 执行 flushPending 时 pending 已被消费,不产生第三张重复 running 元素
    await new Promise((r) => setImmediate(r))
    expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    const [, body] = lastPatch(wanling)
    expect(body).toEqual({
      op: "update",
      element_id: "tool_card_1",
      data: { name: "bash", input: { command: "ls" }, output: "done", status: "completed" },
    })
  })

  it("聚合模式下 task running → 追加 tool_card 元素(status:starting + sub_session_id),注册 childSessionTree", async () => {
    const { manager, state, store, router, wanling } = makeFixture()
    const taskPart = toolPart("p-task-1", "task", "running", {
      input: { description: "子任务", prompt: "..." },
      metadata: { parentSessionId: "sess-1", sessionId: "sess-child" },
    })
    await manager.onPartUpdated(taskPart, state, "sess-1")
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    await vi.waitFor(() => {
      expect(store.registerChild).toHaveBeenCalled()
    })
    const [msgId, body] = lastPatch(wanling)
    expect(msgId).toBe("card-1")
    expect(body).toEqual({
      op: "append",
      element: toolCardElement(
        { name: "task", input: { description: "子任务", prompt: "..." }, status: "starting", sub_session_id: "sess-child" },
        1,
      ),
    })
    // 不再发独立 task 卡(sendCard 不被调)
    expect(router.sendCard).not.toHaveBeenCalled()
    // registerChild 以聚合卡 msgId 为 parentMsgId(子 session 消息串到聚合卡下)
    expect(store.registerChild).toHaveBeenCalledWith(
      state, "card-1", "sess-child", "sess-1",
      { description: "子任务", prompt: "..." },
      expect.objectContaining({ elementId: "tool_card_1" }),
    )
  })

  it("聚合模式下 task completed → 更新聚合元素 status:completed + output + sub_session_id,并清理 childSessionTree", async () => {
    const { manager, state, store, wanling } = makeFixture()
    await manager.onPartUpdated(
      toolPart("p-task-1", "task", "running", {
        input: { description: "子任务", prompt: "..." },
        metadata: { parentSessionId: "sess-1", sessionId: "sess-child" },
      }),
      state, "sess-1",
    )
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    await vi.waitFor(() => {
      expect(store.registerChild).toHaveBeenCalled()
    })
    await manager.onPartUpdated(
      toolPart("p-task-1", "task", "completed", {
        input: { description: "子任务", prompt: "..." },
        output: "任务完成",
        metadata: { parentSessionId: "sess-1", sessionId: "sess-child" },
      }),
      state, "sess-1",
    )
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    })
    const [, body] = lastPatch(wanling)
    expect(body).toEqual({
      op: "update",
      element_id: "tool_card_1",
      data: { name: "task", input: { description: "子任务", prompt: "..." }, output: "任务完成", status: "completed", sub_session_id: "sess-child" },
    })
    // 不对独立 task 卡发 updateMessageContent PATCH
    expect(wanling.updateMessageContent).not.toHaveBeenCalled()
    expect(store.cleanupChild).toHaveBeenCalledWith("sess-child")
  })

  it("聚合模式下 task error → 更新聚合元素 status:error + error 字段", async () => {
    const { manager, state, store, wanling } = makeFixture()
    await manager.onPartUpdated(
      toolPart("p-task-1", "task", "running", {
        input: { description: "子任务", prompt: "..." },
        metadata: { parentSessionId: "sess-1", sessionId: "sess-child" },
      }),
      state, "sess-1",
    )
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    await vi.waitFor(() => {
      expect(store.registerChild).toHaveBeenCalled()
    })
    await manager.onPartUpdated(
      toolPart("p-task-1", "task", "error", {
        input: { description: "子任务", prompt: "..." },
        error: "boom",
        metadata: { parentSessionId: "sess-1", sessionId: "sess-child" },
      }),
      state, "sess-1",
    )
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    })
    const [, body] = lastPatch(wanling)
    expect(body).toEqual({
      op: "update",
      element_id: "tool_card_1",
      data: { name: "task", input: { description: "子任务", prompt: "..." }, error: "boom", status: "error", sub_session_id: "sess-child" },
    })
    expect(store.cleanupChild).toHaveBeenCalledWith("sess-child")
  })

  it("聚合模式下 task completed 抢占 setImmediate:同步补发 starting 元素再更新,registerChild 仍注册", async () => {
    const { manager, state, store, wanling } = makeFixture()
    const running = toolPart("p-task-1", "task", "running", {
      input: { description: "子任务", prompt: "..." },
      metadata: { parentSessionId: "sess-1", sessionId: "sess-child" },
    })
    const completed = toolPart("p-task-1", "task", "completed", {
      input: { description: "子任务", prompt: "..." },
      output: "任务完成",
      metadata: { parentSessionId: "sess-1", sessionId: "sess-child" },
    })
    await manager.onPartUpdated(running, state, "sess-1")
    // 不排空 setImmediate,completed 立即到达(等效旧逻辑 resolveMsgId 分支 3 抢占窗口)
    await manager.onPartUpdated(completed, state, "sess-1")
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    })
    await vi.waitFor(() => {
      expect(store.registerChild).toHaveBeenCalled()
    })
    // 之后 setImmediate 执行 flushPending 时 pending 已被消费,不产生重复 starting 元素
    await new Promise((r) => setImmediate(r))
    expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    const [, body] = lastPatch(wanling)
    expect(body).toEqual({
      op: "update",
      element_id: "tool_card_1",
      data: { name: "task", input: { description: "子任务", prompt: "..." }, output: "任务完成", status: "completed", sub_session_id: "sess-child" },
    })
    expect(store.cleanupChild).toHaveBeenCalledWith("sess-child")
  })
})

describe("ToolCardManager 非聚合回退(AGGREGATE_CARD_ENABLED=false)", () => {
  it("running 发独立卡(router.sendCard),completed 对独立卡 updateMessageContent PATCH", async () => {
    const { manager, state, router, wanling } = makeFixture({ aggregateCardEnabled: false })
    await manager.onPartUpdated(
      toolPart("p-bash-1", "bash", "running", { input: { command: "ls" } }),
      state, "sess-1",
    )
    await new Promise((r) => setImmediate(r))
    expect(router.sendCard).toHaveBeenCalledWith(
      state, "tool_card",
      expect.objectContaining({ name: "bash", status: "running" }),
    )
    // 不建聚合卡
    expect(wanling.patchAggregateMessage).not.toHaveBeenCalled()
    expect(wanling.sendCardMessage).not.toHaveBeenCalled()

    await manager.onPartUpdated(
      toolPart("p-bash-1", "bash", "completed", { input: { command: "ls" }, output: "done" }),
      state, "sess-1",
    )
    expect(wanling.updateMessageContent).toHaveBeenCalledWith(
      "tool-msg-1",
      expect.objectContaining({
        msg_type: "tool_card",
        data: expect.objectContaining({ status: "completed", output: "done" }),
      }),
    )
  })

  it("error 对独立卡 updateMessageContent PATCH", async () => {
    const { manager, state, wanling } = makeFixture({ aggregateCardEnabled: false })
    await manager.onPartUpdated(
      toolPart("p-bash-1", "bash", "running", { input: { command: "ls" } }),
      state, "sess-1",
    )
    await new Promise((r) => setImmediate(r))
    await manager.onPartUpdated(
      toolPart("p-bash-1", "bash", "error", { input: { command: "ls" }, error: "boom" }),
      state, "sess-1",
    )
    expect(wanling.updateMessageContent).toHaveBeenCalledWith(
      "tool-msg-1",
      expect.objectContaining({
        msg_type: "tool_card",
        data: expect.objectContaining({ status: "error", error: "boom" }),
      }),
    )
  })

  it("开关默认开启(不传 aggregateCardEnabled → 聚合路径)", async () => {
    const { manager, state, router, wanling } = makeFixture({ aggregateCardEnabled: undefined })
    await manager.onPartUpdated(
      toolPart("p-bash-1", "bash", "running", { input: { command: "ls" } }),
      state, "sess-1",
    )
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    expect(router.sendCard).not.toHaveBeenCalled()
  })

  it("非聚合模式下 task running 仍走独立卡(starting + sub_session_id),registerChild 用 task 卡 msgId", async () => {
    const { manager, state, store, router, wanling } = makeFixture({ aggregateCardEnabled: false })
    await manager.onPartUpdated(
      toolPart("p-task-1", "task", "running", {
        input: { description: "子任务", prompt: "..." },
        metadata: { parentSessionId: "sess-1", sessionId: "sess-child" },
      }),
      state, "sess-1",
    )
    await new Promise((r) => setImmediate(r))
    await Promise.resolve()
    expect(router.sendCard).toHaveBeenCalledWith(
      state, "tool_card",
      expect.objectContaining({ name: "task", status: "starting", sub_session_id: "sess-child" }),
    )
    expect(store.registerChild).toHaveBeenCalledWith(
      state, "tool-msg-1", "sess-child", "sess-1",
      { description: "子任务", prompt: "..." },
    )
    expect(wanling.patchAggregateMessage).not.toHaveBeenCalled()
    expect(wanling.sendCardMessage).not.toHaveBeenCalled()
  })

  it("非聚合模式下 task completed 对独立卡 updateMessageContent PATCH(status:completed + sub_session_id)", async () => {
    const { manager, state, store, wanling } = makeFixture({ aggregateCardEnabled: false })
    await manager.onPartUpdated(
      toolPart("p-task-1", "task", "running", {
        input: { description: "子任务", prompt: "..." },
        metadata: { parentSessionId: "sess-1", sessionId: "sess-child" },
      }),
      state, "sess-1",
    )
    await new Promise((r) => setImmediate(r))
    await Promise.resolve()
    await manager.onPartUpdated(
      toolPart("p-task-1", "task", "completed", {
        input: { description: "子任务", prompt: "..." },
        output: "任务完成",
        metadata: { parentSessionId: "sess-1", sessionId: "sess-child" },
      }),
      state, "sess-1",
    )
    expect(wanling.updateMessageContent).toHaveBeenCalledWith(
      "tool-msg-1",
      expect.objectContaining({
        msg_type: "tool_card",
        data: expect.objectContaining({ status: "completed", output: "任务完成", sub_session_id: "sess-child" }),
      }),
    )
    expect(store.cleanupChild).toHaveBeenCalledWith("sess-child")
    expect(wanling.patchAggregateMessage).not.toHaveBeenCalled()
  })
})

describe("ToolCardManager 存活信号采集(runningToolParts 随状态机增删)", () => {
  it("tool part 终态后 runningToolParts 清除该 partId(存活信号 S1)", async () => {
    const { manager, state } = makeFixture()
    state.runningToolParts = new Set<string>()
    // 普通工具 running → completed 全链路:running 时 partId 即入集合(同步段,不等发卡),
    // 终态分支入口无条件清除(part 状态以 opencode 事件为准)
    await manager.onPartUpdated(
      toolPart("p1", "bash", "running", { input: { command: "sleep 100" } }),
      state, "s1",
    )
    expect(state.runningToolParts.has("p1")).toBe(true)
    await manager.onPartUpdated(
      toolPart("p1", "bash", "completed", { input: { command: "sleep 100" }, output: "done" }),
      state, "s1",
    )
    expect(state.runningToolParts.has("p1")).toBe(false)
  })

  it("task part 终态后 runningToolParts 清除该 partId(存活信号 S1)", async () => {
    const { manager, state } = makeFixture()
    state.runningToolParts = new Set<string>()
    await manager.onPartUpdated(
      toolPart("p2", "task", "running", {
        input: { description: "子任务", prompt: "..." },
        metadata: { parentSessionId: "s1", sessionId: "sess-child" },
      }),
      state, "s1",
    )
    expect(state.runningToolParts.has("p2")).toBe(true)
    await manager.onPartUpdated(
      toolPart("p2", "task", "completed", {
        input: { description: "子任务", prompt: "..." },
        output: "任务完成",
        metadata: { parentSessionId: "s1", sessionId: "sess-child" },
      }),
      state, "s1",
    )
    expect(state.runningToolParts.has("p2")).toBe(false)
  })
})

describe("ToolCardManager 子 session 不聚合", () => {
  it("子 session 工具 running 仍发独立卡(保持 parent/root 串树),不追加聚合元素", async () => {
    const { manager, state, router, wanling } = makeFixture()
    state.isChildSession = true
    state.childEntry = {
      parentMsgId: "task-msg-1",
      rootMsgId: "task-msg-1",
      depth: 1,
      state,
      parentSessionId: "sess-main",
      hasFirstEvent: true,
    } as any
    await manager.onPartUpdated(
      toolPart("p-bash-1", "bash", "running", { input: { command: "ls" } }),
      state, "sess-child",
    )
    await new Promise((r) => setImmediate(r))
    expect(router.sendCard).toHaveBeenCalledWith(
      state, "tool_card",
      expect.objectContaining({ name: "bash", status: "running" }),
    )
    expect(wanling.patchAggregateMessage).not.toHaveBeenCalled()
    expect(wanling.sendCardMessage).not.toHaveBeenCalled()
  })
})
