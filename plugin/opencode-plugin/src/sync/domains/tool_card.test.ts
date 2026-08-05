import { describe, it, expect, vi } from "vitest"
import { EventEmitter } from "events"
import { ToolCardManager } from "./tool_card.js"
import { AggregateCardManager } from "./aggregate_card.js"
import type { WanlingClient } from "../../wanling/client.js"
import type { SessionState } from "../types.js"

// ToolCardManager 聚合卡改造单测:mock store/router/wanling,直接断言
// 普通 tool 在聚合开关开/关、子 session 三种场景下的行为差异。
// task 工具恒走独立卡(保留 childSessionTree 消息级 parent/root 串树语义),
// 不受聚合开关影响,这里覆盖其保持独立的回归。
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
    expect(body.elements).toEqual([
      AggregateCardManager.toolCard({ name: "bash", input: { command: "ls" }, status: "running" }, 1),
    ])
    // 不再发独立 tool_card(sendCard 不被调)
    expect(router.sendCard).not.toHaveBeenCalled()
  })

  it("工具 completed → 更新聚合卡内目标元素 status:completed + output(全量替换,PATCH 非独立卡)", async () => {
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
    expect(body.elements).toEqual([
      AggregateCardManager.toolCard(
        { name: "bash", input: { command: "ls" }, output: "done", status: "completed" },
        1,
      ),
    ])
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
    expect(body.elements[0].data.status).toBe("completed")
    expect(body.elements[0].data.output).toBe("ok")
    expect(body.elements[0].data.file_diff).toEqual(
      expect.objectContaining({ file: "a.txt" }),
    )
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
    expect(body.elements).toEqual([
      AggregateCardManager.toolCard(
        { name: "bash", input: { command: "ls" }, error: "boom", status: "error" },
        1,
      ),
    ])
  })

  it("tool element_id 与 reasoning/markdown 共用序号计数器(全卡唯一)", async () => {
    const { manager, state, wanling } = makeFixture()
    state.aggregateSeq = 2
    state.aggregateElements = [AggregateCardManager.reasoning("思考", 1), AggregateCardManager.markdown("正文", 2)]
    await manager.onPartUpdated(
      toolPart("p-bash-1", "bash", "running", { input: { command: "ls" } }),
      state, "sess-1",
    )
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    const [, body] = lastPatch(wanling)
    expect(body.elements.map((e: { element_id: string }) => e.element_id)).toEqual([
      "reasoning_1",
      "markdown_2",
      "tool_card_3",
    ])
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
    expect(body.elements).toEqual([
      AggregateCardManager.toolCard(
        { name: "bash", input: { command: "ls" }, output: "done", status: "completed" },
        1,
      ),
    ])
  })

  it("聚合模式下 task 工具保持独立卡(保留 childSessionTree 消息级 parent/root 语义)", async () => {
    const { manager, state, store, router, wanling } = makeFixture()
    await manager.onPartUpdated(
      toolPart("p-task-1", "task", "running", {
        input: { description: "子任务", prompt: "..." },
        metadata: { parentSessionId: "sess-1", sessionId: "sess-child" },
      }),
      state, "sess-1",
    )
    await new Promise((r) => setImmediate(r))
    await Promise.resolve()
    // task 卡仍走独立 sendCard(starting 状态),不追加聚合元素
    expect(router.sendCard).toHaveBeenCalledWith(
      state, "tool_card",
      expect.objectContaining({ name: "task", status: "starting", sub_session_id: "sess-child" }),
    )
    expect(store.registerChild).toHaveBeenCalled()
    expect(wanling.patchAggregateMessage).not.toHaveBeenCalled()
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
