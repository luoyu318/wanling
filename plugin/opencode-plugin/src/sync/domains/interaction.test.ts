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

// InteractionCards 单测(question/permission 统一自管双轨):mock store/router/wanling/
// opencode,直接断言:
// - 聚合模式(主 session)→ 嵌入聚合卡元素(append op + silent 翻转响铃) + card_store 记账
// - 反向流(TUI 答 → 更新聚合卡内元素 status + silent 状态机)
// - 开关 false / 子 session 时回退独立卡(sendCard + updateMessageContent PATCH)。
// 动态 import(config.js mock 生效后)保证 card_store 写到隔离 TMP,不污染真实配置目录。
const { InteractionCards } = await import("./interaction.js")
const { permissionCardElement, questionCardElement } = await import("./aggregate_bridge.js")
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
    approvals: { ask: ReturnType<typeof vi.fn> }
  } = {
    sendCardMessage: vi.fn().mockResolvedValue("card-1"),
    patchAggregateMessage: vi.fn().mockResolvedValue(undefined),
    updateMessageContent: vi.fn().mockResolvedValue(undefined),
    approvals: { ask: vi.fn() },
  } as any
  const opencode = {
    replyQuestion: vi.fn(async () => ({})),
    rejectQuestion: vi.fn(async () => ({})),
  }
  const toolCard = { flushPending: vi.fn() }
  const interaction = new InteractionCards({
    store: store as any,
    router: router as any,
    wanling: wanling as any,
    opencode: opencode as any,
    toolCard: toolCard as any,
    emitter: new EventEmitter(),
    aggregateCardEnabled: opts.aggregateCardEnabled ?? true,
  })
  return { interaction, state, store, router, wanling, opencode, toolCard }
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
  source: { type: "tool", messageID: "m2", callID: "c2" },
}

