import { describe, it, expect, vi, beforeEach, afterAll } from "vitest"
import { rmSync } from "fs"
import { EventEmitter } from "events"
import type { WanlingClient } from "../../wanling/client.js"
import type { SessionState } from "../types.js"

const TMP = `/tmp/wl-int-${Date.now()}`

vi.mock("../../config.js", () => ({ configDir: () => TMP }))

afterAll(() => {
  rmSync(TMP, { recursive: true, force: true })
})

// InteractionCards 聚合卡嵌入单测:mock store/router/wanling,直接断言
// permission/question 交互卡在聚合开关开/关下的行为差异。
// 聚合模式:正向流 append 聚合卡元素 + 整卡 silent 翻转响铃;
// 反向流更新聚合卡内元素 status + 用户回答后回合继续恢复 silent;
// 开关 false 时完全回退旧逻辑(sendCard 独立卡 + updateMessageContent PATCH)。
// 动态 import(config.js mock 生效后)保证 card_store 写到隔离 TMP,不污染真实配置目录。
const { InteractionCards } = await import("./interaction.js")
const { AggregateCardManager } = await import("./aggregate_card.js")
const { getCard, getAllCards, deleteCard } = await import("../card_store.js")
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
    getOrCreateState: vi.fn(async () => state),
    peekState: vi.fn(() => state),
  }
  const router = { sendCard: vi.fn().mockResolvedValue("perm-msg-1") }
  const wanling: WanlingClient & {
    sendCardMessage: ReturnType<typeof vi.fn>
    patchAggregateMessage: ReturnType<typeof vi.fn>
    updateMessageContent: ReturnType<typeof vi.fn>
  } = {
    sendCardMessage: vi.fn().mockResolvedValue("card-1"),
    patchAggregateMessage: vi.fn().mockResolvedValue(undefined),
    updateMessageContent: vi.fn().mockResolvedValue(undefined),
  } as any
  const toolCard = { flushPending: vi.fn() }
  const interaction = new InteractionCards({
    store: store as any,
    router: router as any,
    wanling: wanling as any,
    toolCard: toolCard as any,
    emitter: new EventEmitter(),
    aggregateCardEnabled: opts.aggregateCardEnabled ?? true,
  })
  return { interaction, state, store, router, wanling, toolCard }
}

function lastPatch(wanling: ReturnType<typeof makeFixture>["wanling"]) {
  const calls = wanling.patchAggregateMessage.mock.calls
  return calls[calls.length - 1]
}

const permissionPayload = {
  id: "req-perm-1",
  sessionID: "sess-1",
  directory: "/tmp",
  action: "bash",
  resources: ["*.sh"],
  source: { type: "tool", messageID: "m1", callID: "c1" },
  save: [],
  metadata: {},
}

const questionPayload = {
  id: "req-q-1",
  sessionID: "sess-1",
  directory: "/tmp",
  questions: [{ question: "继续?", header: "确认", options: [{ label: "是", description: "" }] }],
  tool: { messageID: "m2", callID: "c2" },
}

