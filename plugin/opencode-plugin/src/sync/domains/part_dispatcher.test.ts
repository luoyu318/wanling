import { describe, it, expect, vi } from "vitest"
import { EventEmitter } from "events"
import { PartDispatcher } from "./part_dispatcher.js"
import { AggregateCardManager } from "./aggregate_card.js"
import type { WanlingClient } from "../../wanling/client.js"
import type { SessionState } from "../types.js"

// PartDispatcher 聚合卡改造单测:mock store/router/wanling,直接断言
// reasoning/text/step-finish 三条路径在聚合卡开关开/关下的行为差异。
function makeFixture(opts: { aggregateCardEnabled?: boolean } = {}) {
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
  const store = {
    getOrCreateState: vi.fn(async () => state),
    indexPart: vi.fn((partID: string, s: SessionState) => { partIndex.set(partID, s) }),
    getPart: vi.fn((partID: string) => partIndex.get(partID)),
    dropPart: vi.fn((partID: string) => { partIndex.delete(partID) }),
  }
  const router = { send: vi.fn() }
  const wanling: WanlingClient & {
    sendStream: ReturnType<typeof vi.fn>
    sendCardMessage: ReturnType<typeof vi.fn>
    patchAggregateMessage: ReturnType<typeof vi.fn>
  } = {
    sendStream: vi.fn(),
    sendCardMessage: vi.fn().mockResolvedValue("card-1"),
    patchAggregateMessage: vi.fn().mockResolvedValue(undefined),
  } as any
  const partDispatcher = new PartDispatcher({
    store: store as any,
    router: router as any,
    metaSync: { syncAfterLoopEnd: vi.fn() } as any,
    compaction: { completePending: vi.fn() } as any,
    emitter: new EventEmitter(),
    wanling: wanling as any,
    aggregateCardEnabled: opts.aggregateCardEnabled ?? true,
  })
  return { partDispatcher, state, store, router, wanling }
}

