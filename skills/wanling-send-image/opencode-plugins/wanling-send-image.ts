import { existsSync, readFileSync } from "fs"
import { basename, join } from "path"
import { type Plugin, tool } from "@opencode-ai/plugin"

// 万灵发图片 custom tool。
// 运行在 opencode serve 进程内，按 serve 自身 env 的 WANLING_CONFIG_DIR
// 精准定位所属套（dev=~/.config/opencode-wanling / prod=~/.config/opencode-wanling-prod），
// 不会串发到另一套 server。复用系统常量，不读任何 .env/.yml 凭证。
//
// 发送形态（按优先级）：
// 1. 进聚合卡：sync 进程（opencode-plugin）control API 通道，把图片 markdown 元素
//    追加进主会话活跃聚合卡（卡定位由 sync 进程持有，子 session 执行也能进对卡）。
//    control.json 不存在/请求失败/无活跃卡 → 退回形态 2。
// 2. 独立图片消息：REST 发 msg_type=image（按 sessionID 反查 session-maps.json）。

const MAX_SIZE = 20 * 1024 * 1024
const SAFE_EXTS = new Set([".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"])

function cfgDir(): string {
  return (
    process.env.WANLING_CONFIG_DIR ||
    join(process.env.HOME || "", ".config", "opencode-wanling")
  )
}

function loadConfig(): { serverUrl: string; agentId: string; secretKey: string } {
  const raw = JSON.parse(readFileSync(join(cfgDir(), "config.json"), "utf-8"))
  const serverUrl = raw.serverUrl || "http://localhost:18008"
  const agentId = raw.agentId || ""
  const secretKey = raw.secretKey || ""
  if (!agentId || !secretKey) {
    throw new Error(`config.json 缺少 agentId/secretKey (${cfgDir()})`)
  }
  return { serverUrl, agentId, secretKey }
}

function lookupConvBySession(sessionID: string): string {
  const f = join(cfgDir(), "session-maps.json")
  if (!existsSync(f)) return ""
  const maps = (JSON.parse(readFileSync(f, "utf-8")).maps || []) as Array<{
    opencodeSessionId?: string
    wanlingConvId?: string
  }>
  return maps.find((m) => m.opencodeSessionId === sessionID)?.wanlingConvId || ""
}

// control 发现信息（sync 进程启动落盘，0600）：tool → control API 进卡通道。
// 不可用（旧版 sync 进程未落盘/读失败）返回 null，调用方退回独立消息。
function loadControlEndpoint(): { port: number; token: string } | null {
  try {
    const raw = JSON.parse(readFileSync(join(cfgDir(), "control.json"), "utf-8")) as {
      port?: number
      token?: string
    }
    if (!raw.port || !raw.token) return null
    return { port: raw.port, token: raw.token }
  } catch {
    return null
  }
}

async function exchangeToken(
  serverUrl: string,
  agentId: string,
  secretKey: string,
): Promise<string> {
  const resp = await fetch(`${serverUrl}/api/agents/${agentId}/token`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ agent_id: agentId, secret_key: secretKey }),
  })
  const body = (await resp.json()) as { ok?: boolean; data?: { token?: string } }
  if (!body.ok || !body.data?.token) {
    throw new Error(`换 agent token 失败: HTTP ${resp.status}`)
  }
  return body.data.token
}

async function uploadFile(
  serverUrl: string,
  token: string,
  localPath: string,
): Promise<string> {
  const ext = localPath.toLowerCase().match(/\.\w+$/)?.[0] || ""
  if (!SAFE_EXTS.has(ext)) {
    throw new Error(`不支持的文件类型 ${ext}，仅支持: ${[...SAFE_EXTS].join(", ")}`)
  }
  const body = readFileSync(localPath)
  if (body.byteLength > MAX_SIZE) {
    throw new Error(`文件过大: ${body.byteLength} > ${MAX_SIZE}`)
  }
  const form = new FormData()
  form.append("file", new Blob([body]), basename(localPath))
  const resp = await fetch(`${serverUrl}/api/upload`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
    body: form,
  })
  const json = (await resp.json()) as { ok?: boolean; data?: { id?: string } }
  if (!json.ok || !json.data?.id) {
    throw new Error(`上传失败: HTTP ${resp.status}`)
  }
  return json.data.id
}

