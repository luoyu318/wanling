import type { IncomingMessage, ServerResponse } from "http";
import { createServer, request as httpRequest } from "http"
import type { WanlingClient } from "../wanling/client.js"
import { findBySessionId, enqueuePendingTuiMessage } from "../sync/mapper.js"

export interface ProxyOptions {
  listenPort: number
  targetPort: number
  targetHost?: string
  wanling: WanlingClient
  onUserSession?: (sessionId: string) => void
  password: string
}

export function startProxy(opts: ProxyOptions): Promise<{ close: () => void; port: number }> {
  const targetHost = opts.targetHost || "127.0.0.1"

  return new Promise((resolve) => {
    const server = createServer((clientReq, clientRes) => {
      handleRequest(clientReq, clientRes).catch((err) => {
        console.error("[proxy]", err.message)
        if (!clientRes.headersSent) {
          clientRes.writeHead(502)
          clientRes.end("proxy error")
        }
      })
    })

    server.listen(opts.listenPort, "127.0.0.1", () => {
      const addr = server.address()
      const port = addr && typeof addr === "object" ? addr.port : opts.listenPort
      console.log(`[proxy] listening on 127.0.0.1:${port} → :${opts.targetPort}`)
      resolve({ close: () => server.close(), port })
    })
  })

  async function handleRequest(clientReq: IncomingMessage, clientRes: ServerResponse) {
    if (!checkBasicAuth(clientReq, opts.password)) {
      clientRes.writeHead(401, { "WWW-Authenticate": 'Basic realm="wanling-proxy"' })
      clientRes.end("unauthorized")
      return
    }
    const url = new URL(clientReq.url || "/", `http://${clientReq.headers.host || "localhost"}`)
    // 宽松 path 匹配:任何 /session/:id/<verb> 的 POST 都尝试同步,
    // 由 trySyncPrompt 的 body 双重判定(parts 字段)决定是否真同步,
    // 避免 SDK 升级改 path 时 tui_user 同步静默失效。
    const sessionId = matchSessionPost(clientReq.method || "", url.pathname)

    // 双向关闭联动:任一方断开就标记 finished 并销毁到上游的 socket,
    // 防止 TUI 退出/SSE 长连接浮空累积到 EADDRNOTAVAIL。
    // 三处触发点:
    //   - clientRes close  → TUI 中途断开(主要泄漏源)
    //   - proxyRes end     → 上游正常结束(幂等 destroy)
    //   - proxyRes error   → 上游异常
    let proxyReq: ReturnType<typeof httpRequest> | null = null
    let finished = false
    const cleanup = () => {
      if (finished) return
      finished = true
      proxyReq?.destroy()
    }
    clientRes.on("close", cleanup)

    const reqChunks: Buffer[] = []
    clientReq.on("data", (c: Buffer) => reqChunks.push(c))
    clientReq.on("end", () => {
      const reqBody = Buffer.concat(reqChunks)

      // 加 connection:让 proxy 而非 TUI 决定 keep-alive 语义,避免对端透传误导
      const skipHeaders = ["host", "content-length", "transfer-encoding", "connection"]
      const headers: Record<string, string | string[]> = {}
      for (const [k, v] of Object.entries(clientReq.headers)) {
        if (!skipHeaders.includes(k) && v) headers[k] = v
      }
      headers["host"] = `127.0.0.1:${opts.targetPort}`
      headers["content-length"] = String(reqBody.length)

      if (sessionId) {
        const synced = trySyncPrompt(sessionId, reqBody, opts.wanling, opts.onUserSession)
        if (synced) console.log(`[proxy] → POST ${url.pathname}`)
      }

      proxyReq = httpRequest(
        { host: targetHost, port: opts.targetPort, path: url.pathname + url.search, method: clientReq.method, headers },
        (proxyRes) => {
          clientRes.writeHead(proxyRes.statusCode || 200, proxyRes.headers)
          proxyRes.pipe(clientRes)
          proxyRes.on("end", cleanup)
          proxyRes.on("error", cleanup)
        },
      )

      proxyReq.on("error", () => {
        if (!clientRes.headersSent) { clientRes.writeHead(502); clientRes.end("upstream unreachable") }
        cleanup()
      })

      proxyReq.end(reqBody)
    })
  }
}

// 宽松匹配 /session/:id/<verb>(含 /api/、/api/v2/ 等前缀),返回 sessionId 或 null。
// 实际是否同步由 trySyncPrompt 的 body 双重判定决定,这里只做 path 形状初筛。
const SESSION_POST_PATTERN = /^\/(?:api\/(?:v\d+\/)?)?session\/([^/]+)\/[^/]+/

export function matchSessionPost(method: string, path: string): string | null {
  if (method !== "POST") return null
  const m = path.match(SESSION_POST_PATTERN)
  return m ? m[1] : null
}

function lastUserText(parts: Array<{ type?: string; text?: string }>): string {
  const texts = (parts || [])
    .filter((p) => p.type === "text")
    .map((p) => p.text || "")
    .filter((t) => !t.startsWith("<system-reminder>"))
  return texts.length > 0 ? texts[texts.length - 1] : ""
}

// body 双重判定:JSON 含 parts 数组且能提取非空 user text 才视为 prompt 请求。
// onUserSession 仅在确认是 prompt 时触发(避免 abort 等非 prompt session POST 误切 mainSessionId)。
// 返回 true 表示已识别为 prompt 请求(无论是否成功同步到 wanling)。
export function trySyncPrompt(
  sessionId: string,
  reqBody: Buffer,
  wanling: WanlingClient,
  onUserSession?: (id: string) => void,
): boolean {
  let reqJson: Record<string, unknown>
  try {
    reqJson = JSON.parse(reqBody.toString("utf-8"))
  } catch {
    return false
  }

  const parts = reqJson.parts as Array<{ type?: string; text?: string }> | undefined
  if (!Array.isArray(parts)) return false

  const userText = lastUserText(parts)
  if (!userText.trim()) return false

  onUserSession?.(sessionId)

  const map = findBySessionId(sessionId)
  if (!map) {
    // session 群未建(ensureConversation 还在 flight):暂存待补发,
    // ensureConversation.doCreate 建群后 drain 队列补发,避免首条消息丢失。
    enqueuePendingTuiMessage(sessionId, userText)
    console.log(`[proxy] session 群未建,暂存 tui_user 待补发: ${sessionId.slice(0, 12)}…`)
    return true
  }

  wanling.sendTypedMessage(map.wanlingConvId, "tui_user", { text: userText }, { silent: true })
  console.log(`[proxy] synced user message (session: ${sessionId.slice(0, 12)}…)`)
  return true
}

function checkBasicAuth(req: IncomingMessage, expectedPassword: string): boolean {
  const auth = req.headers["authorization"]
  if (!auth || !auth.startsWith("Basic ")) return false
  try {
    const decoded = Buffer.from(auth.slice(6), "base64").toString("utf-8")
    const colonIdx = decoded.indexOf(":")
    if (colonIdx < 0) return false
    const password = decoded.slice(colonIdx + 1)
    return password === expectedPassword
  } catch {
    return false
  }
}