describe("PartDispatcher 聚合卡(reasoning/markdown/step_finish 转元素)", () => {
  it("reasoning time.end → 建聚合卡并追加 reasoning 元素,不再发独立 reasoning 消息", async () => {
    const { partDispatcher, router, wanling } = makeFixture()
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "reasoning", id: "p-r1", text: "思考过程", time: { start: 1, end: 2 } },
      time: 2,
    })
    expect(wanling.sendCardMessage).toHaveBeenCalledWith("conv-1", "aggregate_card", {
      state: "generating",
      elements: [],
    })
    expect(wanling.patchAggregateMessage).toHaveBeenCalledWith(
      "card-1",
      { state: undefined, elements: [AggregateCardManager.reasoning("思考过程", 1)] },
      undefined,
    )
    expect(router.send).not.toHaveBeenCalled()
  })

  it("text time.end → 缓存 pendingText 不立即追加,等 step-finish 判定 silent", async () => {
    const { partDispatcher, state, wanling } = makeFixture()
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "text", id: "p-t1", text: "最终回复", time: { start: 1, end: 2 } },
      time: 2,
    })
    expect(state.pendingText?.text).toBe("最终回复")
    expect(wanling.patchAggregateMessage).not.toHaveBeenCalled()
  })

  it("step-finish isLoopEnd → 追加 markdown + footer 元素,patch({silent:false,state:'done'})", async () => {
    const { partDispatcher, router, wanling } = makeFixture()
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "text", id: "p-t1", text: "最终回复", time: { start: 1, end: 2 } },
      time: 2,
    })
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "step-finish", id: "p-f1", reason: "stop", cost: 0.01, tokens: { total: 100 } },
      time: 3,
    })
    // 第一次 PATCH:markdown 元素(等 step-finish 判定后才追加),silent 不翻转
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(
      1,
      "card-1",
      { state: undefined, elements: [AggregateCardManager.markdown("最终回复", 1)] },
      undefined,
    )
    // 第二次 PATCH:footer 元素 + 整卡翻转 silent:false + state:done
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(
      2,
      "card-1",
      {
        state: "done",
        elements: [
          AggregateCardManager.markdown("最终回复", 1),
          AggregateCardManager.footer({ reason: "stop", cost: 0.01, tokens: { total: 100 }, duration: 0, finished: true }, 2),
        ],
      },
      { silent: false },
    )
    // 不再发独立 step_finish 消息
    expect(router.send).not.toHaveBeenCalled()
  })

  it("step-finish 非 isLoopEnd(中间步骤)→ 追加 footer 元素但 silent 不翻转、state 保持 generating", async () => {
    const { partDispatcher, wanling } = makeFixture()
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "text", id: "p-t1", text: "中间小结", time: { start: 1, end: 2 } },
      time: 2,
    })
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "step-finish", id: "p-f-mid", reason: "tool", cost: 0.005, tokens: { total: 60 } },
      time: 3,
    })
    const calls = wanling.patchAggregateMessage.mock.calls
    const last = calls[calls.length - 1]
    expect(last[0]).toBe("card-1")
    expect(last[1].state).toBeUndefined()
    expect(last[2]).toBeUndefined()
    expect(last[1].elements).toEqual([
      AggregateCardManager.markdown("中间小结", 1),
      AggregateCardManager.footer({ reason: "tool", cost: 0.005, tokens: { total: 60 }, duration: 0, finished: false }, 2),
    ])
  })

  it("seq 递增:reasoning + markdown + footer 共用计数器,element_id 全局唯一", async () => {
    const { partDispatcher, wanling } = makeFixture()
    // reasoning end → reasoning_1
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "reasoning", id: "p-r1", text: "思考", time: { start: 1, end: 2 } },
      time: 2,
    })
    // text end → pendingText
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "text", id: "p-t1", text: "回复", time: { start: 1, end: 2 } },
      time: 3,
    })
    // step-finish → markdown_2 + footer_3
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "step-finish", id: "p-f1", reason: "stop" },
      time: 4,
    })
    const calls = wanling.patchAggregateMessage.mock.calls
    const last = calls[calls.length - 1]
    expect(last[1].elements.map((e: { element_id: string }) => e.element_id)).toEqual([
      "reasoning_1",
      "markdown_2",
      "footer_3",
    ])
  })

  it("流式仍走 op=14(sendStream),聚合卡模式不改 PATCH", async () => {
    const { partDispatcher, wanling } = makeFixture()
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "text", id: "p-t1", text: "", time: { start: 1 } },
      time: 1,
    })
    partDispatcher.onPartDelta({
      sessionID: "sess-1", messageID: "m-1", partID: "p-t1", field: "text", delta: "打",
    })
    // 聚合模式下 sendStream 经 ensureCard 微任务后异步发出,waitFor 等首帧落地。
    await vi.waitFor(() => {
      expect(wanling.sendStream).toHaveBeenCalledWith(
        "conv-1",
        expect.objectContaining({ msg_type: "markdown", text: "打" }),
      )
    })
    expect(wanling.patchAggregateMessage).not.toHaveBeenCalled()
  })

  it("聚合模式 markdown 流式帧带 aggregate:{message_id, element_id}", async () => {
    const { partDispatcher, wanling } = makeFixture()
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "text", id: "p-t1", text: "", time: { start: 1 } },
      time: 1,
    })
    partDispatcher.onPartDelta({
      sessionID: "sess-1", messageID: "m-1", partID: "p-t1", field: "text", delta: "打",
    })
    await vi.waitFor(() => {
      expect(wanling.sendStream).toHaveBeenCalled()
    })
    expect(wanling.sendStream).toHaveBeenCalledWith(
      "conv-1",
      expect.objectContaining({
        stream_id: expect.any(String),
        msg_type: "markdown",
        text: "打",
        aggregate: { message_id: "card-1", element_id: "markdown_1" },
      }),
    )
    // aggregate 定位字段需要建卡,首帧前 ensureCard 建聚合卡
    expect(wanling.sendCardMessage).toHaveBeenCalled()
  })

  it("聚合模式 reasoning 流式帧带 aggregate:{message_id, element_id}", async () => {
    const { partDispatcher, wanling } = makeFixture()
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "reasoning", id: "p-r1", text: "", time: { start: 1 } },
      time: 1,
    })
    partDispatcher.onPartDelta({
      sessionID: "sess-1", messageID: "m-1", partID: "p-r1", field: "text", delta: "想",
    })
    await vi.waitFor(() => {
      expect(wanling.sendStream).toHaveBeenCalled()
    })
    expect(wanling.sendStream).toHaveBeenCalledWith(
      "conv-1",
      expect.objectContaining({
        msg_type: "reasoning",
        text: "想",
        aggregate: { message_id: "card-1", element_id: "reasoning_1" },
      }),
    )
  })

  it("终态 append 用流式预留的同一 element_id(APP 端定位连续)", async () => {
    const { partDispatcher, wanling } = makeFixture()
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "text", id: "p-t1", text: "", time: { start: 1 } },
      time: 1,
    })
    partDispatcher.onPartDelta({
      sessionID: "sess-1", messageID: "m-1", partID: "p-t1", field: "text", delta: "打",
    })
    await vi.waitFor(() => {
      expect(wanling.sendStream).toHaveBeenCalledWith(
        "conv-1",
        expect.objectContaining({ aggregate: { message_id: "card-1", element_id: "markdown_1" } }),
      )
    })
    // text 终态 → pendingText → step-finish → 终态 markdown 元素与流式帧同一 element_id
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "text", id: "p-t1", text: "打", time: { start: 1, end: 2 } },
      time: 2,
    })
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "step-finish", id: "p-f1", reason: "stop", cost: 0.01, tokens: { total: 100 } },
      time: 3,
    })
    const calls = wanling.patchAggregateMessage.mock.calls
    const last = calls[calls.length - 1]
    expect(last[1].elements.map((e: { element_id: string }) => e.element_id)).toEqual([
      "markdown_1",
      "footer_2",
    ])
  })

  it("流式中途其他元素 append 不挤占预留 seq(终态 markdown 仍用流式 element_id)", async () => {
    const { partDispatcher, wanling } = makeFixture()
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "text", id: "p-t1", text: "", time: { start: 1 } },
      time: 1,
    })
    partDispatcher.onPartDelta({
      sessionID: "sess-1", messageID: "m-1", partID: "p-t1", field: "text", delta: "打",
    })
    await vi.waitFor(() => {
      expect(wanling.sendStream).toHaveBeenCalledWith(
        "conv-1",
        expect.objectContaining({ aggregate: { message_id: "card-1", element_id: "markdown_1" } }),
      )
    })
    // 流式中途 reasoning 终态追加元素,取下一个 seq=2(不挤占流式预留的 1)
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "reasoning", id: "p-r2", text: "中间思考", time: { start: 2, end: 3 } },
      time: 3,
    })
    // text 终态 + step-finish:markdown 仍用预留的 markdown_1,footer 取 seq 3
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "text", id: "p-t1", text: "打", time: { start: 1, end: 2 } },
      time: 4,
    })
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "step-finish", id: "p-f1", reason: "stop" },
      time: 5,
    })
    const calls = wanling.patchAggregateMessage.mock.calls
    const last = calls[calls.length - 1]
    expect(last[1].elements.map((e: { element_id: string }) => e.element_id)).toEqual([
      "reasoning_2",
      "markdown_1",
      "footer_3",
    ])
  })

  it("子 session 不聚合:reasoning/text 仍走独立消息(保持 parent/root 串树语义)", async () => {
    const { partDispatcher, state, router, wanling } = makeFixture()
    state.isChildSession = true
    state.childEntry = { parentMsgId: "p-1", rootMsgId: "p-1", depth: 1, state, parentSessionId: "parent", hasFirstEvent: true } as any
    await partDispatcher.onPartUpdated({
      sessionID: "sess-child",
      part: { type: "reasoning", id: "p-r1", text: "子思考", time: { start: 1, end: 2 } },
      time: 2,
    })
    expect(router.send).toHaveBeenCalledWith(state, "reasoning", { text: "子思考" }, true)
    expect(wanling.sendCardMessage).not.toHaveBeenCalled()
  })
})

