import type { PartUpdatedPayload } from "../../opencode/subscriber.js"

// 解析 tool part 的耗时(ms start/end → 秒,保留 1 位小数)。供 task/completed PATCH 的 duration 字段。
export function extractDuration(part: PartUpdatedPayload["part"]): number | null {
  const time = part.state?.time as { start?: number; end?: number } | undefined
  const start = time?.start
  const end = time?.end
  if (typeof start === "number" && typeof end === "number") {
    return Math.round((end - start) / 100) / 10
  }
  return null
}

// M12:从 part.state.metadata 提取 task 子 session 标识,带运行时校验。
// part.state 是 Record<string, unknown>,纯 as 断言在 metadata 形状异常时会让 sessionId 变 undefined,
// 导致 task 静默退化为普通 tool。此处 typeof 校验两字段为 string 后才返回,fail fast。
export function extractTaskMetadata(state: Record<string, unknown> | undefined): { sessionId?: string; parentSessionId?: string } {
  if (!state) return {}
  const raw = state.metadata
  if (!raw || typeof raw !== "object") return {}
  const m = raw as Record<string, unknown>
  const sessionId = typeof m.sessionId === "string" ? m.sessionId : undefined
  const parentSessionId = typeof m.parentSessionId === "string" ? m.parentSessionId : undefined
  const result: { sessionId?: string; parentSessionId?: string } = {}
  if (sessionId) result.sessionId = sessionId
  if (parentSessionId) result.parentSessionId = parentSessionId
  return result
}
