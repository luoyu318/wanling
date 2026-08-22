import { describe, expect, it } from "vitest"
import { AggregateCard } from "../src/aggregate_card.js"
import type { AggregatePatchOp } from "../src/rest.js"

// 录制的增量 PATCH(cardId + op),供断言 patch 序列
interface RecordedPatch {
  cardId: string
  op: AggregatePatchOp
}

function makeIo(opts?: { failPatch?: number }) {
  let cardSeq = 0
  const cards: Array<{ id: string; data: Record<string, unknown> }> = []
  const patches: RecordedPatch[] = []
  const updates: Array<{ cardId: string; content: Record<string, unknown> }> = []
  const recalled: string[] = []
  let patchCalls = 0
  const io = {
    sendCard: async (data: { msg_type: string; data: Record<string, unknown> }) => {
      const id = `m${++cardSeq}`
      cards.push({ id, data: data.data })
      return id
    },
    patch: async (cardId: string, op: AggregatePatchOp) => {
      patchCalls++
      if (patchCalls <= (opts?.failPatch ?? 0)) throw new Error("patch down")
      patches.push({ cardId, op })
      return {}
    },
    updateContent: async (cardId: string, content: Record<string, unknown>) => {
      updates.push({ cardId, content })
      return {}
    },
    recall: async (messageId: string) => {
      recalled.push(messageId)
    },
  }
  return { io, cards, patches, updates, recalled }
}

