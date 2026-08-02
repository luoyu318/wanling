import type { WanlingClient } from "../wanling/client.js"
import type { OpencodeBridge } from "../opencode/bridge.js"
import { upsertSessionMap, findBySessionId, drainPendingTuiMessages } from "./mapper.js"

export interface EnsureDeps {
  wanling: WanlingClient
  opencode: OpencodeBridge
  ownerUserId: string
}

// in-flight Map:同一 session 首批并发事件只建一个群
const inflight = new Map<string, Promise<string>>()

/**
 * 为主 session 建 agent_session 群(已建则直接返)。in-flight 防并发。
 * title 策略:先用 sessionId 前缀立即建群,异步拿到可读名后改名(不阻塞首事件)。
 *
 * directory 同步:建群前同步调 session.get 拉 OC session.directory,
 * 透传给 server conversations.directory 一级列(APP 创建会话场景下走 APP 路径,
 * TUI 创建 session 场景下走 plugin 此路径)。失败降级为空串(NULL 入库),
 * RPC 方法后续可按需调 bridge.getSessionDirectory 按需拉取。
 */
export async function ensureConversation(
  sessionId: string,
  deps: EnsureDeps,
): Promise<string> {
  const existing = findBySessionId(sessionId)
  if (existing) return existing.wanlingConvId

  let p = inflight.get(sessionId)
  if (!p) {
    p = doCreate(sessionId, deps).finally(() => inflight.delete(sessionId))
    inflight.set(sessionId, p)
  }
  return p
}

async function doCreate(sessionId: string, deps: EnsureDeps): Promise<string> {
  const initialTitle = sessionId.slice(0, 12)
  // 同步拉 OC session.directory 透传给 server(TUI 新建 session 场景必走此路径)。
  // 拉失败降级为空串(NULL),不阻断建群。
  const directory = await deps.opencode.getSessionDirectory(sessionId)
  const convId = await deps.wanling.createGroupAsAgent(
    "agent_session",
    initialTitle,
    { userId: deps.ownerUserId, directory: directory || undefined },
  )
  upsertSessionMap({
    wanlingConvId: convId,
    opencodeSessionId: sessionId,
    lastSyncAt: new Date().toISOString(),
    messageCount: 0,
  })
  // drain proxy race 期间暂存的 tui_user 消息并补发:
  // proxy 拦截 prompt 早于建群完成,findBySessionId 落空的消息入队待发,
  // 此处建群成功(convId 已知)后补发,避免新 session 首条消息丢失。
  for (const text of drainPendingTuiMessages(sessionId)) {
    deps.wanling.sendTypedMessage(convId, "tui_user", { text }, { silent: true })
  }
  // 异步改名(失败不阻断,initial title 已可用)
  void deps.opencode.getSessionTitle(sessionId).then((title) => {
    if (title && title !== initialTitle) {
      deps.wanling.updateConversationTitle(convId, title).catch(() => {})
    }
  }).catch(() => {
    // getSessionTitle 失败不影响主流程（标题只是锦上添花）
  })
  return convId
}

/**
 * 清空 in-flight Map（测试专用，避免跨用例污染）。
 * @internal 不属于公开 API，仅用于测试环境重置状态。
 */
export function _resetInflight(): void {
  inflight.clear()
}