describe("InteractionCards 聚合模式 — 正向流(pending 元素嵌入聚合卡 + silent 翻转响铃)", () => {
  beforeEach(() => {
    for (const id of Object.keys(getAllCards())) deleteCard(id)
  })

  it("onPermissionAsked → 聚合卡追加 permission 元素 + 整卡翻转 silent=false 响铃,不再发独立卡", async () => {
    const { interaction, state, router, wanling, toolCard } = makeFixture()
    await interaction.onPermissionAsked(permissionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    const [msgId, body, opts] = lastPatch(wanling)
    expect(msgId).toBe("card-1")
    expect(body.elements).toEqual([
      AggregateCardManager.permissionCard({
        oc_request_id: "req-perm-1",
        action: "bash",
        resources: ["*.sh"],
        save: [],
        metadata: {},
        status: "pending",
      }, 1),
    ])
    // pending 交互 → 整卡翻转 silent=false(需要用户介入 → 响铃)
    expect(opts).toEqual({ silent: false })
    // 不再发独立 permission_card
    expect(router.sendCard).not.toHaveBeenCalled()
    // card_store 存聚合卡 msgId + element_id + sessionId(供反向流定位)
    const entry = getCard("req-perm-1")!
    expect(entry.msgId).toBe("card-1")
    expect(entry.elementId).toBe("permission_card_1")
    expect(entry.sessionId).toBe("sess-1")
    expect(entry.type).toBe("permission")
    // 刷新 pending tool_card 仍被调(顺序:审批元素 → 工具元素)
    expect(toolCard.flushPending).toHaveBeenCalledWith(state)
  })

  it("onQuestionAsked → 聚合卡追加 question 元素 + silent=false 响铃 + card_store 存 element_id", async () => {
    const { interaction, router, wanling } = makeFixture()
    await interaction.onQuestionAsked(questionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    const [, body, opts] = lastPatch(wanling)
    expect(body.elements).toEqual([
      AggregateCardManager.questionCard({
        oc_request_id: "req-q-1",
        questions: questionPayload.questions,
        status: "pending",
      }, 1),
    ])
    expect(opts).toEqual({ silent: false })
    expect(router.sendCard).not.toHaveBeenCalled()
    const entry = getCard("req-q-1")!
    expect(entry.elementId).toBe("question_card_1")
    expect(entry.sessionId).toBe("sess-1")
    expect(entry.type).toBe("question")
  })

  it("元素序号与既有元素共用 state.aggregateSeq(全卡唯一递增)", async () => {
    const { interaction, state, wanling } = makeFixture()
    state.aggregateSeq = 2
    state.aggregateElements = [
      AggregateCardManager.reasoning("思考", 1),
      AggregateCardManager.markdown("正文", 2),
    ]
    await interaction.onPermissionAsked(permissionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    const [, body] = lastPatch(wanling)
    expect(body.elements.map((e: { element_id: string }) => e.element_id)).toEqual([
      "reasoning_1",
      "markdown_2",
      "permission_card_3",
    ])
    expect(state.aggregateSeq).toBe(3)
  })

  it("与 part_dispatcher/tool_card 共用串行队列(前一个 pending PATCH 排空后才追加)", async () => {
    const { interaction, state, wanling } = makeFixture()
    let resolveSeed!: () => void
    state.aggregatePatchQueue = new Promise<void>((r) => { resolveSeed = r })
    const p = interaction.onPermissionAsked(permissionPayload)
    await Promise.resolve()
    // 队列前有未 resolve 的 PATCH,interaction 的追加必须排队等待
    expect(wanling.patchAggregateMessage).not.toHaveBeenCalled()
    resolveSeed()
    await p
    expect(wanling.patchAggregateMessage).toHaveBeenCalled()
  })
})

describe("InteractionCards 聚合模式 — 反向流(更新聚合卡内元素 status + silent 状态机)", () => {
  beforeEach(() => {
    for (const id of Object.keys(getAllCards())) deleteCard(id)
  })

  it("onQuestionReplied → 更新聚合卡内元素 status=answered + silent 恢复 true + deleteCard", async () => {
    const { interaction, wanling } = makeFixture()
    await interaction.onQuestionAsked(questionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    await interaction.onQuestionReplied({ sessionID: "sess-1", requestID: "req-q-1", answers: [["是"]] })
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    })
    const [, body, opts] = lastPatch(wanling)
    expect(body.elements).toEqual([
      AggregateCardManager.questionCard({
        oc_request_id: "req-q-1",
        questions: questionPayload.questions,
        status: "answered",
        result: "是",
      }, 1),
    ])
    // 用户回答后回合继续 → silent 恢复 true(不再响铃),回合结束 footer 再翻 false 计未读
    expect(opts).toEqual({ silent: true })
    // 不再对独立 question_card 发 updateMessageContent PATCH
    expect(wanling.updateMessageContent).not.toHaveBeenCalled()
    // 请求已处理 → deleteCard
    expect(getCard("req-q-1")).toBeNull()
  })

  it("onPermissionReplied(approve) → 元素 status=approved + silent 恢复 true + deleteCard", async () => {
    const { interaction, wanling } = makeFixture()
    await interaction.onPermissionAsked(permissionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    await interaction.onPermissionReplied({ sessionID: "sess-1", requestID: "req-perm-1", reply: "once" })
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    })
    const [, body, opts] = lastPatch(wanling)
    expect(body.elements[0].type).toBe("permission_card")
    expect(body.elements[0].data.status).toBe("approved")
    expect(body.elements[0].data.result).toBe("once")
    expect(opts).toEqual({ silent: true })
    expect(wanling.updateMessageContent).not.toHaveBeenCalled()
    expect(getCard("req-perm-1")).toBeNull()
  })

  it("onPermissionReplied(reject) → 元素 status=denied", async () => {
    const { interaction, wanling } = makeFixture()
    await interaction.onPermissionAsked(permissionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    await interaction.onPermissionReplied({ sessionID: "sess-1", requestID: "req-perm-1", reply: "reject" })
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    })
    const [, body] = lastPatch(wanling)
    expect(body.elements[0].data.status).toBe("denied")
    expect(body.elements[0].data.result).toBe("reject")
  })

  it("onQuestionRejected → 元素 status=rejected + silent 恢复 true", async () => {
    const { interaction, wanling } = makeFixture()
    await interaction.onQuestionAsked(questionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    await interaction.onQuestionRejected({ sessionID: "sess-1", requestID: "req-q-1" })
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    })
    const [, body, opts] = lastPatch(wanling)
    expect(body.elements[0].data.status).toBe("rejected")
    expect(body.elements[0].data.result).toBe("rejected")
    expect(opts).toEqual({ silent: true })
    expect(getCard("req-q-1")).toBeNull()
  })

  it("仍有其他 pending 交互时不恢复 silent(整卡继续响铃)", async () => {
    const { interaction, wanling } = makeFixture()
    // 先挂一个 permission pending,再挂 question pending
    await interaction.onPermissionAsked(permissionPayload)
    await interaction.onQuestionAsked(questionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    })
    // 回答 question,但 permission 仍 pending → 不恢复 silent
    await interaction.onQuestionReplied({ sessionID: "sess-1", requestID: "req-q-1", answers: [["是"]] })
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(3)
    })
    const [, body, opts] = lastPatch(wanling)
    const qEl = body.elements.find((e: { element_id: string }) => e.element_id === "question_card_2")
    expect(qEl.data.status).toBe("answered")
    expect(opts).toBeUndefined()
  })

  it("回合已结束(state=done)回答时不恢复 silent(回合结束翻转 false 已计未读)", async () => {
    const { interaction, state, wanling } = makeFixture()
    await interaction.onQuestionAsked(questionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    // 模拟回合已结束(step-finish isLoopEnd 已翻 done)
    state.aggregateCardState = "done"
    await interaction.onQuestionReplied({ sessionID: "sess-1", requestID: "req-q-1", answers: [["是"]] })
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    })
    const [, body, opts] = lastPatch(wanling)
    expect(body.elements[0].data.status).toBe("answered")
    expect(opts).toBeUndefined()
  })

  it("session 状态不可用(peekState miss)时跳过元素更新但仍 deleteCard(回声兜底清理)", async () => {
    const { interaction, store, wanling } = makeFixture()
    await interaction.onQuestionAsked(questionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    store.peekState.mockReturnValue(undefined)
    await interaction.onQuestionReplied({ sessionID: "sess-1", requestID: "req-q-1", answers: [["是"]] })
    // 不追加 PATCH(状态不可用无法全量替换),仍 deleteCard
    expect(wanling.patchAggregateMessage.mock.calls.length).toBe(1)
    expect(getCard("req-q-1")).toBeNull()
  })

  it("跨轮防护:state 聚合卡已是新卡(msgId 不同)时不误更新新卡元素,仍 deleteCard", async () => {
    const { interaction, state, wanling } = makeFixture()
    await interaction.onQuestionAsked(questionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    // 模拟回合已结束并重置:新轮建了新卡(msgId 不同,element_id 从 1 重计)
    state.aggregateCardMsgId = "card-2-new-turn"
    state.aggregateElements = [AggregateCardManager.questionCard({
      oc_request_id: "new-turn-q",
      questions: [{ question: "新一轮?", header: "确认", options: [{ label: "是", description: "" }] }],
      status: "pending",
    }, 1)]
    await interaction.onQuestionReplied({ sessionID: "sess-1", requestID: "req-q-1", answers: [["是"]] })
    // 不追加 PATCH(不能拿旧 entry 的元素 id 误更新新卡),仍 deleteCard
    expect(wanling.patchAggregateMessage.mock.calls.length).toBe(1)
    expect(state.aggregateElements[0].data.status).toBe("pending")
    expect(getCard("req-q-1")).toBeNull()
  })
})

