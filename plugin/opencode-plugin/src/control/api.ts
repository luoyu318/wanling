import { randomUUID } from "crypto"
import { logger } from "../utils/logger.js"
import type { IncomingMessage, ServerResponse } from "http";
import { createServer } from "http"
import type { SyncEngine } from "../sync/engine.js"
import type { OpencodeBridge } from "../opencode/bridge.js"
import type { WanlingClient } from "../wanling/client.js"
import type { Streamer } from "../sync/streamer.js"

interface ControlApiOptions {
  port: number
  wanling: WanlingClient
  opencode: OpencodeBridge
  sync: SyncEngine
  // streamer 在 wanling connected 回调内惰性创建且 WS 重连时重建,
  // control API 与其生命周期解耦,经 getter 闭包取当前实例(可为 undefined)。
  getStreamer: () => Streamer | undefined
}

export async function startControlApi(
  opts: ControlApiOptions,
): Promise<{ close: () => void; port: number; token: string }> {
  const apiToken = randomUUID()
  logger.info(`[control] API token: ${apiToken}`)

  const server = createServer((req: IncomingMessage, res: ServerResponse) => {
    handleRequest(req, res, opts, apiToken).catch((err) => {
      writeJson(res, 500, { ok: false, error: String(err) })
    })
  })

  return new Promise((resolve) => {
    server.listen(opts.port, "127.0.0.1", () => {
      const addr = server.address()
      const port = addr && typeof addr === "object" ? addr.port : opts.port
      resolve({ close: () => server.close(), port, token: apiToken })
    })
  })
}

async function handleRequest(
  req: IncomingMessage,
  res: ServerResponse,
  opts: ControlApiOptions,
  apiToken: string,
): Promise<void> {
  if (!checkAuth(req, apiToken)) {
    writeJson(res, 403, { ok: false, error: { code: "forbidden", message: "invalid token" } })
    return
  }
  const url = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`)
  const method = req.method || "GET"

  if (url.pathname === "/status" && method === "GET") {
    const status = opts.sync.getStatus()
    writeJson(res, 200, { ok: true, data: status })
    return
  }

  if (url.pathname === "/sync" && method === "POST") {
    const body = await readBody(req)
    const wanlingConvId = String(body?.wanlingConvId ?? url.searchParams.get("conv_id") ?? "")
    if (!wanlingConvId) {
      writeJson(res, 400, { ok: false, error: "missing wanlingConvId" })
      return
    }
    let sessionId = String(body?.sessionId ?? url.searchParams.get("session_id") ?? "")
    if (!sessionId) {
      sessionId = (await opts.opencode.getCurrentSession()) || ""
    }
    if (!sessionId) {
      writeJson(res, 400, { ok: false, error: "no active session" })
      return
    }
    try {
      await opts.sync.syncCliToApp(wanlingConvId, sessionId)
      writeJson(res, 200, { ok: true, data: { wanlingConvId, sessionId } })
    } catch (err) {
      writeJson(res, 409, { ok: false, error: String(err) })
    }
    return
  }

  if (url.pathname === "/aggregate/append-image" && method === "POST") {
    const body = await readBody(req)
    const fileId = String(body?.file_id ?? "")
    if (!fileId) {
      writeJson(res, 400, { ok: false, error: "missing file_id" })
      return
    }
    const streamer = opts.getStreamer()
    if (!streamer) {
      // streamer 未就绪(启动中/断线重连窗口):等同无活跃卡,调用方退回独立消息。
      writeJson(res, 200, { ok: true, data: { result: "no_active_card" } })
      return
    }
    // body.session_id 仅日志参考(tool 执行上下文的 session,可能是子 session),
    // 卡定位固定由 streamer 用主 session 完成。
    const alt = typeof body?.alt === "string" ? body.alt : undefined
    logger.info(`[control] append-image: file=${fileId.slice(0, 8)}… session=${String(body?.session_id ?? "-").slice(0, 12)}`)
    try {
      const result = await streamer.appendImageToCard(fileId, alt)
      writeJson(res, 200, { ok: true, data: { result } })
    } catch (err) {
      writeJson(res, 500, { ok: false, error: String(err) })
    }
    return
  }

  if (url.pathname === "/shutdown" && method === "POST") {
    writeJson(res, 200, { ok: true, data: { message: "shutting down" } })
    setImmediate(() => process.exit(0))
    return
  }

  writeJson(res, 404, { ok: false, error: "not found" })
}

function checkAuth(req: IncomingMessage, apiToken: string): boolean {
  const auth = req.headers["authorization"]
  if (!auth || !auth.startsWith("Bearer ")) return false
  return auth.slice(7) === apiToken
}

function writeJson(
  res: ServerResponse,
  status: number,
  data: unknown,
): void {
  res.writeHead(status, { "Content-Type": "application/json" })
  res.end(JSON.stringify(data))
}

function readBody(req: IncomingMessage): Promise<Record<string, unknown>> {
  return new Promise((resolve) => {
    const chunks: Buffer[] = []
    req.on("data", (c: Buffer) => chunks.push(c))
    req.on("end", () => {
      try {
        resolve(JSON.parse(Buffer.concat(chunks).toString()))
      } catch {
        resolve({})
      }
    })
  })
}
