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

// InteractionCards 迁移 SDK 后单测:mock store/router/wanling/opencode,直接断言
// 双轨行为:
// - question(聚合模式)→ wanling.approvals.ask(SDK Approvals):options 映射/决议回填/
//   TUI 先答回声去重(pendingQuestions 登记表)
// - permission → 保留自管(聚合模式嵌入聚合卡元素 + card_store 记账)
// - 反向流(TUI 答 → 更新聚合卡内元素 status + silent 状态机)
// - 开关 false 时完全回退旧逻辑(sendCard 独立卡 + updateMessageContent PATCH)。
// 动态 import(config.js mock 生效后)保证 card_store 写到隔离 TMP,不污染真实配置目录。
const { InteractionCards } = await import("./interaction.js")
const { permissionCardElement } = await import("./aggregate_bridge.js")
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
})

describe("InteractionCards 聚合模式 — question 走 SDK approvals.ask", () => {
  beforeEach(() => {
    for (const id of Object.keys(getAllCards())) deleteCard(id)
  })

  it("onQuestionAsked → approvals.ask(单问题:options=label 映射,title=header),不 append 元素不 saveCard", async () => {
    const { interaction, router, wanling, toolCard } = makeFixture()
    const askP = new Promise(() => {}) // 挂起不决议(测发卡参数)
    wanling.approvals.ask.mockReturnValue(askP)
    const p = interaction.onQuestionAsked(questionPayload)
    await vi.waitFor(() => {
      expect(wanling.approvals.ask).toHaveBeenCalled()
    })
    expect(wanling.approvals.ask).toHaveBeenCalledWith("conv-1", {
      cardType: "question",
      title: "确认",
      options: [{ id: "是", label: "是" }],
      multiSelect: false,
      sessionKey: "req-q-1",
    })
    // 不再嵌入聚合卡元素 / 不发独立卡 / card_store 无记账
    expect(wanling.patchAggregateMessage).not.toHaveBeenCalled()
    expect(router.sendCard).not.toHaveBeenCalled()
    expect(getCard("req-q-1")).toBeNull()
    // 发卡即返回,flushPending 不等决议(工具卡不被答题阻塞)
    expect(toolCard.flushPending).toHaveBeenCalled()
    void p
  })

  it("多问题拍平:option id 带 header 前缀防撞,description 拼进 label", async () => {
    const { interaction, wanling } = makeFixture()
    const multiPayload = {
      ...questionPayload,
      questions: [
        { question: "选语言?", header: "语言", options: [{ label: "Go", description: "快" }, { label: "TS" }] },
        { question: "确认?", header: "确认", options: [{ label: "Go", description: "" }], multiple: true },
      ],
    }
    wanling.approvals.ask.mockReturnValue(new Promise(() => {}))
    const p = interaction.onQuestionAsked(multiPayload)
    await vi.waitFor(() => {
      expect(wanling.approvals.ask).toHaveBeenCalled()
    })
    expect(wanling.approvals.ask).toHaveBeenCalledWith("conv-1", {
      cardType: "question",
      title: "Agent 提问(2 个问题)",
      options: [
        { id: "Go", label: "Go — 快" },
        { id: "TS", label: "TS" },
        { id: "确认:Go", label: "Go" },
      ],
      multiSelect: true,
      sessionKey: "req-q-1",
    })
    void p
  })

  it("多条单选问题拍平 → multiSelect=true(server 单选限答 1 项,放开多选保全部问题可答)", async () => {
    const { interaction, wanling } = makeFixture()
    const twoSinglePayload = {
      ...questionPayload,
      questions: [
        { question: "选语言?", header: "语言", options: [{ label: "Go" }] },
        { question: "确认?", header: "确认", options: [{ label: "好" }] },
      ],
    }
    wanling.approvals.ask.mockReturnValue(new Promise(() => {}))
    const p = interaction.onQuestionAsked(twoSinglePayload)
    await vi.waitFor(() => {
      expect(wanling.approvals.ask).toHaveBeenCalled()
    })
    expect(wanling.approvals.ask.mock.calls[0][1].multiSelect).toBe(true)
    void p
  })

  it("同题同名 label → option id 追加序号去重不撞车(防 server 400 丢问题)", async () => {
    const { interaction, wanling } = makeFixture()
    const dupPayload = {
      ...questionPayload,
      questions: [
        { question: "选?", header: "选", options: [{ label: "同" }, { label: "同" }, { label: "同" }] },
      ],
    }
    wanling.approvals.ask.mockReturnValue(new Promise(() => {}))
    const p = interaction.onQuestionAsked(dupPayload)
    await vi.waitFor(() => {
      expect(wanling.approvals.ask).toHaveBeenCalled()
    })
    const ids = wanling.approvals.ask.mock.calls[0][1].options.map((o: { id: string }) => o.id)
    expect(ids).toEqual(["同", "同_2", "同_3"])
    void p
  })

  it("ask 决议 approved → answers 按问题归属分组回填 replyQuestion", async () => {
    const { interaction, wanling, opencode } = makeFixture()
    let resolveAsk!: (r: unknown) => void
    wanling.approvals.ask.mockReturnValue(new Promise((r) => { resolveAsk = r }))
    const p = interaction.onQuestionAsked(questionPayload)
    resolveAsk({ state: "approved", answers: ["是"] })
    await p
    expect(opencode.replyQuestion).toHaveBeenCalledWith("req-q-1", [["是"]], "/tmp")
  })

  it("多问题决议 approved → answers 按 qIdx 分组,未答问题给空数组", async () => {
    const { interaction, wanling, opencode } = makeFixture()
    const multiPayload = {
      ...questionPayload,
      questions: [
        { question: "选语言?", header: "语言", options: [{ label: "Go" }, { label: "TS" }] },
        { question: "确认?", header: "确认", options: [{ label: "好" }] },
      ],
    }
    let resolveAsk!: (r: unknown) => void
    wanling.approvals.ask.mockReturnValue(new Promise((r) => { resolveAsk = r }))
    const p = interaction.onQuestionAsked(multiPayload)
    // 只答了第一问的 Go
    resolveAsk({ state: "approved", answers: ["Go"] })
    await p
    expect(opencode.replyQuestion).toHaveBeenCalledWith("req-q-1", [["Go"], []], "/tmp")
  })

  it("ask 决议 denied → rejectQuestion", async () => {
    const { interaction, wanling, opencode } = makeFixture()
    let resolveAsk!: (r: unknown) => void
    wanling.approvals.ask.mockReturnValue(new Promise((r) => { resolveAsk = r }))
    const p = interaction.onQuestionAsked(questionPayload)
    resolveAsk({ state: "denied" })
    await p
    expect(opencode.rejectQuestion).toHaveBeenCalledWith("req-q-1", "/tmp")
    expect(opencode.replyQuestion).not.toHaveBeenCalled()
  })

  it("ask 决议 expired → rejectQuestion(OC 侧 404 类错误静默跳过)", async () => {
    const { interaction, wanling, opencode } = makeFixture()
    let resolveAsk!: (r: unknown) => void
    wanling.approvals.ask.mockReturnValue(new Promise((r) => { resolveAsk = r }))
    const p = interaction.onQuestionAsked(questionPayload)
    opencode.rejectQuestion.mockRejectedValueOnce(new Error("question no longer exists"))
    resolveAsk({ state: "expired" })
    await expect(p).resolves.toBeUndefined()
    expect(opencode.rejectQuestion).toHaveBeenCalled()
  })

  it("回声去重:TUI 先答(onQuestionReplied 置 settled)→ ask 决议后跳过回填", async () => {
    const { interaction, wanling, opencode } = makeFixture()
    let resolveAsk!: (r: unknown) => void
    wanling.approvals.ask.mockReturnValue(new Promise((r) => { resolveAsk = r }))
    const p = interaction.onQuestionAsked(questionPayload)
    await vi.waitFor(() => {
      expect(wanling.approvals.ask).toHaveBeenCalled()
    })
    // TUI 侧先答(回声路径):登记表命中置 settled
    await interaction.onQuestionReplied({ sessionID: "sess-1", requestID: "req-q-1", answers: [["是"]] })
    resolveAsk({ state: "approved", answers: ["是"] })
    await p
    // OC question 已被 TUI 解决,不再回填(防二次回复)
    expect(opencode.replyQuestion).not.toHaveBeenCalled()
    expect(opencode.rejectQuestion).not.toHaveBeenCalled()
  })

  it("回声去重:TUI 先拒(onQuestionRejected 置 settled)→ ask 决议后跳过回填", async () => {
    const { interaction, wanling, opencode } = makeFixture()
    let resolveAsk!: (r: unknown) => void
    wanling.approvals.ask.mockReturnValue(new Promise((r) => { resolveAsk = r }))
    const p = interaction.onQuestionAsked(questionPayload)
    await vi.waitFor(() => {
      expect(wanling.approvals.ask).toHaveBeenCalled()
    })
    await interaction.onQuestionRejected({ sessionID: "sess-1", requestID: "req-q-1" })
    resolveAsk({ state: "approved", answers: ["是"] })
    await p
    expect(opencode.replyQuestion).not.toHaveBeenCalled()
  })

  it("APP 先答的回声(我们自己 replyQuestion 触发):登记条目已随决议清理,自然跳过", async () => {
    const { interaction, wanling, opencode } = makeFixture()
    let resolveAsk!: (r: unknown) => void
    wanling.approvals.ask.mockReturnValue(new Promise((r) => { resolveAsk = r }))
    const p = interaction.onQuestionAsked(questionPayload)
    resolveAsk({ state: "approved", answers: ["是"] })
    await p
    expect(opencode.replyQuestion).toHaveBeenCalledTimes(1)
    // 决议后登记条目已删:OC 回答事件的回声找不到登记也找不到 card entry → 跳过
    await interaction.onQuestionReplied({ sessionID: "sess-1", requestID: "req-q-1", answers: [["是"]] })
    expect(opencode.replyQuestion).toHaveBeenCalledTimes(1)
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
    // 先挂两个 permission pending(question 聚合已走 SDK ask,不再入卡)
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
    expect(wanling.approvals.ask).not.toHaveBeenCalled()
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

  it("开关默认开启(不传 aggregateCardEnabled → question 走 ask 聚合路径)", async () => {
    const { interaction, router, wanling } = makeFixture({ aggregateCardEnabled: undefined })
    wanling.approvals.ask.mockReturnValue(new Promise(() => {}))
    const p = interaction.onQuestionAsked(questionPayload)
    await vi.waitFor(() => {
      expect(wanling.approvals.ask).toHaveBeenCalled()
    })
    expect(router.sendCard).not.toHaveBeenCalled()
    void p
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
