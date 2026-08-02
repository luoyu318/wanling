import { describe, it, expect, beforeEach, afterAll, vi } from "vitest"
import { rmSync } from "fs"
import { join } from "path"

// 隔离:mock configDir 到临时目录,避免污染真实 ~/.config
// vi.mock 工厂被 vitest 提升到文件顶部,引用的变量必须用 vi.hoisted 声明
const { TMP } = vi.hoisted(() => ({
  TMP: `/tmp/wl-mapper-test-${process.pid}-${Date.now()}`,
}))
vi.mock("../config.js", () => ({ configDir: () => TMP }))

afterAll(() => {
  rmSync(TMP, { recursive: true, force: true })
})

// 动态 import 让 mock 生效;每个 test 前重置模块 cache 清掉 mapper 的内存 cache
let mapper: typeof import("./mapper.js")
beforeEach(async () => {
  vi.resetModules()
  // 清理上一次测试残留的 store 文件,确保每个 test 从干净状态开始
  rmSync(join(TMP, "session-maps.json"), { force: true })
  mapper = await import("./mapper.js")
})

describe("mapper 精确 1:1 映射", () => {
  it("upsert + getSessionMap 精确命中", () => {
    mapper.upsertSessionMap({
      wanlingConvId: "conv-1",
      opencodeSessionId: "sess-1",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const got = mapper.getSessionMap("conv-1")
    expect(got?.opencodeSessionId).toBe("sess-1")
  })

  it("getSessionMap 未命中返 undefined(无 fallback)", () => {
    expect(mapper.getSessionMap("not-exist")).toBeUndefined()
  })

  it("findBySessionId 未命中返 undefined(无 ownerConvId 兜底)", () => {
    expect(mapper.findBySessionId("no-session")).toBeUndefined()
  })

  it("findBySessionId 多匹配取最新 + 清理旧", () => {
    mapper.upsertSessionMap({ wanlingConvId: "c-old", opencodeSessionId: "s-dup", lastSyncAt: "2026-01-01T00:00:00Z", messageCount: 0 })
    mapper.upsertSessionMap({ wanlingConvId: "c-new", opencodeSessionId: "s-dup", lastSyncAt: "2026-07-10T00:00:00Z", messageCount: 0 })
    const got = mapper.findBySessionId("s-dup")
    expect(got?.wanlingConvId).toBe("c-new")
    // 旧的被清理
    expect(mapper.getSessionMap("c-old")).toBeUndefined()
  })
})

describe("pending tui_user 暂存队列", () => {
  it("enqueue 后 drain 取出并清空(保序)", () => {
    mapper.enqueuePendingTuiMessage("sess-1", "msg1")
    mapper.enqueuePendingTuiMessage("sess-1", "msg2")
    const drained = mapper.drainPendingTuiMessages("sess-1")
    expect(drained).toEqual(["msg1", "msg2"])
    // 二次 drain 为空(已清空)
    expect(mapper.drainPendingTuiMessages("sess-1")).toEqual([])
  })

  it("drain 未入队的 session 返空数组", () => {
    expect(mapper.drainPendingTuiMessages("nope")).toEqual([])
  })

  it("不同 session 互不干扰", () => {
    mapper.enqueuePendingTuiMessage("sess-a", "a1")
    mapper.enqueuePendingTuiMessage("sess-b", "b1")
    expect(mapper.drainPendingTuiMessages("sess-a")).toEqual(["a1"])
    expect(mapper.drainPendingTuiMessages("sess-b")).toEqual(["b1"])
  })
})
