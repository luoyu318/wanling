import { describe, it, expect, vi, beforeEach } from "vitest"
import { AggregateCardManager, AGGREGATE_SCHEMA_VER } from "./aggregate_card.js"
import type { WanlingClient } from "../../wanling/client.js"
import type { SessionState } from "../types.js"

function makeWanling(): { wanling: WanlingClient & { sendCardMessage: ReturnType<typeof vi.fn>; patchAggregateMessage: ReturnType<typeof vi.fn> } } {
  const wanling = {
    sendCardMessage: vi.fn().mockResolvedValue("card-1"),
    patchAggregateMessage: vi.fn().mockResolvedValue(undefined),
  } as any
  return { wanling }
}

function makeState(): SessionState {
  return {
    reasoning: null,
    text: null,
    convId: "conv-1",
    toolPartsSent: new Set(),
    textPartsFlushed: new Set(),
    toolCardMsgIds: new Map(),
    toolCardInflight: new Map(),
  }
}

describe("AggregateCardManager ensureCard", () => {
  let wanling: ReturnType<typeof makeWanling>["wanling"]

  beforeEach(() => {
    wanling = makeWanling().wanling
  })

  it("首次建卡:sendCardMessage 建空聚合卡并返回真实 msgId", async () => {
    const manager = new AggregateCardManager(wanling, makeState())
    const msgId = await manager.ensureCard()
    expect(msgId).toBe("card-1")
    expect(wanling.sendCardMessage).toHaveBeenCalledWith("conv-1", "aggregate_card", {
      schema_ver: AGGREGATE_SCHEMA_VER,
      state: "generating",
      elements: [],
    })
  })

  it("再次调用幂等复用:不重复建卡,返回同一 msgId(含跨实例共享 state)", async () => {
    const state = makeState()
    const manager1 = new AggregateCardManager(wanling, state)
    const manager2 = new AggregateCardManager(wanling, state)
    const first = await manager1.ensureCard()
    const second = await manager2.ensureCard()
    expect(second).toBe(first)
    expect(wanling.sendCardMessage).toHaveBeenCalledTimes(1)
  })

  it("并发首调:sendCardMessage 飞行中共享 state 两次 ensureCard 只建一张卡", async () => {
    let resolveCard!: (v: string) => void
    wanling.sendCardMessage.mockReturnValue(new Promise((r) => { resolveCard = r }))
    const state = makeState()
    const manager1 = new AggregateCardManager(wanling, state)
    const manager2 = new AggregateCardManager(wanling, state)
    const p1 = manager1.ensureCard()
    const p2 = manager2.ensureCard()
    resolveCard("card-1")
    const [id1, id2] = await Promise.all([p1, p2])
    expect(id1).toBe("card-1")
    expect(id2).toBe("card-1")
    expect(wanling.sendCardMessage).toHaveBeenCalledTimes(1)
    // 完成后再调 ensureCard 走 msgId 缓存,不再发建卡
    const again = await new AggregateCardManager(wanling, state).ensureCard()
    expect(again).toBe("card-1")
    expect(wanling.sendCardMessage).toHaveBeenCalledTimes(1)
  })

  it("并发首调建卡失败:失败方 reject,等待方重新发起建卡(不产生双卡)", async () => {
    wanling.sendCardMessage
      .mockRejectedValueOnce(new Error("boom"))
      .mockResolvedValueOnce("card-2")
    const state = makeState()
    const m1 = new AggregateCardManager(wanling, state)
    const m2 = new AggregateCardManager(wanling, state)
    const p1 = m1.ensureCard()
    const p2 = m2.ensureCard()
    // 发起方失败(首建卡请求 reject)
    await expect(p1).rejects.toThrow("boom")
    // 等待方 await 同一 inflight 失败后重新发起建卡 → 拿到 card-2
    // (p1 未建成,重新发起不产生双卡)
    await expect(p2).resolves.toBe("card-2")
    expect(wanling.sendCardMessage).toHaveBeenCalledTimes(2)
    // 建卡成功后幂等复用,不再发建卡
    const again = await new AggregateCardManager(wanling, state).ensureCard()
    expect(again).toBe("card-2")
    expect(wanling.sendCardMessage).toHaveBeenCalledTimes(2)
  })
})

