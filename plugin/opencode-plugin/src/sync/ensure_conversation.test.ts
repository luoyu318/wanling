import { describe, it, expect, vi, beforeEach, afterAll } from "vitest"
import { rmSync } from "fs"

const TMP = `/tmp/wl-ec-${process.pid}`

// 隔离 mapper:文件级 vi.mock 提升,内部用 vi.fn() 占位,per-test 用 vi.mocked() 改返回值。
vi.mock("./mapper.js", () => ({
  findBySessionId: vi.fn(),
  upsertSessionMap: vi.fn(),
  drainPendingTuiMessages: vi.fn(() => []),
}))
vi.mock("../config.js", () => ({ configDir: () => TMP }))

afterAll(() => {
  rmSync(TMP, { recursive: true, force: true })
})

import { findBySessionId, upsertSessionMap, drainPendingTuiMessages } from "./mapper.js"
import { ensureConversation, _resetInflight } from "./ensure_conversation.js"

const findMock = vi.mocked(findBySessionId)
const upsertMock = vi.mocked(upsertSessionMap)
const drainMock = vi.mocked(drainPendingTuiMessages)

describe("ensureConversation", () => {
  beforeEach(() => {
    findMock.mockReset()
    upsertMock.mockReset()
    drainMock.mockReset()
    drainMock.mockReturnValue([]) // 默认返空数组(与真实实现一致),需特殊值的用例自行覆盖
    _resetInflight()
  })

  it("并发 3 次同 session 只建一群", async () => {
    findMock.mockReturnValue(undefined)
    const create = vi.fn().mockResolvedValue("conv-xyz")
    const getSessionTitle = vi.fn().mockResolvedValue("")
    const getSessionDirectory = vi.fn().mockResolvedValue("")
    const updateConversationTitle = vi.fn().mockResolvedValue(undefined)
    const deps = {
      wanling: { createGroupAsAgent: create, updateConversationTitle } as any,
      opencode: { getSessionTitle, getSessionDirectory } as any,
      ownerUserId: "user-1",
    }
    const [a, b, c] = await Promise.all([
      ensureConversation("sess-main", deps),
      ensureConversation("sess-main", deps),
      ensureConversation("sess-main", deps),
    ])
    expect(create).toHaveBeenCalledTimes(1)
    expect(a).toBe("conv-xyz")
    expect(b).toBe("conv-xyz")
    expect(c).toBe("conv-xyz")
  })

  it("mapper 已命中则不建群", async () => {
    findMock.mockReturnValue({
      wanlingConvId: "existing",
      opencodeSessionId: "sess",
      lastSyncAt: new Date().toISOString(),
      messageCount: 0,
    })
    const create = vi.fn()
    const convId = await ensureConversation("sess", {
      wanling: { createGroupAsAgent: create } as any,
      opencode: {} as any,
      ownerUserId: "u",
    })
    expect(convId).toBe("existing")
    expect(create).not.toHaveBeenCalled()
  })

  it("directory 通过 getSessionDirectory 拉取并透传到 createGroupAsAgent(TUI 场景)", async () => {
    findMock.mockReturnValue(undefined)
    const create = vi.fn().mockResolvedValue("conv-tui")
    const getSessionTitle = vi.fn().mockResolvedValue("")
    const getSessionDirectory = vi.fn().mockResolvedValue("/workspace/app/chat")
    const deps = {
      wanling: { createGroupAsAgent: create, updateConversationTitle: vi.fn() } as any,
      opencode: { getSessionTitle, getSessionDirectory } as any,
      ownerUserId: "u",
    }

    const convId = await ensureConversation("sess-tui", deps)

    expect(convId).toBe("conv-tui")
    expect(getSessionDirectory).toHaveBeenCalledWith("sess-tui")
    expect(create).toHaveBeenCalledWith(
      "agent_session",
      expect.any(String),
      expect.objectContaining({
        userId: "u",
        directory: "/workspace/app/chat",
      }),
    )
    // mapper 不再写 directory
    const arg = upsertMock.mock.calls[0][0] as Record<string, unknown>
    expect(arg.directory).toBeUndefined()
  })

  it("getSessionDirectory 返空串时 createGroupAsAgent 不传 directory", async () => {
    findMock.mockReturnValue(undefined)
    const create = vi.fn().mockResolvedValue("conv-x")
    const getSessionTitle = vi.fn().mockResolvedValue("")
    const getSessionDirectory = vi.fn().mockResolvedValue("")
    await ensureConversation("sess-x", {
      wanling: { createGroupAsAgent: create, updateConversationTitle: vi.fn() } as any,
      opencode: { getSessionTitle, getSessionDirectory } as any,
      ownerUserId: "u",
    })

    expect(create).toHaveBeenCalledTimes(1)
    const arg = create.mock.calls[0][2] as Record<string, unknown>
    expect(arg.directory).toBeUndefined()
  })

  it("建群后 drain pending tui_user 补发(修复 proxy race 丢首条)", async () => {
    findMock.mockReturnValue(undefined)
    drainMock.mockReturnValue(["race 时暂存的消息"])
    const create = vi.fn().mockResolvedValue("conv-race")
    const sendTypedMessage = vi.fn()
    const getSessionTitle = vi.fn().mockResolvedValue("")
    const getSessionDirectory = vi.fn().mockResolvedValue("")
    await ensureConversation("sess-race", {
      wanling: { createGroupAsAgent: create, updateConversationTitle: vi.fn(), sendTypedMessage } as any,
      opencode: { getSessionTitle, getSessionDirectory } as any,
      ownerUserId: "u",
    })

    expect(drainMock).toHaveBeenCalledWith("sess-race")
    expect(sendTypedMessage).toHaveBeenCalledWith(
      "conv-race", "tui_user", { text: "race 时暂存的消息" }, { silent: true },
    )
  })

  it("无 pending 时不发空消息(drain 返空数组)", async () => {
    findMock.mockReturnValue(undefined)
    drainMock.mockReturnValue([])
    const create = vi.fn().mockResolvedValue("conv-empty")
    const sendTypedMessage = vi.fn()
    await ensureConversation("sess-empty", {
      wanling: { createGroupAsAgent: create, updateConversationTitle: vi.fn(), sendTypedMessage } as any,
      opencode: { getSessionTitle: vi.fn().mockResolvedValue(""), getSessionDirectory: vi.fn().mockResolvedValue("") } as any,
      ownerUserId: "u",
    })

    expect(sendTypedMessage).not.toHaveBeenCalled()
  })
})
