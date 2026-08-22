import type { AskOptions, AskResult } from "./types.js"

interface PendingAsk {
  resolve: (r: AskResult) => void
  timer: ReturnType<typeof setTimeout>
}

/**
 * 审批/提问高层封装：createApproval REST 建卡 → 监听 APPROVAL_DECIDED/EXPIRED
 * （按 approval_id 匹配）→ Promise 决议。超时本地兜底（防事件丢失），
 * 断线重连后主动 GET 兜底一次。
 */
export class Approvals {
  private readonly pending = new Map<string, PendingAsk>()

  constructor(
    private readonly create: (convId: string, body: Record<string, unknown>) => Promise<{ approval_id?: string; state?: string; auto_approved?: boolean }>,
    private readonly fetchApproval: (id: string) => Promise<{ state?: string; decided_action?: string; decided_answers?: string[] }>,
    private readonly onEvent: (name: "approval.decided" | "approval.expired", cb: (payload: Record<string, unknown>) => void) => void,
    private readonly log: (msg: string) => void = () => {},
  ) {
    onEvent("approval.decided", (p) => this.settle(String(p.approval_id ?? ""), {
      state: (p.decision === "deny" || p.decision === "reject" || p.decision === "cancel") ? "denied" : "approved",
      decision: String(p.decision ?? ""),
      answers: Array.isArray(p.answers) ? (p.answers as string[]) : undefined,
      decidedBy: p.decided_by !== undefined ? String(p.decided_by) : undefined,
      reason: p.reason !== undefined ? String(p.reason) : undefined,
    }))
    onEvent("approval.expired", (p) => this.settle(String(p.approval_id ?? ""), { state: "expired" }))
  }

  /** 发卡并等待决策。auto_approved 命中白名单时立即返回 approved。 */
  async ask(convId: string, opts: AskOptions): Promise<AskResult> {
    const created = await this.create(convId, {
      card_type: opts.cardType, title: opts.title,
      ...(opts.preview !== undefined && { preview: opts.preview }),
      ...(opts.toolName !== undefined && { tool_name: opts.toolName }),
      session_key: opts.sessionKey,
      ...(opts.options !== undefined && { options: opts.options }),
      ...(opts.multiSelect !== undefined && { multi_select: opts.multiSelect }),
      ...(opts.allowPattern !== undefined && { allow_pattern: opts.allowPattern }),
      ...(opts.confirmId !== undefined && { confirm_id: opts.confirmId }),
      ...(opts.timeoutSec !== undefined && { timeout_sec: opts.timeoutSec }),
    })
    if (created.auto_approved === true || created.state === "approved") {
      return { state: "approved", decision: "allow_always" }
    }
    const approvalId = created.approval_id ?? ""
    if (approvalId === "") throw new Error("createApproval 未返回 approval_id")

    const timeoutMs = (opts.timeoutSec ?? 300) * 1000 + 5000 // server 超时 + 5s 事件余量
    return new Promise<AskResult>((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(approvalId)
        this.log(`ask 超时兜底 approval=${approvalId}`)
        resolve({ state: "expired" })
      }, timeoutMs)
      this.pending.set(approvalId, { resolve, timer })
    })
  }

  /** 断线重连后调用：对未决项逐个 REST 兜底查询。 */
  async resync(): Promise<void> {
    for (const [id, p] of this.pending) {
      try {
        const a = await this.fetchApproval(id)
        if (a.state !== undefined && a.state !== "pending") {
          clearTimeout(p.timer)
          this.pending.delete(id)
          p.resolve(a.state === "expired" ? { state: "expired" } : {
            state: a.state === "denied" ? "denied" : "approved",
            decision: a.decided_action ?? "", answers: a.decided_answers,
          })
        }
      } catch { /* 下轮再试 */ }
    }
  }

  private settle(approvalId: string, result: AskResult): void {
    const p = this.pending.get(approvalId)
    if (p === undefined) return
    clearTimeout(p.timer)
    this.pending.delete(approvalId)
    p.resolve(result)
  }
}