describe("AggregateCardManager appendElement(增量 op)", () => {
  let wanling: ReturnType<typeof makeWanling>["wanling"]

  beforeEach(() => {
    wanling = makeWanling().wanling
  })

  it("追加元素:patchAggregateMessage 传 {op:'append', element},建卡仍全量(空 elements)", async () => {
    const manager = new AggregateCardManager(wanling, makeState())
    const element = AggregateCardManager.markdown("hello", 1)
    await manager.appendElement(element)
    expect(wanling.sendCardMessage).toHaveBeenCalledWith("conv-1", "aggregate_card", {
      schema_ver: AGGREGATE_SCHEMA_VER,
      state: "generating",
      elements: [],
    })
    expect(wanling.patchAggregateMessage).toHaveBeenCalledWith(
      "card-1",
      { op: "append", element },
    )
    expect(wanling.patchAggregateMessage).toHaveBeenCalledTimes(1)
  })

  it("state 变更:append 后单独发 {op:'set_state', state:'done'},并维护 aggregateCardState", async () => {
    const state = makeState()
    const manager = new AggregateCardManager(wanling, state)
    const element = AggregateCardManager.footer({ finished: true, tokens: { total: 1200 } }, 1)
    await manager.appendElement(element, { state: "done" })
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(1, "card-1", { op: "append", element })
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(2, "card-1", { op: "set_state", state: "done" })
    expect(wanling.patchAggregateMessage).toHaveBeenCalledTimes(2)
    expect(state.aggregateCardState).toBe("done")
  })

  it("silent 翻转:append 后单独发 {op:'set_silent', silent:false}", async () => {
    const manager = new AggregateCardManager(wanling, makeState())
    const element = AggregateCardManager.markdown("hello", 1)
    await manager.appendElement(element, { silent: false })
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(1, "card-1", { op: "append", element })
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(2, "card-1", { op: "set_silent", silent: false })
    expect(wanling.patchAggregateMessage).toHaveBeenCalledTimes(2)
  })

  it("回合结束组合:append + set_state + set_silent 三步 op", async () => {
    const manager = new AggregateCardManager(wanling, makeState())
    const element = AggregateCardManager.footer({ finished: true }, 1)
    await manager.appendElement(element, { silent: false, state: "done" })
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(1, "card-1", { op: "append", element })
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(2, "card-1", { op: "set_state", state: "done" })
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(3, "card-1", { op: "set_silent", silent: false })
    expect(wanling.patchAggregateMessage).toHaveBeenCalledTimes(3)
  })

  it("upsert:同一 element_id 已存在(流式占位)发 update 原位替换,server 无 append upsert", async () => {
    const state = makeState()
    state.aggregateElements = [AggregateCardManager.markdown("打", 1)]
    const manager = new AggregateCardManager(wanling, state)
    await manager.appendElement(AggregateCardManager.markdown("打完整", 1))
    expect(wanling.patchAggregateMessage).toHaveBeenCalledWith(
      "card-1",
      { op: "update", element_id: "markdown_1", data: { text: "打完整" } },
    )
    expect(state.aggregateElements).toEqual([AggregateCardManager.markdown("打完整", 1)])
  })
})

describe("AggregateCardManager 分卡(满 20 自动开新卡)", () => {
  let wanling: ReturnType<typeof makeWanling>["wanling"]

  beforeEach(() => {
    wanling = makeWanling().wanling
  })

  it("第 20 个元素仍在当前卡(未达上限不切)", async () => {
    const state = makeState()
    // 先铺 19 个元素(模拟流式占位等已追加,无需真实 PATCH)
    state.aggregateElements = Array.from({ length: 19 }, (_, i) =>
      AggregateCardManager.markdown(`m${i + 1}`, i + 1),
    )
    state.aggregateCardMsgId = "card-1"
    const manager = new AggregateCardManager(wanling, state)
    await manager.appendElement(AggregateCardManager.markdown("m20", 20))
    expect(wanling.sendCardMessage).not.toHaveBeenCalled() // aggregateCardMsgId 已缓存,复用不建卡
    expect(wanling.patchAggregateMessage).toHaveBeenCalledWith(
      "card-1", { op: "append", element: AggregateCardManager.markdown("m20", 20) },
    )
    expect(wanling.patchAggregateMessage).not.toHaveBeenCalledWith("card-1", { op: "set_state", state: "done" })
  })

  it("第 21 个元素触发切卡:旧卡 set_state done(不写 footer/silent),元素 append 到新卡", async () => {
    const state = makeState()
    state.aggregateElements = Array.from({ length: 20 }, (_, i) =>
      AggregateCardManager.markdown(`m${i + 1}`, i + 1),
    )
    state.aggregateCardMsgId = "card-1"
    state.aggregateCardState = "generating"
    wanling.sendCardMessage.mockResolvedValueOnce("card-2") // 切卡后建新卡返回 card-2
    const manager = new AggregateCardManager(wanling, state)
    const el = AggregateCardManager.markdown("m21", 21)
    await manager.appendElement(el)
    // 旧卡收尾:只 set_state done
    expect(wanling.patchAggregateMessage).toHaveBeenCalledWith("card-1", { op: "set_state", state: "done" })
    // 元素归属映射:新元素指向 card-2
    expect(state.aggregateElementCardIds?.get("markdown_21")).toBe("card-2")
    expect(state.aggregateElements).toEqual([el])
    expect(wanling.sendCardMessage).toHaveBeenCalledTimes(1) // 仅切卡后的建卡
    expect(wanling.sendCardMessage).toHaveBeenCalledWith("conv-1", "aggregate_card", {
      schema_ver: AGGREGATE_SCHEMA_VER,
      state: "generating",
      elements: [],
    })
  })
})

