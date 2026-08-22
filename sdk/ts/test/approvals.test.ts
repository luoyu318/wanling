import { describe, expect, it, vi } from "vitest"
import { Approvals } from "../src/approvals.js"

function makeApprovals() {
  const handlers: Record<string, ((p: Record<string, unknown>) => void)[]> = {}
  const createBodies: Record<string, unknown>[] = []
  const approvals = new Approvals(
    async (_convId: string, body: Record<string, unknown>) => {
      createBodies.push(body)
      return { approval_id: "ap1", state: "pending" }
    },
    async () => { throw new Error("not called") },
    (name, cb) => { (handlers[name] ??= []).push(cb) },
  )
  return { approvals, createBodies, emit: (name: string, p: Record<string, unknown>) => handlers[name]?.forEach((cb) => cb(p)) }
}

describe("Approvals", () => {
  it("decided 事件决议 approved+answers", async () => {
    const { approvals, emit } = makeApprovals()
    const p = approvals.ask("c1", { cardType: "question", title: "t", sessionKey: "s", options: [{ id: "a", label: "A" }], multiSelect: true })
    // 等 createApproval mock resolve、pending 注册完成后再 emit（模拟真实时序：决策晚于建卡）
    await new Promise((r) => setTimeout(r, 0))
    emit("approval.decided", { approval_id: "ap1", decision: "answer", answers: ["a"], decided_by: "u1" })
    expect(await p).toEqual({ state: "approved", decision: "answer", answers: ["a"], decidedBy: "u1" })
  })

  it("expired 事件决议 expired", async () => {
    const { approvals, emit } = makeApprovals()
    const p = approvals.ask("c1", { cardType: "tool", title: "t", sessionKey: "s" })
    await new Promise((r) => setTimeout(r, 0))
    emit("approval.expired", { approval_id: "ap1" })
    expect(await p).toEqual({ state: "expired" })
  })

  it("ask 透传 preview_language/meta 到建卡 body", async () => {
    const { approvals, createBodies, emit } = makeApprovals()
    const p = approvals.ask("c1", {
      cardType: "command", title: "t", sessionKey: "s",
      preview: "rm -rf /tmp/x", previewLanguage: "shell",
      meta: [{ text: "dangerous command from hook", warn: true }],
    })
    await new Promise((r) => setTimeout(r, 0))
    expect(createBodies[0]).toMatchObject({
      card_type: "command",
      preview_language: "shell",
      meta: [{ text: "dangerous command from hook", warn: true }],
    })
    emit("approval.decided", { approval_id: "ap1", decision: "approve" })
    expect(await p).toEqual({ state: "approved", decision: "approve" })
  })

  it("auto_approved 命中白名单立即返回", async () => {
    const approvals = new Approvals(async () => ({ approval_id: "x", state: "approved", auto_approved: true }), async () => { throw new Error() }, () => {})
    expect(await approvals.ask("c1", { cardType: "command", title: "t", sessionKey: "s" }))
      .toEqual({ state: "approved", decision: "allow_always" })
  })

  it("超时兜底 expired", async () => {
    vi.useFakeTimers()
    const { approvals } = makeApprovals()
    const p = approvals.ask("c1", { cardType: "tool", title: "t", sessionKey: "s", timeoutSec: 1 })
    await vi.advanceTimersByTimeAsync(0) // flush microtask：等 pending 注册
    await vi.advanceTimersByTimeAsync(6500)
    expect(await p).toEqual({ state: "expired" })
    vi.useRealTimers()
  })
})
