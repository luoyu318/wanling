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
})

describe("AggregateCardManager patchElements", () => {
  let wanling: ReturnType<typeof makeWanling>["wanling"]

  beforeEach(() => {
    wanling = makeWanling().wanling
  })

  it("全量替换:patchAggregateMessage 传 elements,state 默认 generating", async () => {
    const manager = new AggregateCardManager(wanling, makeState())
    const elements = [AggregateCardManager.markdown("hello", 1)]
    await manager.patchElements(elements)
    expect(wanling.sendCardMessage).toHaveBeenCalledTimes(1)
    expect(wanling.patchAggregateMessage).toHaveBeenCalledWith(
      "card-1",
      { state: undefined, elements },
      undefined,
    )
  })

  it("silent 翻转:传 {silent:false, state:'done'} 时 content 带 silent:false", async () => {
    const manager = new AggregateCardManager(wanling, makeState())
    const elements = [AggregateCardManager.footer({ finished: true, tokens: { total: 1200 } }, 1)]
    await manager.patchElements(elements, { silent: false, state: "done" })
    expect(wanling.patchAggregateMessage).toHaveBeenCalledWith(
      "card-1",
      { state: "done", elements },
      { silent: false },
    )
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
})