describe("AggregateCardManager 静态构造器(element_id 规则 type_seq)", () => {
  it("reasoning 元素", () => {
    expect(AggregateCardManager.reasoning("思考中", 1)).toEqual({
      type: "reasoning",
      element_id: "reasoning_1",
      data: { text: "思考中" },
    })
  })

  it("toolCard 元素透传 ToolCardData", () => {
    const data = { name: "bash", input: { command: "ls" }, status: "running" }
    expect(AggregateCardManager.toolCard(data, 2)).toEqual({
      type: "tool_card",
      element_id: "tool_card_2",
      data,
    })
  })

  it("markdown 元素", () => {
    expect(AggregateCardManager.markdown("正文", 3)).toEqual({
      type: "markdown",
      element_id: "markdown_3",
      data: { text: "正文" },
    })
  })

  it("footer 元素透传 FooterData", () => {
    const data = { reason: "stop", cost: 0.1, tokens: { total: 1200 }, duration: 3.2, finished: true }
    expect(AggregateCardManager.footer(data, 4)).toEqual({
      type: "footer",
      element_id: "footer_4",
      data,
    })
  })

  it("footer 元素透传 FooterData(含 mode/model 快照字段)", () => {
    const data = { reason: "stop", cost: 0.1, tokens: { total: 1200 }, duration: 3.2, finished: true, mode: "build", model: "DeepSeek-V3" }
    expect(AggregateCardManager.footer(data, 4)).toEqual({
      type: "footer",
      element_id: "footer_4",
      data,
    })
  })

  it("questionCard 元素透传 QuestionCardData", () => {
    const data = {
      oc_request_id: "q-1",
      questions: [{ question: "继续?", header: "确认", options: [{ label: "是", description: "" }] }],
      status: "pending",
    }
    expect(AggregateCardManager.questionCard(data, 5)).toEqual({
      type: "question_card",
      element_id: "question_card_5",
      data,
    })
  })

  it("permissionCard 元素透传 PermissionCardData", () => {
    const data = {
      oc_request_id: "p-1",
      action: "bash",
      resources: ["*.sh"],
      save: [],
      metadata: {},
      status: "pending",
    }
    expect(AggregateCardManager.permissionCard(data, 6)).toEqual({
      type: "permission_card",
      element_id: "permission_card_6",
      data,
    })
  })
})

