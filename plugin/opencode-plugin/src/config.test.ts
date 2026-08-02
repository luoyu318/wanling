import { describe, it, expect, beforeEach, afterEach } from "vitest"
import { writeFileSync, readFileSync, mkdirSync, chmodSync, statSync, rmSync } from "fs"
import { join } from "path"
import { tmpdir } from "os"
import { loadConfig } from "./config.js"

// 用独立 tmp 目录隔离,避免污染真实 ~/.config/opencode-wanling/config.json
const TMP = join(tmpdir(), `wl-config-test-${process.pid}-${Date.now()}`)
const CFG_FILE = join(TMP, "config.json")

// loadConfig 在调用时读 process.env,无需 re-import;只需在 case 间切换 env。
describe("loadConfig secretKey 权限修复", () => {
  const savedFile = process.env.WANLING_CONFIG_FILE
  const savedKey = process.env.WANLING_SECRET_KEY
  const savedProxyPw = process.env.WANLING_PROXY_PASSWORD

  beforeEach(() => {
    mkdirSync(TMP, { recursive: true })
    // 默认指向 tmp 文件,且不带 secretKey env（每个 case 按需覆盖）
    process.env.WANLING_CONFIG_FILE = CFG_FILE
    delete process.env.WANLING_SECRET_KEY
    // 给定 proxyPassword,隔离 proxyPassword 自动初始化(它也会 chmod),让本组聚焦 secretKey 行为
    process.env.WANLING_PROXY_PASSWORD = "skip-auto-init"
  })

  afterEach(() => {
    rmSync(TMP, { recursive: true, force: true })
    // 还原 env
    if (savedFile === undefined) delete process.env.WANLING_CONFIG_FILE
    else process.env.WANLING_CONFIG_FILE = savedFile
    if (savedKey === undefined) delete process.env.WANLING_SECRET_KEY
    else process.env.WANLING_SECRET_KEY = savedKey
    if (savedProxyPw === undefined) delete process.env.WANLING_PROXY_PASSWORD
    else process.env.WANLING_PROXY_PASSWORD = savedProxyPw
  })

  it("secretKey 来自文件 → loadConfig 后权限被修复为 0o600", () => {
    // 模拟旧版本创建的 config.json:含 secretKey + 宽松权限 0o644
    writeFileSync(
      CFG_FILE,
      JSON.stringify({ secretKey: "sk-from-file", serverUrl: "http://localhost:18008" }),
      "utf-8",
    )
    chmodSync(CFG_FILE, 0o644)
    expect(statSync(CFG_FILE).mode & 0o777).toBe(0o644)

    const cfg = loadConfig()

    expect(cfg.secretKey).toBe("sk-from-file")
    // 权限应被实际修复为 0o600（不再只是打印"已确保"）
    expect(statSync(CFG_FILE).mode & 0o777).toBe(0o600)
  })

  it("secretKey 来自环境变量 → 不触发文件 chmod（保持原权限）", () => {
    process.env.WANLING_SECRET_KEY = "sk-from-env"
    writeFileSync(
      CFG_FILE,
      JSON.stringify({ serverUrl: "http://localhost:18008" }),
      "utf-8",
    )
    chmodSync(CFG_FILE, 0o644)

    loadConfig()

    // env 是安全源,不该动文件权限
    expect(statSync(CFG_FILE).mode & 0o777).toBe(0o644)
  })

  it("文件无 secretKey → 不触发 chmod", () => {
    writeFileSync(
      CFG_FILE,
      JSON.stringify({ serverUrl: "http://localhost:18008" }),
      "utf-8",
    )
    chmodSync(CFG_FILE, 0o644)

    loadConfig()

    expect(statSync(CFG_FILE).mode & 0o777).toBe(0o644)
  })
})