describe("InteractionCards 聚合模式 — permission 正向流(pending 元素嵌入聚合卡 + silent 翻转响铃)", () => {
  beforeEach(() => {
    for (const id of Object.keys(getAllCards())) deleteCard(id)
  })

  it("onPermissionAsked → 聚合卡追加 permission 元素(append op) + 单独 set_silent:false 响铃,不再发独立卡", async () => {
    const { interaction, state, router, wanling, toolCard } = makeFixture()
    await interaction.onPermissionAsked(permissionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(1, "card-1", {
      op: "append",
      element: permissionCardElement({
        oc_request_id: "req-perm-1",
        action: "bash",
        resources: ["*.sh"],
        save: [],
        metadata: {},
        status: "pending",
      }, 1),
    })
    // pending 交互 → 单独 set_silent:false(需要用户介入 → 响铃)
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(2, "card-1", { op: "set_silent", silent: false })
    expect(wanling.patchAggregateMessage).toHaveBeenCalledTimes(2)
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

  it("元素序号与既有元素共用 state.aggregateSeq(全卡唯一递增)", async () => {
    const { interaction, state, wanling } = makeFixture()
    state.aggregateSeq = 2
    await interaction.onPermissionAsked(permissionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    const appendCall = wanling.patchAggregateMessage.mock.calls.find(([, b]) => b.op === "append")
    expect(appendCall[1].element.element_id).toBe("permission_card_3")
    expect(state.aggregateSeq).toBe(3)
  })

  it("onQuestionAsked → 聚合卡追加 question 元素(append op) + set_silent:false 响铃 + card_store 存 element_id", async () => {
    const { interaction, router, wanling } = makeFixture()
    await interaction.onQuestionAsked(questionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(1, "card-1", {
      op: "append",
      element: questionCardElement({
        oc_request_id: "req-q-1",
        questions: questionPayload.questions,
        status: "pending",
      }, 1),
    })
    expect(wanling.patchAggregateMessage).toHaveBeenNthCalledWith(2, "card-1", { op: "set_silent", silent: false })
    expect(router.sendCard).not.toHaveBeenCalled()
    const entry = getCard("req-q-1")!
    expect(entry.msgId).toBe("card-1")
    expect(entry.elementId).toBe("question_card_1")
    expect(entry.sessionId).toBe("sess-1")
    expect(entry.type).toBe("question")
  })
})

describe("InteractionCards 聚合模式 — question 反向流(更新聚合卡内元素 status + silent 状态机)", () => {
  beforeEach(() => {
    for (const id of Object.keys(getAllCards())) deleteCard(id)
  })

  it("onQuestionReplied → 元素 status=answered(update op,data 合并全量) + 单独 set_silent:true + deleteCard", async () => {
    const { interaction, wanling } = makeFixture()
    await interaction.onQuestionAsked(questionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    await interaction.onQuestionReplied({ sessionID: "sess-1", requestID: "req-q-1", answers: [["是"]] })
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(4)
    })
    const ops = wanling.patchAggregateMessage.mock.calls.map(([, b]) => b)
    const update = ops[2]
    expect(update.op).toBe("update")
    expect(update.element_id).toBe("question_card_1")
    expect(update.data.status).toBe("answered")
    expect(update.data.result).toBe("是")
    // 合并保留 questions(update 整体替换 data,不能丢既有字段)
    expect(update.data.questions).toEqual(questionPayload.questions)
    expect(ops[3]).toEqual({ op: "set_silent", silent: true })
    expect(wanling.updateMessageContent).not.toHaveBeenCalled()
    expect(getCard("req-q-1")).toBeNull()
  })

  it("onQuestionRejected → 元素 status=rejected + set_silent:true + deleteCard", async () => {
    const { interaction, wanling } = makeFixture()
    await interaction.onQuestionAsked(questionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    await interaction.onQuestionRejected({ sessionID: "sess-1", requestID: "req-q-1" })
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(4)
    })
    const ops = wanling.patchAggregateMessage.mock.calls.map(([, b]) => b)
    expect(ops[2].op).toBe("update")
    expect(ops[2].data.status).toBe("rejected")
    expect(ops[3]).toEqual({ op: "set_silent", silent: true })
    expect(getCard("req-q-1")).toBeNull()
  })
})

describe("InteractionCards 聚合模式 — permission 反向流(更新聚合卡内元素 status + silent 状态机)", () => {
  beforeEach(() => {
    for (const id of Object.keys(getAllCards())) deleteCard(id)
  })

  it("onPermissionReplied(approve) → 元素 status=approved(update op,data 合并全量) + 单独 set_silent:true + deleteCard", async () => {
    const { interaction, wanling } = makeFixture()
    await interaction.onPermissionAsked(permissionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    await interaction.onPermissionReplied({ sessionID: "sess-1", requestID: "req-perm-1", reply: "once" })
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(4)
    })
    const ops = wanling.patchAggregateMessage.mock.calls.map(([, b]) => b)
    const update = ops[2]
    expect(update.op).toBe("update")
    expect(update.element_id).toBe("permission_card_1")
    expect(update.data.status).toBe("approved")
    expect(update.data.result).toBe("once")
    // 合并保留 action/resources/save/metadata(update 整体替换 data,不能丢既有字段)
    expect(update.data.action).toBe("bash")
    expect(update.data.resources).toEqual(["*.sh"])
    expect(ops[3]).toEqual({ op: "set_silent", silent: true })
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
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(4)
    })
    const ops = wanling.patchAggregateMessage.mock.calls.map(([, b]) => b)
    expect(ops[2].op).toBe("update")
    expect(ops[2].data.status).toBe("denied")
    expect(ops[2].data.result).toBe("reject")
  })

  it("仍有其他 pending 交互时不恢复 silent(整卡继续响铃)", async () => {
    const { interaction, wanling } = makeFixture()
    // 先挂两个 permission pending
    await interaction.onPermissionAsked(permissionPayload)
    await interaction.onPermissionAsked({ ...permissionPayload, id: "req-perm-2" })
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(4)
    })
    // 回答第一个,但第二个仍 pending → 不恢复 silent(只发 update,无 set_silent)
    await interaction.onPermissionReplied({ sessionID: "sess-1", requestID: "req-perm-1", reply: "once" })
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(5)
    })
    const [, body] = lastPatch(wanling)
    expect(body.op).toBe("update")
    expect(body.element_id).toBe("permission_card_1")
    expect(body.data.status).toBe("approved")
  })

  it("回合真实收尾(finalizeCard)后的迟到回答:零 wire 流量(不误碰已收尾卡),仍 deleteCard", async () => {
    const { interaction, state, wanling } = makeFixture()
    await interaction.onPermissionAsked(permissionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    // 真实收尾(footer + set_state done + set_silent false,bridge/SDK 双双 sealed,
    // sealRound 清归属映射):迟到回答经 bridge 守卫拦截,不 PATCH 已收尾卡。
    await state.aggregateCard!.finalizeCard({ reason: "stop", duration: 1 })
    const baseline = wanling.patchAggregateMessage.mock.calls.length
    await interaction.onPermissionReplied({ sessionID: "sess-1", requestID: "req-perm-1", reply: "once" })
    expect(wanling.patchAggregateMessage.mock.calls.length).toBe(baseline)
    expect(getCard("req-perm-1")).toBeNull()
  })

  it("session 状态不可用(peekState miss)时跳过元素更新但仍 deleteCard(回声兜底清理)", async () => {
    const { interaction, store, wanling } = makeFixture()
    await interaction.onPermissionAsked(permissionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    store.peekState.mockReturnValue(undefined)
    await interaction.onPermissionReplied({ sessionID: "sess-1", requestID: "req-perm-1", reply: "once" })
    // 不追加 PATCH(状态不可用无法定位元素),仍 deleteCard
    expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    expect(getCard("req-perm-1")).toBeNull()
  })

  it("跨轮防护:收尾后归属映射已清(真跨轮 element_id 复用)时不误更新新卡元素,仍 deleteCard", async () => {
    const { interaction, state, wanling } = makeFixture()
    await interaction.onPermissionAsked(permissionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    // 模拟回合收尾(sealRound 清空 bridge.elementCardIds,真跨轮映射必为空)
    state.aggregateCard!.elementCardIds.clear()
    await interaction.onPermissionReplied({ sessionID: "sess-1", requestID: "req-perm-1", reply: "once" })
    // 不追加 PATCH(不能拿旧 entry 的元素 id 误更新新卡),仍 deleteCard
    expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    expect(getCard("req-perm-1")).toBeNull()
  })

  it("回答后 set_silent 恢复打到元素归属卡(bridge 归属映射定位)", async () => {
    const { interaction, state, wanling } = makeFixture()
    await interaction.onPermissionAsked(permissionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    // 模拟分卡:当前卡已切 card-2,permission_card_1 留在旧卡 card-1
    // (SDK 侧 update 经自身归属映射打旧卡;bridge 的 set_silent 定位同理)
    const bridge = state.aggregateCard!
    bridge.elementCardIds.set("permission_card_1", "card-1")
    await interaction.onPermissionReplied({ sessionID: "sess-1", requestID: "req-perm-1", reply: "once" })
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(4)
    })
    const silentCall = wanling.patchAggregateMessage.mock.calls.find(([, b]) => b.op === "set_silent")
    // set_silent 打到归属卡 card-1
    expect(silentCall![0]).toBe("card-1")
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

  it("onQuestionAsked → sendCard 独立 question_card + saveCard 无 elementId(非聚合不走 ask)", async () => {
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

  it("开关默认开启(不传 aggregateCardEnabled → question 走聚合元素路径)", async () => {
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
    await interaction.onPermissionAsked(permissionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    // 伪造超过 10min 的 createdAt 触发孤儿清理
    const entry = getCard("req-perm-1")!
    entry.createdAt = Date.now() - 11 * 60 * 1000

    await interaction.cleanupOrphans()
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage.mock.calls.length).toBe(3)
    })
    const [, body] = lastPatch(wanling)
    expect(body.op).toBe("update")
    expect(body.data.status).toBe("expired")
    expect(getCard("req-perm-1")).toBeNull()
  })

  it("聚合条目但 session 状态不可用 → 丢弃记账(不 PATCH 不泄漏)", async () => {
    const { interaction, store, wanling } = makeFixture()
    await interaction.onPermissionAsked(permissionPayload)
    await vi.waitFor(() => {
      expect(wanling.patchAggregateMessage).toHaveBeenCalled()
    })
    const entry = getCard("req-perm-1")!
    entry.createdAt = Date.now() - 11 * 60 * 1000
    store.peekState.mockReturnValue(undefined)

    await interaction.cleanupOrphans()
    // 状态不可用:不追加 PATCH(无法定位元素),仅丢弃本地记账
    expect(wanling.patchAggregateMessage.mock.calls.length).toBe(2)
    expect(wanling.updateMessageContent).not.toHaveBeenCalled()
    expect(getCard("req-perm-1")).toBeNull()
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
