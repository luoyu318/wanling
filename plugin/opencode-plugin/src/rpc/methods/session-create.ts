import { RPCError } from "../types.js"
import { getSessionMap, upsertSessionMap } from "../../sync/mapper.js"
import type { RPCContext } from "../utils.js"

type SessionCreateResult = {
  opencode_session_id: string
}

export const sessionCreateHandler = async (
  params: unknown,
  ctx: RPCContext,
): Promise<SessionCreateResult> => {
  const p = params as { wanling_conv_id: string; title?: string; directory?: string } | undefined

  if (!p?.wanling_conv_id) {
    throw new RPCError(-32602, "wanling_conv_id required")
  }

  const existing = getSessionMap(p.wanling_conv_id)
  if (existing) {
    return { opencode_session_id: existing.opencodeSessionId }
  }

  const client = ctx.getClient()
  if (!client) {
    throw new RPCError(-32603, "opencode client unavailable")
  }

  const resp = await client.session.create({
    title: p.title || "万灵对话",
    ...(p.directory ? { directory: p.directory } : {}),
  })
  const session = resp.data as { id: string }

  upsertSessionMap({
    wanlingConvId: p.wanling_conv_id,
    opencodeSessionId: session.id,
    lastSyncAt: new Date().toISOString(),
    messageCount: 0,
  })

  return { opencode_session_id: session.id }
}