describe("loadConfig defaultDirectory 加载", () => {
  const savedFile = process.env.WANLING_CONFIG_FILE
  const savedDir = process.env.WANLING_DEFAULT_DIRECTORY

  beforeEach(() => {
    mkdirSync(TMP, { recursive: true })
    process.env.WANLING_CONFIG_FILE = CFG_FILE
    delete process.env.WANLING_DEFAULT_DIRECTORY
  })

  afterEach(() => {
    rmSync(TMP, { recursive: true, force: true })
    if (savedFile === undefined) delete process.env.WANLING_CONFIG_FILE
    else process.env.WANLING_CONFIG_FILE = savedFile
    if (savedDir === undefined) delete process.env.WANLING_DEFAULT_DIRECTORY
    else process.env.WANLING_DEFAULT_DIRECTORY = savedDir
  })

  it("defaultDirectory 从 WANLING_DEFAULT_DIRECTORY env 加载", () => {
    process.env.WANLING_DEFAULT_DIRECTORY = "/home/user/work"
    const cfg = loadConfig()
    expect(cfg.defaultDirectory).toBe("/home/user/work")
  })

  it("defaultDirectory 默认空串(未配)", () => {
    const cfg = loadConfig()
    expect(cfg.defaultDirectory).toBe("")
  })

  it("defaultDirectory 从 config.json 覆盖 env", () => {
    process.env.WANLING_DEFAULT_DIRECTORY = "/from-env"
    writeFileSync(
      CFG_FILE,
      JSON.stringify({ defaultDirectory: "/from-file" }),
      "utf-8",
    )
    const cfg = loadConfig()
    expect(cfg.defaultDirectory).toBe("/from-file")
  })
})

describe("loadConfig proxyPassword auto-init 定向写(不落盘 env secretKey)", () => {
  const savedFile = process.env.WANLING_CONFIG_FILE
  const savedKey = process.env.WANLING_SECRET_KEY
  const savedProxyPw = process.env.WANLING_PROXY_PASSWORD
  // 独立 tmp 目录,避免与其他 describe 组冲突
  const TMP2 = join(tmpdir(), `wl-config-init-${process.pid}-${Date.now()}`)
  const CFG2 = join(TMP2, "config.json")

  beforeEach(() => {
    mkdirSync(TMP2, { recursive: true })
    process.env.WANLING_CONFIG_FILE = CFG2
    // secretKey 来自 env(项目推荐的不落盘方式)
    process.env.WANLING_SECRET_KEY = "sk-from-env-do-not-persist"
    // 不设 WANLING_PROXY_PASSWORD → 触发 auto-init
    delete process.env.WANLING_PROXY_PASSWORD
  })

  afterEach(() => {
    rmSync(TMP2, { recursive: true, force: true })
    if (savedFile === undefined) delete process.env.WANLING_CONFIG_FILE
    else process.env.WANLING_CONFIG_FILE = savedFile
    if (savedKey === undefined) delete process.env.WANLING_SECRET_KEY
    else process.env.WANLING_SECRET_KEY = savedKey
    if (savedProxyPw === undefined) delete process.env.WANLING_PROXY_PASSWORD
    else process.env.WANLING_PROXY_PASSWORD = savedProxyPw
  })

  it("auto-init 不落盘 env 来源的 secretKey(无既有文件)", () => {
    const cfg = loadConfig()

    expect(cfg.proxyPassword).toBeTruthy()
    expect(cfg.secretKey).toBe("sk-from-env-do-not-persist")

    // 回读落盘文件:只应有 proxyPassword,绝不含 secretKey
    const written = JSON.parse(readFileSync(CFG2, "utf-8"))
    expect(written.proxyPassword).toBe(cfg.proxyPassword)
    expect(written.secretKey).toBeUndefined()
  })

  it("auto-init 定向写保留既有字段,只追加 proxyPassword", () => {
    // 既有文件含别的字段 + 宽松权限,验证不被整体覆盖
    writeFileSync(
      CFG2,
      JSON.stringify({ serverUrl: "http://keep-me:18008", agentId: "agent-x" }),
      "utf-8",
    )

    const cfg = loadConfig()

    expect(cfg.proxyPassword).toBeTruthy()
    // 内存中 config.secretKey 来自 env(loadConfig Object.assign 不写 secretKey 入文件)
    expect(cfg.secretKey).toBe("sk-from-env-do-not-persist")

    const written = JSON.parse(readFileSync(CFG2, "utf-8"))
    // 既有字段保留
    expect(written.serverUrl).toBe("http://keep-me:18008")
    expect(written.agentId).toBe("agent-x")
    // proxyPassword 追加
    expect(written.proxyPassword).toBe(cfg.proxyPassword)
    // env 来源 secretKey 绝不落盘
    expect(written.secretKey).toBeUndefined()
  })
})
