import { describe, it, expect, vi } from "vitest"
import { EventEmitter } from "events"
import { PartDispatcher } from "./part_dispatcher.js"
import { AggregateCardManager, AGGREGATE_SCHEMA_VER } from "./aggregate_card.js"
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
    metaSync: { syncAfterLoopEnd: vi.fn(), peekFullMeta: vi.fn(() => undefined), fetchTurnDuration: vi.fn(async () => 0) } as any,
    compaction: { completePending: vi.fn() } as any,
    emitter: new EventEmitter(),
    wanling: wanling as any,
    aggregateCardEnabled: opts.aggregateCardEnabled ?? true,
  })
  return { partDispatcher, state, store, router, wanling }
}

describe("PartDispatcher 聚合卡(reasoning/markdown/step_finish 转元素)", () => {
  // 按 PATCH 顺序提取聚合卡元素 element_id(append 取 element_id,update 取目标 element_id),
  // 用于断言终态/占位复用同一 element_id、序号全卡唯一递增。
  function orderedElementIds(wanling: ReturnType<typeof makeFixture>["wanling"]): string[] {
    return wanling.patchAggregateMessage.mock.calls
      .map(([, body]) => {
        if (body.op === "append") return [body.element.element_id]
        if (body.op === "update") return [body.element_id]
        return []
      })
      .flat()
  }

  it("reasoning time.end → 建聚合卡并追加 reasoning 元素,不再发独立 reasoning 消息", async () => {
    const { partDispatcher, router, wanling } = makeFixture()
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "reasoning", id: "p-r1", text: "思考过程", time: { start: 1, end: 2 } },
      time: 2,
    })
    expect(wanling.sendCardMessage).toHaveBeenCalledWith("conv-1", "aggregate_card", {
      schema_ver: AGGREGATE_SCHEMA_VER,
      state: "generating",
      elements: [],
    })
    expect(wanling.patchAggregateMessage).toHaveBeenCalledWith(
      "card-1",
      { op: "append", element: AggregateCardManager.reasoning("思考过程", 1, true) },
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

  it("step-finish isLoopEnd → 追加 markdown + footer 元素,set_state:done + set_silent:false 单独发 op", async () => {
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
    // 第一次 PATCH:markdown 元素(等 step-finish 判定后才追加)
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(
      1,
      "card-1",
      { op: "append", element: AggregateCardManager.markdown("最终回复", 1) },
    )
    // 第二次 PATCH:footer 元素
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(
      2,
      "card-1",
      { op: "append", element: AggregateCardManager.footer({ reason: "stop", cost: 0.01, tokens: { total: 100 }, duration: 0, finished: true }, 2) },
    )
    // 第三/四次 PATCH:state 翻 done + silent 翻 false(不再随 append 全量携带)
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(3, "card-1", { op: "set_state", state: "done" })
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(4, "card-1", { op: "set_silent", silent: false })
    expect(wanling.patchAggregateMessage).toHaveBeenCalledTimes(4)
    // 不再发独立 step_finish 消息
    expect(router.send).not.toHaveBeenCalled()
  })

  it("step-finish isLoopEnd → footer 带 mode/model 快照(读 metaSync.peekFullMeta)", async () => {
    const { partDispatcher, wanling } = makeFixture()
    ;(partDispatcher as any).metaSync.peekFullMeta = vi.fn(() => ({ mode: "build", modelId: "deepseek-v3", modelName: "DeepSeek-V3" }))
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
    expect(wanling.patchAggregateMessage).toHaveBeenCalledWith(
      "card-1",
      { op: "append", element: expect.objectContaining({
        type: "footer",
        data: expect.objectContaining({ mode: "build", model: "DeepSeek-V3", finished: true }),
      }) },
    )
  })

  it("step-finish isLoopEnd → footer duration 取 metaSync.fetchTurnDuration(回合耗时)", async () => {
    const { partDispatcher, wanling } = makeFixture()
    ;(partDispatcher as any).metaSync.fetchTurnDuration = vi.fn(async () => 12.3)
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
    expect(wanling.patchAggregateMessage).toHaveBeenCalledWith(
      "card-1",
      { op: "append", element: expect.objectContaining({
        type: "footer",
        data: expect.objectContaining({ duration: 12.3, finished: true }),
      }) },
    )
    expect((partDispatcher as any).metaSync.fetchTurnDuration).toHaveBeenCalledWith("sess-1")
  })

  it("step-finish metaSync.peekFullMeta 未命中 → footer 不写 mode/model", async () => {
    const { partDispatcher, wanling } = makeFixture()
    ;(partDispatcher as any).metaSync.peekFullMeta = vi.fn(() => undefined)
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
    const footerCall = wanling.patchAggregateMessage.mock.calls
      .map(([, b]: [string, any]) => b)
      .find((b: any) => b.op === "append" && b.element.type === "footer")
    expect(footerCall.element.data.mode).toBeUndefined()
    expect(footerCall.element.data.model).toBeUndefined()
  })

  it("step-finish 非 isLoopEnd(中间步骤)→ 不追加 footer(过程性 footer 无意义且隔断工具卡合并)", async () => {
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
    // flushPendingText(markdown)走 fire-and-forget,waitFor 等落地
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    const appended = wanling.patchAggregateMessage.mock.calls.map(([, b]: [string, any]) => b)
    // 只 append markdown,不追加 footer(无任何 footer 元素)
    const footerAppends = appended.filter((b: any) => b.op === "append" && b.element.type === "footer")
    expect(footerAppends).toHaveLength(0)
    // state 不翻 done(中间步骤整卡保持 generating)
    expect(wanling.patchAggregateMessage).not.toHaveBeenCalledWith(
      "card-1",
      { op: "set_state", state: "done" },
    )
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
    expect(orderedElementIds(wanling)).toEqual([
      "reasoning_1",
      "markdown_2",
      "footer_3",
    ])
  })

  it("I1 流式首帧前先 append 目标元素占位(空 text 或当前累积),帧能命中同一 element_id", async () => {
    const { partDispatcher, wanling } = makeFixture()
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "text", id: "p-t1", text: "", time: { start: 1 } },
      time: 1,
    })
    partDispatcher.onPartDelta({
      sessionID: "sess-1", messageID: "m-1", partID: "p-t1", field: "text", delta: "打",
    })
    // 首帧推流前目标元素已 PATCH 进聚合卡(否则 APP 端 _applyAggregateStreamUpdate
    // 因元素不存在丢弃帧 → 整个生成期无中间文本)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    const [msgId, body] = wanling.patchAggregateMessage.mock.calls[0]
    expect(msgId).toBe("card-1")
    expect(body).toEqual({ op: "append", element: AggregateCardManager.markdown("打", 1) })
    // 占位 PATCH 落地后才发流式帧(帧能命中已存在的 markdown_1)
    await vi.waitFor(() => {
      expect(wanling.sendStream).toHaveBeenCalledWith(
        "conv-1",
        expect.objectContaining({
          msg_type: "markdown",
          text: "打",
          aggregate: { message_id: "card-1", element_id: "markdown_1" },
        }),
      )
    })
    const patchOrder = wanling.patchAggregateMessage.mock.invocationCallOrder[0]
    const streamOrder = wanling.sendStream.mock.invocationCallOrder[0]
    expect(patchOrder).toBeLessThan(streamOrder)
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

  it("C1 多轮重置:第二次 step-finish isLoopEnd 建新卡,新卡 elements 从空开始", async () => {
    const { partDispatcher, wanling } = makeFixture()
    wanling.sendCardMessage
      .mockResolvedValueOnce("card-1")
      .mockResolvedValueOnce("card-2")
    // 第一轮:text end → pendingText;step-finish isLoopEnd → markdown + footer 上 card-1
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "text", id: "p-t1", text: "第一轮回复", time: { start: 1, end: 2 } },
      time: 2,
    })
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "step-finish", id: "p-f1", reason: "stop", cost: 0.01, tokens: { total: 100 } },
      time: 3,
    })
    expect(wanling.sendCardMessage).toHaveBeenCalledTimes(1)
    // 第二轮:text end → pendingText;step-finish isLoopEnd → 应建新卡 card-2
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "text", id: "p-t2", text: "第二轮回复", time: { start: 4, end: 5 } },
      time: 5,
    })
    await partDispatcher.onPartUpdated({
      sessionID: "sess-1",
      part: { type: "step-finish", id: "p-f2", reason: "stop", cost: 0.02, tokens: { total: 200 } },
      time: 6,
    })
    expect(wanling.sendCardMessage).toHaveBeenCalledTimes(2)
    expect(wanling.sendCardMessage).toHaveBeenLastCalledWith("conv-1", "aggregate_card", {
      schema_ver: AGGREGATE_SCHEMA_VER,
      state: "generating",
      elements: [],
    })
    // 第二轮 markdown PATCH 用 card-2,新卡 elements 从空开始(不带旧卡元素)
    const calls = wanling.patchAggregateMessage.mock.calls
    const round2FirstPatch = calls.filter(([mid]) => mid === "card-2")[0]
    expect(round2FirstPatch[1]).toEqual({
      op: "append",
      element: AggregateCardManager.markdown("第二轮回复", 1),
    })
    // 第二轮 footer 同样落在 card-2
    expect(calls.filter(([mid]) => mid === "card-2")[1][0]).toBe("card-2")
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
    // text 终态 → pendingText → step-finish → 终态 markdown 与流式帧同一 element_id
    // (占位已存在 → upsert 发 update 原位替换,避免 server 出双元素)
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
    const updateCalls = wanling.patchAggregateMessage.mock.calls.filter(([, b]) => b.op === "update")
    // 终态 markdown 发 update 定位 markdown_1(与流式占位同一 element_id)
    expect(updateCalls[0][1].element_id).toBe("markdown_1")
    expect(updateCalls[0][1].data).toEqual({ text: "打" })
    const footerAppend = wanling.patchAggregateMessage.mock.calls.find(([, b]) => b.op === "append" && b.element.type === "footer")
    expect(footerAppend![1].element.element_id).toBe("footer_2")
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
    // 流式首帧已 append markdown_1 占位(text delta 先于 reasoning 终态到达),
    // 终态 markdown 同 element_id upsert 更新,footer 取 seq 3
    expect(orderedElementIds(wanling)).toEqual([
      "markdown_1",
      "reasoning_2",
      "markdown_1",
      "footer_3",
    ])
    // footer 的 element_id 确认 seq 未被流式占位挤占
    const footerAppend = calls.find(([, b]) => b.op === "append" && b.element.type === "footer")
    expect(footerAppend![1].element.element_id).toBe("footer_3")
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