describe("PartDispatcher 聚合卡开关回退(AGGREGATE_CARD_ENABLED=false)", () => {
  it("reasoning/text/step-finish 全部回退旧逐条发送", async () => {
    const { partDispatcher, state, router, wanling } = makeFixture({ aggregateCardEnabled: false })
    // reasoning end → 独立 reasoning 消息
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "reasoning", id: "p-r1", text: "思考", time: { start: 1, end: 2 } },
      time: 2,
    })
    expect(router.send).toHaveBeenCalledWith(state, "reasoning", { text: "思考" }, true)

    // text end → pendingText 缓存 → step-finish isLoopEnd → 独立 markdown(silent=false) + step_finish
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "text", id: "p-t1", text: "最终回复", time: { start: 1, end: 2 } },
      time: 3,
    })
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "step-finish", id: "p-f1", reason: "stop", cost: 0.01, tokens: { total: 100 } },
      time: 4,
    })
    expect(router.send).toHaveBeenCalledWith(state, "markdown", { text: "最终回复" }, false)
    expect(router.send).toHaveBeenCalledWith(
      state, "step_finish",
      expect.objectContaining({ finished: true, reason: "stop", cost: 0.01 }),
      true,
    )
    // 全程不建卡
    expect(wanling.sendCardMessage).not.toHaveBeenCalled()
    expect(wanling.patchAggregateMessage).not.toHaveBeenCalled()
  })

  it("非聚合模式流式帧不带 aggregate(APP 走旧独立占位)", async () => {
    const { partDispatcher, wanling } = makeFixture({ aggregateCardEnabled: false })
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "text", id: "p-t1", text: "", time: { start: 1 } },
      time: 1,
    })
    partDispatcher.onPartDelta({
      sessionID: "sess-1", messageID: "m-1", partID: "p-t1", field: "text", delta: "打",
    })
    expect(wanling.sendStream).toHaveBeenCalledWith(
      "conv-1",
      expect.objectContaining({ msg_type: "markdown", text: "打" }),
    )
    const call = wanling.sendStream.mock.calls[0]
    expect(call[1].aggregate).toBeUndefined()
    // 非聚合模式不建卡,流式帧不需要 message_id
    expect(wanling.sendCardMessage).not.toHaveBeenCalled()
  })

  it("开关默认开启(不传 aggregateCardEnabled → 聚合路径)", async () => {
    const { partDispatcher, router, wanling } = makeFixture({ aggregateCardEnabled: undefined })
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "reasoning", id: "p-r1", text: "思考", time: { start: 1, end: 2 } },
      time: 2,
    })
    expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    expect(router.send).not.toHaveBeenCalled()
  })
})
