import { randomUUID } from "crypto"
import { logger } from "../utils/logger.js"
import type { IncomingMessage, ServerResponse } from "http";
import { createServer } from "http"
import type { SyncEngine } from "../sync/engine.js"
import type { OpencodeBridge } from "../opencode/bridge.js"
import type { WanlingClient } from "../wanling/client.js"

interface ControlApiOptions {
  port: number
  wanling: WanlingClient
  opencode: OpencodeBridge
  sync: SyncEngine
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
