import { describe, it, expect, vi, beforeEach } from "vitest"
import { AggregateCardManager } from "./aggregate_card.js"
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
})
