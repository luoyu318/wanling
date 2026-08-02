import { describe, it, expect } from "vitest"
import { RPCDispatcher } from "./dispatcher.js"

describe("RPCDispatcher", () => {
  it("dispatch 命中的 method 返回 result", async () => {
    const d = new RPCDispatcher()
    d.register("echo", async (params) => ({ echo: (params as { text?: string }).text ?? "" }))

    const got = await d.dispatch({ jsonrpc: "2.0", id: "x1", method: "echo", params: { text: "hi" } })

    expect(got).toEqual({ jsonrpc: "2.0", id: "x1", result: { echo: "hi" } })
  })

  it("未知 method 返回 -32601", async () => {
    const d = new RPCDispatcher()
    const got = await d.dispatch({ jsonrpc: "2.0", id: "x2", method: "missing", params: {} })
    expect(got).toEqual({
      jsonrpc: "2.0", id: "x2",
      error: { code: -32601, message: "method not found: missing" },
    })
  })

  it("handler 抛错返回 -32603", async () => {
    const d = new RPCDispatcher()
    d.register("boom", async () => { throw new Error("kaboom") })
    const got = await d.dispatch({ jsonrpc: "2.0", id: "x3", method: "boom", params: {} })
    expect(got.error?.code).toBe(-32603)
    expect(got.error?.message).toContain("kaboom")
  })

  it("列已注册 methods", () => {
    const d = new RPCDispatcher()
    d.register("echo", async () => ({}))
    d.register("ping", async () => ({}))
    expect(d.methods().sort()).toEqual(["echo", "ping"])
  })

  it("handler 抛 RPCError 时透传 code", async () => {
    const d = new RPCDispatcher()
    d.register("custom", async () => {
      const { RPCError } = await import("./types.js")
      throw new RPCError(-32601, "session not created")
    })
    const got = await d.dispatch({ jsonrpc: "2.0", id: "x4", method: "custom", params: {} })
    expect(got.error?.code).toBe(-32601)
    expect(got.error?.message).toBe("session not created")
  })
})

describe("RPCDispatcher.listMethods", () => {
  it("返已注册清单 + 缺省 timeout_hint_ms", () => {
    const d = new RPCDispatcher()
    d.register("echo", async () => ({}), { timeoutHintMs: 3000 })
    d.register("default", async () => ({}))

    const list = d.listMethods()

    expect(list).toHaveLength(2)
    expect(list).toContainEqual({ name: "echo", timeout_hint_ms: 3000 })
    expect(list).toContainEqual({ name: "default", timeout_hint_ms: 5000 })
  })

  it("未注册任何 method 时返空数组", () => {
    const d = new RPCDispatcher()
    expect(d.listMethods()).toEqual([])
  })
})
