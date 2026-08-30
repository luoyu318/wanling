import { Agent, setGlobalDispatcher } from "undici"
import { logger } from "./utils/logger.js"
import { loadConfig, configDir } from "./config.js"
import { WanlingClient } from "./wanling/client.js"
import { OpencodeBridge } from "./opencode/bridge.js"
import { SyncEngine } from "./sync/engine.js"
import { startControlApi } from "./control/api.js"
import { startProxy } from "./proxy/http.js"
import { EventSubscriber } from "./opencode/subscriber.js"
import { Streamer } from "./sync/streamer.js"
import { createDefaultDispatcher } from "./rpc/register.js"
import { WanlingDownloader } from "./storage/downloader.js"
import { join } from "path"

// 全局 dispatcher:控制 undici 连接池行为,防止 opencode serve(Go HTTP server,
// 默认 IdleTimeout=0)不主动关 keep-alive 连接导致 ESTABLISHED 累积,
// 最终占满 Linux ephemeral 端口范围触发 EADDRNOTAVAIL。
// pipelining=0 + 极短 keepAliveTimeout 让空闲连接立即释放。
// SSE 长连接走独立 stream,不受 keepAliveTimeout 影响。
setGlobalDispatcher(
  new Agent({
    pipelining: 0,
    keepAliveTimeout: 1000,
    keepAliveMaxTimeout: 1000,
  }),
)

async function main(): Promise<void> {
  const config = loadConfig()

  const opencode = new OpencodeBridge(config.opencodePort)
  await opencode.ensureServer()
  logger.info(`[wanling] connected to OpenCode (port ${config.opencodePort})`)

  // 解析主 session:首事件触发建群(agent_session)的判定基准。
  const existingMain = await opencode.getCurrentSession()
  const mainSessionId = existingMain ?? await opencode.createSession("万灵对话")
  if (!existingMain) {
    logger.info(`[wanling] created main session: ${mainSessionId.slice(0, 12)}…`)
  }

  const dispatcher = createDefaultDispatcher({
    getClient: () => opencode.getClientV2(),
  })
  const wanling = new WanlingClient({
    serverUrl: config.serverUrl,
    agentId: config.agentId,
    secretKey: config.secretKey,
    dispatcher,
  })
  logger.info(`[rpc] 已注册 methods: ${dispatcher.methods().join(", ")}`)

  wanling.on("connected", () => {
    logger.info("[wanling] connected to Wanling server")
  })

  wanling.on("disconnected", () => {
    logger.info("[wanling] disconnected from Wanling server")
  })

  wanling.on("reconnecting", ({ delay }: { delay: number }) => {
    logger.info(`[wanling] reconnecting in ${delay.toFixed(1)}s`)
  })

  wanling.on("fatal", (_code: string, msg: string) => {
    console.error(`[wanling] fatal: ${msg}`)
  })

  wanling.on("error", (err: Error) => {
    console.error(`[wanling] error: ${err.message}`)
  })

  await wanling.connect()

  let subscriber: EventSubscriber | undefined
  let streamer: Streamer | undefined

  wanling.on("connected", () => {
    // WS 重连时先停旧实例，await 真正退出再新建，避免 SSE fetch socket 泄漏
    // （旧实现只置 aborted 标志，进行中的 fetch 不被取消，长跑后 EADDRNOTAVAIL）
    ;(async () => {
      if (subscriber) await subscriber.stopAsync()
      streamer?.stop()

      const ocClient = opencode.getClient()
      if (!ocClient) return
      subscriber = new EventSubscriber(ocClient)
      streamer = new Streamer(subscriber, wanling, mainSessionId, {
        opencode,
        ownerUserId: config.ownerUserId,
      }, dispatcher, config.childTimeoutMs, config.aggregateCardEnabled, {
        hardTimeoutMs: config.childHardTimeoutMs,
        abortChild: (id) => opencode.abortSession(id),
      })
      subscriber.on("error", (err: unknown) => console.error("[subscriber] error:", err))
      streamer.on("error", (err: Error) => console.error("[streamer] error:", err.message))
      subscriber.start().catch((err) => console.error("[subscriber] failed:", err))
      streamer.start()
      logger.info("[wanling] streamer started")
    })().catch((err) => console.error("[wanling] connected handler failed:", err))
  })

  const cacheDir = join(configDir(), "cache", "wanling_files")
  const downloader = new WanlingDownloader({
    baseUrl: config.serverUrl,
    tokenProvider: () => wanling.getToken(),
    cacheDir,
    maxBytes: config.maxDownloadBytes,
  })

  const sync = new SyncEngine(wanling, opencode, config.defaultDirectory, downloader)
  sync.on("error", (err: Error) => {
    console.error("[sync] error:", err.message)
  })
  // engine(停止/分段)触发聚合卡收尾 → streamer 对主 session 卡 finishCard。
  // engine 与 streamer 是分离实例,经此事件解耦(index.ts 是装配点)。
  sync.on("aggregate_finish", (payload: { sessionId: string; reason: "stop" | "interrupt" }) => {
    void streamer?.finishCardForSession(payload.sessionId, payload.reason)
  })
  sync.start()

  const control = await startControlApi({
    port: config.controlPort,
    wanling,
    opencode,
    sync,
  })

  const proxy = await startProxy({
    listenPort: config.proxyPort,
    targetPort: config.opencodePort,
    wanling,
    onUserSession: (id) => streamer?.updateMainSessionId(id),
    password: config.proxyPassword,
  })

  logger.info(`[wanling] control API on 127.0.0.1:${config.controlPort}`)
  logger.info(`[wanling] proxy on 127.0.0.1:${proxy.port} → :${config.opencodePort}`)

  logger.info(`[wanling] main session: ${mainSessionId.slice(0, 12)}… (首事件触发建群)`)

  logger.info("[wanling] opencode-plugin ready")

  process.on("SIGINT", () => {
    logger.info("\n[wanling] shutting down...")
    proxy.close()
    control.close()
    streamer?.stop()
    subscriber?.stop()
    wanling.disconnect()
    opencode.shutdown()
    process.exit(0)
  })

  process.on("SIGTERM", () => {
    logger.info("\n[wanling] shutting down...")
    proxy.close()
    control.close()
    streamer?.stop()
    subscriber?.stop()
    wanling.disconnect()
    opencode.shutdown()
    process.exit(0)
  })
}

main().catch((err) => {
  console.error("[wanling] failed to start:", err)
  process.exit(1)
})