describe("AggregateCardManager updateElement", () => {
  let wanling: ReturnType<typeof makeWanling>["wanling"]

  beforeEach(() => {
    wanling = makeWanling().wanling
  })

  it("按 element_id 更新元素:patchAggregateMessage 传 {op:'update', element_id, data}(data 为合并后全量)", async () => {
    const state = makeState()
    state.aggregateElements = [
      AggregateCardManager.questionCard({
        oc_request_id: "q-1",
        questions: [{ question: "继续?", header: "确认", options: [{ label: "是", description: "" }] }],
        status: "pending",
      }, 1),
      AggregateCardManager.markdown("正文", 2),
    ]
    const manager = new AggregateCardManager(wanling, state)
    await manager.updateElement("question_card_1", { status: "answered", result: "是" })
    expect(wanling.patchAggregateMessage).toHaveBeenCalledWith(
      "card-1",
      {
        op: "update",
        element_id: "question_card_1",
        data: {
          oc_request_id: "q-1",
          questions: [{ question: "继续?", header: "确认", options: [{ label: "是", description: "" }] }],
          status: "answered",
          result: "是",
        },
      },
    )
    expect(state.aggregateElements[0].data.status).toBe("answered")
    expect(state.aggregateElements[0].data.result).toBe("是")
  })

  it("silent 翻转:update 后单独发 {op:'set_silent', silent:true}", async () => {
    const state = makeState()
    state.aggregateElements = [
      AggregateCardManager.questionCard({
        oc_request_id: "q-1",
        questions: [{ question: "继续?", header: "确认", options: [{ label: "是", description: "" }] }],
        status: "pending",
      }, 1),
    ]
    const manager = new AggregateCardManager(wanling, state)
    await manager.updateElement("question_card_1", { status: "answered" }, { silent: true })
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(
      1,
      "card-1",
      expect.objectContaining({ op: "update", element_id: "question_card_1" }),
    )
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(2, "card-1", { op: "set_silent", silent: true })
    expect(wanling.patchAggregateMessage).toHaveBeenCalledTimes(2)
  })

  it("element 不存在时不 PATCH(server update 会 400,本地缓存兜底)", async () => {
    const state = makeState()
    const manager = new AggregateCardManager(wanling, state)
    await manager.updateElement("question_card_9", { status: "answered" })
    expect(wanling.patchAggregateMessage).not.toHaveBeenCalled()
  })

  it("竞态:updateElement 早于 append 落地时缓存 pending update,append 后补发 {op:'update'}", async () => {
    const state = makeState()
    const manager = new AggregateCardManager(wanling, state)
    // registerTaskChildEarly 提前注册后,working PATCH 先到(元素尚未 append)
    await manager.updateElement("tool_card_1", { status: "working" })
    // 此时元素未 append,不发 PATCH,只缓存
    expect(wanling.patchAggregateMessage).not.toHaveBeenCalled()
    expect(state.aggregatePendingUpdates?.get("tool_card_1")).toEqual({ status: "working" })
    // append 落地 → 补发 update op(status 合并进元素 data)
    await manager.appendElement(AggregateCardManager.toolCard({
      name: "task", input: { prompt: "x" }, status: "starting", sub_session_id: "sess-child",
    }, 1))
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(
      1,
      "card-1",
      { op: "append", element: AggregateCardManager.toolCard({
        name: "task", input: { prompt: "x" }, status: "starting", sub_session_id: "sess-child",
      }, 1) },
    )
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(
      2,
      "card-1",
      { op: "update", element_id: "tool_card_1", data: {
        name: "task", input: { prompt: "x" }, status: "working", sub_session_id: "sess-child",
      } },
    )
    // 本地累计同步为 working
    expect(state.aggregateElements?.[0].data.status).toBe("working")
    // 缓存已消费
    expect(state.aggregatePendingUpdates?.has("tool_card_1")).toBe(false)
  })

  it("竞态:append 前多次 update 合并缓存字段,append 后一次补发", async () => {
    const state = makeState()
    const manager = new AggregateCardManager(wanling, state)
    await manager.updateElement("tool_card_1", { status: "working" })
    await manager.updateElement("tool_card_1", { duration: 3.2 })
    await manager.appendElement(AggregateCardManager.toolCard({
      name: "task", input: {}, status: "starting",
    }, 1))
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(
      2,
      "card-1",
      { op: "update", element_id: "tool_card_1", data: {
        name: "task", input: {}, status: "working", duration: 3.2,
      } },
    )
  })
})

