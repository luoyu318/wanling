import { existsSync, readFileSync } from "fs"
import { join } from "path"
import { type Plugin, tool } from "@opencode-ai/plugin"

// 万灵发小程序卡片 custom tool。仅独立卡片消息(msg_type=mini_program_card):
// server 字符串透传 + APP renderer 全链路现成,无聚合卡通道。
// 运行在 opencode serve 进程内,按 serve 自身 env 的 WANLING_CONFIG_DIR
// 精准定位所属套(dev=~/.config/opencode-wanling / prod=~/.config/opencode-wanling-prod),
// 不会串发到另一套 server。title/icon 按 appid 查 GET /api/mini-programs 自取
// (server 端 List 已做 agent owner 换算,主人私有小程序可查)。

const APPID_RE = /^[a-z0-9][a-z0-9-]{2,31}$/

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

interface MPItem {
  appid?: string
  name?: string
  icon?: string
}

async function findMiniProgram(
  serverUrl: string,
  token: string,
  appid: string,
): Promise<MPItem> {
  const resp = await fetch(`${serverUrl}/api/mini-programs`, {
    headers: { Authorization: `Bearer ${token}` },
  })
  const json = (await resp.json()) as { ok?: boolean; data?: MPItem[] }
  const hit = json.data?.find((it) => it.appid === appid)
  // 不区分不存在/无权限(防泄露)
  if (!json.ok || !hit) {
    throw new Error(`未找到或不可见: ${appid}`)
  }
  return hit
}

async function sendCardMessage(
  serverUrl: string,
  token: string,
  convId: string,
  appid: string,
  title: string,
  icon: string,
  params?: unknown,
): Promise<string> {
  const data: Record<string, unknown> = { appid, title }
  if (icon) data.icon = icon
  if (params !== undefined) data.params = params
  const resp = await fetch(`${serverUrl}/api/conversations/${convId}/messages`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ content: { msg_type: "mini_program_card", data } }),
  })
  const json = (await resp.json()) as { ok?: boolean; data?: { message_id?: string } }
  if (!json.ok || !json.data?.message_id) {
    throw new Error(`发送小程序卡片失败: HTTP ${resp.status}`)
  }
  return json.data.message_id
}

export const WanlingSendMiniprogramCard: Plugin = async () => ({
  tool: {
    wanling_send_miniprogram_card: tool({
      description:
        "把万灵小程序以卡片消息发送到当前会话，用户点卡片直接打开小程序。" +
        "发布小程序后顺手发卡、或用户要求「发小程序卡片/把小程序发给我/发到会话」时使用。" +
        "appid 必填；卡片标题与图标自动按 appid 查询，无需提供。",
      args: {
        appid: tool.schema
          .string()
          .describe("小程序 appid（小写字母/数字/连字符，如 hello-demo）"),
        params: tool.schema
          .string()
          .optional()
          .describe("启动参数，JSON object 字符串（如 '{\"scene\":\"debug\"}'），透传给小程序入口"),
      },
      async execute(args, context) {
        if (!APPID_RE.test(args.appid)) {
          throw new Error(`appid 格式非法(小写字母/数字/连字符,3-32 位): ${args.appid}`)
        }
        // params 字符串 → JSON object,fail fast 校验(非 object 拒发)
        let params: unknown
        if (args.params !== undefined) {
          try {
            params = JSON.parse(args.params)
          } catch {
            throw new Error(`params 不是合法 JSON: ${args.params}`)
          }
          if (params === null || typeof params !== "object" || Array.isArray(params)) {
            throw new Error(`params 必须是 JSON object: ${args.params}`)
          }
        }

        const cfg = loadConfig()
        const token = await exchangeToken(cfg.serverUrl, cfg.agentId, cfg.secretKey)
        const mp = await findMiniProgram(cfg.serverUrl, token, args.appid)
        const title = mp.name || "小程序"
        const icon = mp.icon || ""

        const convId = lookupConvBySession(context.sessionID)
        if (!convId) {
          throw new Error(
            `session ${context.sessionID} 未映射到万灵会话(session-maps.json 无记录)，无法发卡。` +
              `可改用脚本: python3 <skill目录>/send_card.py ${args.appid} <conv_id>`,
          )
        }
        const messageId = await sendCardMessage(
          cfg.serverUrl, token, convId, args.appid, title, icon, params,
        )
        return (
          `已发送小程序卡片到当前会话（appid=${args.appid}, title=${title}, message_id=${messageId}）。` +
          `卡片已直接出现在会话里，回复文字说明即可，不要再粘贴链接或重复描述卡片内容。`
        )
      },
    }),
  },
})