// 尝试把已上传图片追加进主会话活跃聚合卡（经 sync 进程 control API）。
// 返回 "appended"（已进卡）；"no_active_card"（无活跃聚合卡）；null（通道不可用）。
async function appendToAggregateCard(
  fileId: string,
  alt: string,
  sessionID: string,
): Promise<"appended" | "no_active_card" | null> {
  const endpoint = loadControlEndpoint()
  if (!endpoint) return null
  try {
    const resp = await fetch(`http://127.0.0.1:${endpoint.port}/aggregate/append-image`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${endpoint.token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ file_id: fileId, alt, session_id: sessionID }),
      // control 是本机 sync 进程,不正常挂起;超时按通道不可用退回独立消息
      signal: AbortSignal.timeout(5000),
    })
    if (!resp.ok) return null
    const json = (await resp.json()) as {
      ok?: boolean
      data?: { result?: "appended" | "no_active_card" }
    }
    if (!json.ok || !json.data?.result) return null
    return json.data.result
  } catch {
    return null
  }
}

async function sendImageMessage(
  serverUrl: string,
  token: string,
  convId: string,
  fileId: string,
): Promise<string> {
  const resp = await fetch(`${serverUrl}/api/conversations/${convId}/messages`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      content: { msg_type: "image", data: { file_id: fileId } },
    }),
  })
  const json = (await resp.json()) as { ok?: boolean; data?: { message_id?: string } }
  if (!json.ok || !json.data?.message_id) {
    throw new Error(`发送图片消息失败: HTTP ${resp.status}`)
  }
  return json.data.message_id
}

export const WanlingSendImage: Plugin = async () => ({
  tool: {
    wanling_send_image: tool({
      description:
        "上传本地图片到万灵并发送到当前会话（可点击放大）。" +
        "Agent 回合进行中优先作为图片元素插入聚合卡内（不打断实时内容流）；" +
        "无活跃聚合卡时作为独立图片消息发送。" +
        "当用户要求「发图片、发张图、发截图、在对话里显示图片」时使用。参数 path 为本地图片绝对路径。",
      args: {
        path: tool.schema
          .string()
          .describe("本地图片文件的绝对路径（jpg/png/gif/webp/bmp）"),
        alt: tool.schema
          .string()
          .optional()
          .describe("图片说明文字（可选，展示在图片加载前与画廊标题）"),
      },
      async execute(args, context) {
        const { sessionID } = context
        const cfg = loadConfig()
        const token = await exchangeToken(cfg.serverUrl, cfg.agentId, cfg.secretKey)
        const fileId = await uploadFile(cfg.serverUrl, token, args.path)

        // 优先:进主会话活跃聚合卡(不需要 convId,卡定位由 sync 进程完成,
        // 子 session 执行也能进对卡——现状 session-maps 反查在子 session 会落空)。
        const cardResult = await appendToAggregateCard(fileId, args.alt ?? "", sessionID)
        if (cardResult === "appended") {
          return `图片已插入当前聚合卡（file_id=${fileId}）。已直接出现在会话里，回复文字说明即可，不要再粘贴 markdown 引用。`
        }

        // 退回:无活跃卡/通道不可用 → 独立图片消息(需要 convId)
        const convId = lookupConvBySession(sessionID)
        if (!convId) {
          throw new Error(
            `图片已上传（file_id=${fileId}），但无活跃聚合卡且 session ${sessionID} 未映射到万灵会话（session-maps.json 无记录），无法发送。可在回复中引用: ![image](/api/files/${fileId})`,
          )
        }
        const messageId = await sendImageMessage(cfg.serverUrl, token, convId, fileId)
        return `已发送独立图片消息到当前会话（file_id=${fileId}, message_id=${messageId}）。图片已直接出现在会话里，回复文字说明即可，不要再粘贴 markdown 引用。`
      },
    }),
  },
})