describe("AggregateCardManager.finishCard", () => {
  let wanling: ReturnType<typeof makeWanling>["wanling"]

  beforeEach(() => {
    wanling = makeWanling().wanling
  })

  it("stop:追加 stopped footer + set_state done + reset", async () => {
    const state = makeState()
    state.aggregateCardMsgId = "card-1"
    state.aggregateCardState = "generating"
    const manager = new AggregateCardManager(wanling, state)

    await manager.finishCard("stop")

    expect(wanling.patchAggregateMessage).toHaveBeenCalledWith(
      "card-1",
      expect.objectContaining({ op: "append" }),
    )
    // reset:msgId/序号/累计清空,aggregateCardState 保留 done(标志本卡已收尾,
    // 幂等守卫靠它区分「活跃卡」与「已收尾」;下一轮 ensureCard 建新卡时置 generating)
    expect(state.aggregateCardState).toBe("done")
    expect(state.aggregateCardMsgId).toBeUndefined() // reset
  })

  it("interrupt:footer 不带 stopped 标记", async () => {
    const state = makeState()
    state.aggregateCardMsgId = "card-1"
    state.aggregateCardState = "generating"
    const manager = new AggregateCardManager(wanling, state)

    await manager.finishCard("interrupt")

    const appendCall = wanling.patchAggregateMessage.mock.calls.find(
      (c: unknown[]) => (c[1] as { op?: string })?.op === "append",
    )
    const element = (appendCall![1] as { element: { data: Record<string, unknown> } }).element
    expect(element.data.stopped).toBe(false)
    expect(element.data.reason).toBe("interrupt")
  })

  it("已 done 幂等:不重复 append", async () => {
    const state = makeState()
    state.aggregateCardMsgId = "card-1"
    state.aggregateCardState = "done"
    const manager = new AggregateCardManager(wanling, state)

    await manager.finishCard("stop")

    expect(wanling.patchAggregateMessage).not.toHaveBeenCalled()
  })

  it("无卡:静默跳过", async () => {
    const state = makeState() // 无 aggregateCardMsgId
    const manager = new AggregateCardManager(wanling, state)

    await manager.finishCard("stop")

    expect(wanling.patchAggregateMessage).not.toHaveBeenCalled()
  })
})

describe("AggregateCardManager.finalizeCard(completed 事件驱动收尾)", () => {
  let wanling: ReturnType<typeof makeWanling>["wanling"]

  beforeEach(() => {
    wanling = makeWanling().wanling
  })

  it("finalizeCard:追加带完整数据 footer(duration/cost/tokens/mode/model) + done + silent", async () => {
    const state = makeState()
    state.aggregateCardMsgId = "card-1"
    state.aggregateCardState = "generating"
    state.aggregateSeq = 3
    const manager = new AggregateCardManager(wanling, state)

    await manager.finalizeCard({
      reason: "stop",
      duration: 13.4,
      cost: 0.01,
      tokens: { total: 100 },
      mode: "build",
      model: "DeepSeek-V3",
    })

    // append footer + set_state done + set_silent false
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(
      1,
      "card-1",
      { op: "append", element: AggregateCardManager.footer({ reason: "stop", cost: 0.01, tokens: { total: 100 }, duration: 13.4, finished: true, mode: "build", model: "DeepSeek-V3" }, 4) },
    )
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(2, "card-1", { op: "set_state", state: "done" })
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(3, "card-1", { op: "set_silent", silent: false })
    // reset:msgId 清空,卡状态保留 done(供幂等守卫),下一轮 ensureCard 建新卡
    expect(state.aggregateCardState).toBe("done")
    expect(state.aggregateCardMsgId).toBeUndefined()
  })

  it("finalizeCard 后 reset:下一轮 ensureCard 建新卡(一次问答一张卡)", async () => {
    const state = makeState()
    const manager = new AggregateCardManager(wanling, state)
    // 第一轮:ensureCard 建卡(第 1 次 sendCardMessage)→ finalizeCard 收尾 reset
    await manager.ensureCard()
    await manager.finalizeCard({ reason: "stop", duration: 3.2 })
    expect(state.aggregateCardMsgId).toBeUndefined()

    // 第二轮:ensureCard 重新建卡(第 2 次 sendCardMessage)
    await manager.ensureCard()
    expect(wanling.sendCardMessage).toHaveBeenCalledTimes(2)
    expect(state.aggregateCardState).toBe("generating")
    expect(state.aggregateCardMsgId).toBe("card-1")
  })

  it("幂等:卡已 done 时跳过(不重复 append footer)", async () => {
    const state = makeState()
    state.aggregateCardMsgId = "card-1"
    state.aggregateCardState = "done"
    const manager = new AggregateCardManager(wanling, state)

    await manager.finalizeCard({ reason: "stop", duration: 1.2 })

    expect(wanling.patchAggregateMessage).not.toHaveBeenCalled()
  })

  it("无卡:静默跳过", async () => {
    const state = makeState() // 无 aggregateCardMsgId
    const manager = new AggregateCardManager(wanling, state)

    await manager.finalizeCard({ reason: "stop", duration: 1.2 })

    expect(wanling.patchAggregateMessage).not.toHaveBeenCalled()
  })
})