describe("AggregateCard", () => {
  it("append 同 element_id 自动改 update（无 upsert）", async () => {
    const { io, cards, patches } = makeIo()
    const card = new AggregateCard("c1", io)
    const r1 = await card.append("tool_card", { type: "tool_card", element_id: "t1", name: "bash" })
    const r2 = await card.append("tool_card", { type: "tool_card", element_id: "t1", name: "bash", status: "done" })
    expect(r1).toEqual({ id: "t1" })
    expect(r2).toEqual({ id: "t1" })
    // 建卡幂等:两次 append 只建一张卡
    expect(cards.length).toBe(1)
    // 第一次 append、第二次 update(server append 无 upsert,同 id 原位替换)
    expect(patches[0]?.op).toEqual({
      op: "append",
      element: { type: "tool_card", element_id: "t1", data: { name: "bash" } },
    })
    expect(patches[1]?.op).toEqual({
      op: "update",
      element_id: "t1",
      data: { name: "bash", status: "done" },
    })
  })

  it("20 元素自动分卡 + set_segment", async () => {
    const { io, cards, patches } = makeIo()
    const card = new AggregateCard("c1", io)
    const push = (i: number) => card.append("markdown", { type: "markdown", element_id: `md_${i}`, text: `t${i}` })
    for (let i = 1; i <= 20; i++) await push(i)
    // 满 20 不分卡,第 20 个仍在首卡
    expect(cards.length).toBe(1)
    await push(21)
    // 第 21 个触发分卡:首卡 seal(done + segment first),新卡建卡带 segment last
    expect(cards.length).toBe(2)
    const firstCardOps = patches.filter((p) => p.cardId === "m1").map((p) => p.op)
    expect(firstCardOps).toContainEqual({ op: "set_state", state: "done" })
    expect(firstCardOps).toContainEqual({ op: "set_segment", segment: "first" })
    expect(cards[1]?.data).toMatchObject({ segment: "last", state: "generating", elements: [] })
    expect(patches.at(-1)).toMatchObject({ cardId: "m2", op: { op: "append", element: { element_id: "md_21" } } })
    // 跨卡 update:旧卡元素(md_1)仍打到旧卡(归属映射命中)
    await card.update("md_1", { text: "edited" })
    expect(patches.at(-1)).toMatchObject({ cardId: "m1", op: { op: "update", element_id: "md_1", data: { text: "edited" } } })
    // 第二次分卡(第 41 个元素):第二张卡 seal 为 middle,第三张卡 last
    for (let i = 22; i <= 40; i++) await push(i)
    await push(41)
    expect(cards.length).toBe(3)
    const secondCardOps = patches.filter((p) => p.cardId === "m2").map((p) => p.op)
    expect(secondCardOps).toContainEqual({ op: "set_segment", segment: "middle" })
    expect(cards[2]?.data).toMatchObject({ segment: "last" })
  })

  it("PATCH 串行（前次失败不断链）", async () => {
    const { io, patches } = makeIo({ failPatch: 1 })
    const card = new AggregateCard("c1", io)
    await expect(card.append("markdown", { type: "markdown", text: "a" })).rejects.toThrow("patch down")
    // 队列吞掉前次失败:第二次 append 仍执行且成功
    await card.append("markdown", { type: "markdown", text: "b" })
    expect(patches.length).toBe(1)
    expect(patches[0]?.op).toMatchObject({ op: "append", element: { data: { text: "b" } } })
  })

  it("update 未就绪元素缓存后补发", async () => {
    const { io, patches } = makeIo()
    const card = new AggregateCard("c1", io)
    // update 先于 append 到达:元素不在卡上,不 PATCH(避免 server 400),缓存待补
    await card.update("tool_x", { status: "working" })
    expect(patches.length).toBe(0)
    await card.append("tool_card", { type: "tool_card", element_id: "tool_x", name: "x" })
    // append 落地后自动补发 update,且与元素初始 data 合并
    expect(patches.map((p) => p.op.op)).toEqual(["append", "update"])
    expect(patches[1]?.op).toEqual({ op: "update", element_id: "tool_x", data: { name: "x", status: "working" } })
  })

  it("finish 后迟到 update 不建孤儿卡（零 wire 流量）", async () => {
    const { io, cards, patches, updates } = makeIo()
    const card = new AggregateCard("c1", io)
    await card.append("tool_card", { type: "tool_card", element_id: "t1", name: "bash" })
    await card.finish({ durationMs: 100 })
    // 收尾后工具终态迟到:sealed,不建新卡(resetRound/孤儿 generating 卡)、
    // 不 PATCH 已收尾卡、不触发降级全量替换 —— 对齐 opencode pending 缓存语义
    const wire = { cards: cards.length, patches: patches.length, updates: updates.length }
    await card.update("t1", { status: "done", output: "ok" })
    expect(cards.length).toBe(wire.cards)
    expect(patches.length).toBe(wire.patches)
    expect(updates.length).toBe(wire.updates)
  })

  it("interrupt 后迟到 update 零 wire,新一轮 append 正常开新卡", async () => {
    const { io, cards, patches } = makeIo()
    const card = new AggregateCard("c1", io)
    await card.append("tool_card", { type: "tool_card", element_id: "t1", name: "bash" })
    await card.interrupt()
    const cardCount = cards.length
    const patchCount = patches.length
    // 用户停止后工具终态迟到:同 finish 语义,零 wire 流量
    await card.update("t1", { status: "done" })
    expect(cards.length).toBe(cardCount)
    expect(patches.length).toBe(patchCount)
    // 新一轮 append:resetRound 路径未被破坏,正常开新卡
    await card.append("markdown", { type: "markdown", element_id: "md_1", text: "next" })
    expect(cards.length).toBe(cardCount + 1)
    expect(cards.at(-1)?.data).toMatchObject({ state: "generating", elements: [] })
    // 新一轮 update 打到新卡(resetRound 已清迟到缓存,不跨轮泄漏)
    await card.update("md_1", { text: "edited" })
    expect(patches.at(-1)).toMatchObject({
      cardId: `m${cardCount + 1}`,
      op: { op: "update", element_id: "md_1", data: { text: "edited" } },
    })
  })

  it("连续 3 次失败降级全量替换自愈（append 改写幂等 update）", async () => {
    const { io, patches, updates } = makeIo({ failPatch: 3 })
    const card = new AggregateCard("c1", io)
    await expect(card.append("markdown", { type: "markdown", element_id: "m1", text: "a" })).rejects.toThrow("patch down")
    await expect(card.append("markdown", { type: "markdown", element_id: "m2", text: "b" })).rejects.toThrow("patch down")
    // 第三次连续失败触发降级:影子副本全量替换推 server 收敛,append 改写 update 重试成功
    const r3 = await card.append("markdown", { type: "markdown", element_id: "m3", text: "c" })
    expect(r3).toEqual({ id: "m3" })
    expect(updates.length).toBe(1)
    expect(updates[0]?.content).toMatchObject({
      msg_type: "aggregate_card",
      data: {
        state: "generating",
        elements: [
          { type: "markdown", element_id: "m1", data: { text: "a" } },
          { type: "markdown", element_id: "m2", data: { text: "b" } },
          { type: "markdown", element_id: "m3", data: { text: "c" } },
        ],
      },
    })
    // 自愈 envelope 不带 silent 键(server mergePreservedSilent 并入原值,防覆写已翻转的响铃)
    expect(updates[0]?.content).not.toHaveProperty("silent")
    // 重试的 op 是幂等 update(全量已含新元素,防重复 append)
    expect(patches.at(-1)?.op).toEqual({ op: "update", element_id: "m3", data: { text: "c" } })
  })

  it("finish 追加 footer+done+翻 silent,重复 finish 幂等", async () => {
    const { io, patches } = makeIo()
    const card = new AggregateCard("c1", io)
    await card.append("markdown", { type: "markdown", text: "hi" })
    await card.finish({ durationMs: 1200, model: "glm" })
    await card.finish({})
    const ops = patches.map((p) => p.op.op)
    expect(ops).toEqual(["append", "append", "set_state", "set_silent"])
    // durationMs 映射协议字段 duration;finished 由 finish 语义置 true
    expect(patches[1]?.op).toMatchObject({
      op: "append",
      element: { type: "footer", data: { duration: 1200, model: "glm", finished: true } },
    })
    expect(patches[2]?.op).toEqual({ op: "set_state", state: "done" })
    expect(patches[3]?.op).toEqual({ op: "set_silent", silent: false })
  })

  it("recallEmpty 空卡撤回（不发 footer/state）", async () => {
    const { io, patches, recalled } = makeIo()
    const card = new AggregateCard("c1", io, { recallEmpty: true })
    await card.finish({})
    expect(recalled).toEqual(["m1"])
    expect(patches.length).toBe(0)
  })
})
