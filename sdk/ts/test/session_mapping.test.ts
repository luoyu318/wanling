import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import { SessionMapping } from "../src/session_mapping.js"

const tmpDirs: string[] = []

afterEach(() => {
  for (const dir of tmpDirs.splice(0)) rmSync(dir, { recursive: true, force: true })
})

function tmpPath(name: string): string {
  const dir = mkdtempSync(join(tmpdir(), "wl-session-map-"))
  tmpDirs.push(dir)
  return join(dir, name)
}

describe("SessionMapping", () => {
  it("原子写 + 重载恢复双索引", async () => {
    const path = join(tmpPath(""), "sub", "mapping.json") // 子目录不存在 → 递归建目录
    const created: string[] = []
    const m = new SessionMapping(path, async (sessionId) => {
      created.push(sessionId)
      return "conv_1"
    })
    // miss 时建会话,返回 convId
    expect(await m.ensureConversation("sess_1", { title: "T" })).toBe("conv_1")
    expect(created).toEqual(["sess_1"])
    // 幂等:已知 session 不再建
    expect(await m.ensureConversation("sess_1", { title: "T" })).toBe("conv_1")
    expect(created).toEqual(["sess_1"])
    // tmp 文件已 rename,无残留
    expect(existsSync(`${path}.tmp`)).toBe(false)
    // 新实例 load 恢复双索引
    const m2 = new SessionMapping(path, async () => {
      throw new Error("不应再建")
    })
    expect(m2.bySession("sess_1")).toBe("conv_1")
    expect(m2.byConversation("conv_1")).toBe("sess_1")
    // remove 后内存 + 落盘同步清除
    m2.remove("sess_1")
    expect(m2.bySession("sess_1")).toBeUndefined()
    expect(m2.byConversation("conv_1")).toBeUndefined()
    const m3 = new SessionMapping(path, async () => "conv_2")
    expect(m3.bySession("sess_1")).toBeUndefined()
  })

  it("损坏文件备份后重置", async () => {
    const dir = tmpPath("")
    const path = join(dir, "mapping.json")
    writeFileSync(path, "{not json", "utf8")
    const m = new SessionMapping(path, async () => "conv_x")
    // load 不抛,索引重置为空
    expect(m.bySession("whatever")).toBeUndefined()
    const backups = readdirSync(dir).filter((f) => f.startsWith("mapping.json.corrupt."))
    expect(backups.length).toBe(1)
    // 重置后可正常重建映射
    expect(await m.ensureConversation("s2", { title: "T2" })).toBe("conv_x")
    const raw = JSON.parse(readFileSync(path, "utf8")) as { mappings: Record<string, { sessionId: string }> }
    expect(Object.keys(raw.mappings)).toEqual(["conv_x"])
  })
})
