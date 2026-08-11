import { readFileSync, existsSync, writeFileSync, mkdirSync, chmodSync } from "fs"
import { logger } from "./utils/logger.js"
import { join } from "path"
import { homedir } from "os"
import { randomUUID } from "crypto"

export interface Config {
  serverUrl: string
  agentId: string
  secretKey: string
  ownerUserId: string
  allowedUsers: string[]
  allowAll: boolean
  opencodePort: number
  controlPort: number
  proxyPort: number
  childTimeoutMs: number
  defaultDirectory: string
  proxyPassword: string
  maxDownloadBytes: number
  aggregateCardEnabled: boolean
}

const DEFAULT_CONFIG_DIR = join(homedir(), ".config", "opencode-wanling")

// configDir 支持用 WANLING_CONFIG_DIR 环境变量重定向，用于多实例隔离
// (config.json / session-maps.json / pending-cards.json 都落在 configDir 下)。
// 默认值不变，单实例部署向后兼容。
export function configDir(): string {
  return process.env.WANLING_CONFIG_DIR || DEFAULT_CONFIG_DIR
}

// configPath 优先用 WANLING_CONFIG_FILE 单文件覆盖，否则取 configDir/config.json。
function configPath(): string {
  return process.env.WANLING_CONFIG_FILE || join(configDir(), "config.json")
}

function envStr(key: string, fallback: string): string {
  return process.env[key] || fallback
}

function envBool(key: string, fallback: boolean): boolean {
  const v = process.env[key]
  if (!v) return fallback
  return ["1", "true", "yes"].includes(v.toLowerCase())
}

function envArr(key: string, fallback: string[]): string[] {
  const v = process.env[key]
  if (!v) return fallback
  return v.split(",").map((s) => s.trim()).filter(Boolean)
}

export function loadConfig(): Config {
  const config: Config = {
    serverUrl: envStr("WANLING_SERVER_URL", "http://localhost:18008"),
    agentId: envStr("WANLING_AGENT_ID", ""),
    secretKey: envStr("WANLING_SECRET_KEY", ""),
    ownerUserId: envStr("WANLING_OWNER_USER_ID", ""),
    allowedUsers: envArr("WANLING_ALLOWED_USERS", []),
    allowAll: envBool("WANLING_ALLOW_ALL_USERS", true),
    opencodePort: Number(envStr("OPENCODE_PORT", "4096")),
    controlPort: Number(envStr("CONTROL_PORT", "19780")),
    proxyPort: Number(envStr("PROXY_PORT", "5096")),
    // I-O:子 session 兜底超时(task 崩溃/漏发终态时强制清理)。默认 30min,
    // 复杂 task 可能跑久,运维可经 WANLING_CHILD_TIMEOUT_MS(ms)调整不重编译。
    childTimeoutMs: Number(envStr("WANLING_CHILD_TIMEOUT_MS", "1800000")),
    defaultDirectory: envStr("WANLING_DEFAULT_DIRECTORY", ""),
    proxyPassword: envStr("WANLING_PROXY_PASSWORD", ""),
    maxDownloadBytes: Number(envStr("WANLING_MAX_DOWNLOAD_BYTES", String(20 * 1024 * 1024))),
    // 聚合卡开关(Task 3):reasoning/markdown/step_finish 转聚合卡元素。
    // 默认 true;false 时 plugin 回退旧逐条发送(独立消息)。
    aggregateCardEnabled: envBool("WANLING_AGGREGATE_CARD_ENABLED", true),
  }

  const file = configPath()
  const hasSecretKeyEnv = !!process.env.WANLING_SECRET_KEY
  if (existsSync(file)) {
    try {
      const raw = readFileSync(file, "utf-8")
      const fileCfg = JSON.parse(raw)
      Object.assign(config, fileCfg)
    } catch { /* .env 文件可不存在，跳过 */ }
  }

  // secretKey 来自文件而非环境变量:实际修复权限（旧版本可能创建为 644）+ 提醒改用环境变量
  if (config.secretKey && !hasSecretKeyEnv) {
    let secured = false
    try {
      chmodSync(file, 0o600)
      secured = true
    } catch {
      // 非 POSIX / 权限不足 → 不阻断,消息改为建议手动修复
    }
    console.warn(
      `[wanling] ⚠️  secretKey 来自 config.json` +
      (secured ? `，已设文件权限为 600。` : `，建议手动执行 chmod 600。`) +
      ` 更推荐用 WANLING_SECRET_KEY 环境变量（不落盘）。`,
    )
  }

  // 非 localhost 的 http:// URL 发出警告（凭证明文传输风险）
  if (
    config.serverUrl.startsWith("http://") &&
    !config.serverUrl.includes("localhost") &&
    !config.serverUrl.includes("127.0.0.1")
  ) {
    console.warn(
      `[wanling] ⚠️  serverUrl 使用明文 HTTP(${config.serverUrl})，` +
      "凭证将通过未加密通道传输。生产环境请配置 HTTPS。"
    )
  }

  if (!config.proxyPassword) {
    config.proxyPassword = randomUUID()
    try {
      // 定向写:只更新 proxyPassword 字段,不触碰其他字段(尤其不落盘 env 来源的 secretKey)
      const file = configPath()
      let fileJson: Record<string, unknown> = {}
      if (existsSync(file)) {
        try {
          fileJson = JSON.parse(readFileSync(file, "utf-8"))
        } catch { /* 文件损坏,用空对象兜底 */ }
      }
      fileJson.proxyPassword = config.proxyPassword
      mkdirSync(configDir(), { recursive: true })
      writeFileSync(file, JSON.stringify(fileJson, null, 2), "utf-8")
      try { chmodSync(file, 0o600) } catch { /* 非 POSIX */ }
      logger.info("[wanling] 生成 proxyPassword 并写入 config.json")
    } catch {
      console.warn("[wanling] ⚠️  proxyPassword 自动生成但写回 config.json 失败,本次启动用临时 token")
    }
  }

  return config
}

export function saveConfig(cfg: Config): void {
  mkdirSync(configDir(), { recursive: true })
  const file = configPath()
  writeFileSync(file, JSON.stringify(cfg, null, 2), "utf-8")
  // 限制文件权限为 owner-only（config.json 含 secretKey 等敏感字段）
  try {
    chmodSync(file, 0o600)
  } catch {
    // chmod 失败不阻断（非 POSIX 系统 / 权限不足）
  }
}