describe("InteractionCards 非聚合回退(aggregateCardEnabled=false)", () => {
  beforeEach(() => {
    for (const id of Object.keys(getAllCards())) deleteCard(id)
  })

  it("onPermissionAsked → sendCard 独立 permission_card(silent=false) + saveCard 无 elementId", async () => {
    const { interaction, state, router, wanling, toolCard } = makeFixture({ aggregateCardEnabled: false })
    await interaction.onPermissionAsked(permissionPayload)
    expect(router.sendCard).toHaveBeenCalledWith(
      state, "permission_card",
      expect.objectContaining({ oc_request_id: "req-perm-1", status: "pending" }),
      false,
    )
    // 不建聚合卡
    expect(wanling.patchAggregateMessage).not.toHaveBeenCalled()
    expect(wanling.sendCardMessage).not.toHaveBeenCalled()
    const entry = getCard("req-perm-1")!
    expect(entry.elementId).toBeUndefined()
    expect(entry.type).toBe("permission")
    expect(toolCard.flushPending).toHaveBeenCalledWith(state)
  })

  it("onPermissionReplied → 对独立卡 updateMessageContent PATCH(approved) + deleteCard", async () => {
    const { interaction, wanling } = makeFixture({ aggregateCardEnabled: false })
    await interaction.onPermissionAsked(permissionPayload)
    await interaction.onPermissionReplied({ sessionID: "sess-1", requestID: "req-perm-1", reply: "always" })
    expect(wanling.updateMessageContent).toHaveBeenCalledWith(
      "perm-msg-1",
      expect.objectContaining({
        msg_type: "permission_card",
        data: expect.objectContaining({ status: "approved", result: "always", oc_request_id: "req-perm-1" }),
      }),
    )
    expect(getCard("req-perm-1")).toBeNull()
  })

  it("onQuestionAsked → sendCard 独立 question_card + saveCard 无 elementId", async () => {
    const { interaction, state, router, wanling } = makeFixture({ aggregateCardEnabled: false })
    await interaction.onQuestionAsked(questionPayload)
    expect(router.sendCard).toHaveBeenCalledWith(
      state, "question_card",
      expect.objectContaining({ oc_request_id: "req-q-1", status: "pending" }),
      false,
    )
    expect(wanling.patchAggregateMessage).not.toHaveBeenCalled()
    const entry = getCard("req-q-1")!
    expect(entry.elementId).toBeUndefined()
    expect(entry.type).toBe("question")
  })

  it("onQuestionReplied → 对独立卡 updateMessageContent PATCH(answered) + deleteCard", async () => {
    const { interaction, wanling } = makeFixture({ aggregateCardEnabled: false })
    await interaction.onQuestionAsked(questionPayload)
    await interaction.onQuestionReplied({ sessionID: "sess-1", requestID: "req-q-1", answers: [["是"]] })
    expect(wanling.updateMessageContent).toHaveBeenCalledWith(
      "perm-msg-1",
      expect.objectContaining({
        msg_type: "question_card",
        data: expect.objectContaining({ status: "answered", result: "是", oc_request_id: "req-q-1" }),
      }),
    )
    expect(getCard("req-q-1")).toBeNull()
  })

  it("开关默认开启(不传 aggregateCardEnabled → 聚合路径)", async () => {
    const { interaction, router, wanling } = makeFixture({ aggregateCardEnabled: undefined })
    await interaction.onQuestionAsked(questionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    expect(router.sendCard).not.toHaveBeenCalled()
  })
})

describe("InteractionCards 聚合模式 — cleanupOrphans(孤儿元素更新 expired)", () => {
  beforeEach(() => {
    for (const id of Object.keys(getAllCards())) deleteCard(id)
  })

  it("聚合条目 → 更新聚合卡内元素 status=expired + deleteCard", async () => {
    const { interaction, wanling } = makeFixture()
    await interaction.onQuestionAsked(questionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    // 伪造超过 10min 的 createdAt 触发孤儿清理
    const entry = getCard("req-q-1")!
    entry.createdAt = Date.now() - 11 * 60 * 1000

    await interaction.cleanupOrphans()
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    })
    const [, body, opts] = lastPatch(wanling)
    expect(body.elements[0].data.status).toBe("expired")
    expect(opts).toBeUndefined()
    expect(getCard("req-q-1")).toBeNull()
  })

  it("聚合条目但 session 状态不可用 → 丢弃记账(不 PATCH 不泄漏)", async () => {
    const { interaction, store, wanling } = makeFixture()
    await interaction.onQuestionAsked(questionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    const entry = getCard("req-q-1")!
    entry.createdAt = Date.now() - 11 * 60 * 1000
    store.peekState.mockReturnValue(undefined)

    await interaction.cleanupOrphans()
    // 状态不可用:不追加 PATCH(全量替换会丢元素),仅丢弃本地记账
    expect(wanling.patchAggregateMessage.mock.calls.length).toBe(1)
    expect(wanling.updateMessageContent).not.toHaveBeenCalled()
    expect(getCard("req-q-1")).toBeNull()
  })

  it("非聚合条目 → 对独立卡 updateMessageContent PATCH expired + deleteCard", async () => {
    const { interaction, wanling } = makeFixture({ aggregateCardEnabled: false })
    await interaction.onQuestionAsked(questionPayload)
    const entry = getCard("req-q-1")!
    entry.createdAt = Date.now() - 11 * 60 * 1000

    await interaction.cleanupOrphans()
    expect(wanling.updateMessageContent).toHaveBeenCalledWith(
      "perm-msg-1",
      expect.objectContaining({
        msg_type: "question_card",
        data: expect.objectContaining({ status: "expired" }),
      }),
    )
    expect(getCard("req-q-1")).toBeNull()
  })
})
