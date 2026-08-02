import type { OpencodeClient as OpencodeClientV2 } from "@opencode-ai/sdk/v2"

export type RPCContext = {
  getClient: () => OpencodeClientV2 | null
}

export async function fetchSessionDirectory(
  getClient: () => OpencodeClientV2 | null,
  opencodeSessionId: string,
): Promise<string> {
  const client = getClient()
  if (!client) return ""
  try {
    const sess = await client.session.get({ sessionID: opencodeSessionId })
    return sess.data?.directory ?? ""
  } catch {
    return ""
  }
}
