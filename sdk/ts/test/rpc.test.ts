import { describe, it, expect } from "vitest"
import { RPCDispatcher, RPCError } from "../src/rpc.js"

describe("RPCDispatcher", () => {
  it("register + dispatch 成功回包", async () => {
    const d = new RPCDispatcher()
    d.register("echo", async (params) => ({ echoed: params }))
    const resp = await d.dispatch({ jsonrpc: "2.0", id: "1", method: "echo", params: { x: 1 } })
    expect(resp.result).toEqual({ echoed: { x: 1 } })
  })

  it("未注册方法返 -32601", async () => {
    const d = new RPCDispatcher()
    const resp = await d.dispatch({ jsonrpc: "2.0", id: "2", method: "nope" })
    expect(resp.error?.code).toBe(-32601)
  })

  it("handler 抛 RPCError 透传 code", async () => {
    const d = new RPCDispatcher()
    d.register("boom", async () => { throw new RPCError(-32002, "timeout") })
    const resp = await d.dispatch({ jsonrpc: "2.0", id: "3", method: "boom" })
    expect(resp.error?.code).toBe(-32002)
    expect(resp.error?.message).toBe("timeout")
  })

  it("handler 抛普通异常返 -32603", async () => {
    const d = new RPCDispatcher()
    d.register("err", async () => { throw new Error("boom") })
    const resp = await d.dispatch({ jsonrpc: "2.0", id: "4", method: "err" })
    expect(resp.error?.code).toBe(-32603)
  })

  it("listMethods 带默认 timeout_hint", async () => {
    const d = new RPCDispatcher()
    d.register("a", async () => ({}), { timeoutHintMs: 3000 })
    d.register("b", async () => ({}))
    const list = d.listMethods()
    expect(list).toEqual([
      { name: "a", timeout_hint_ms: 3000 },
      { name: "b", timeout_hint_ms: 5000 },
    ])
  })
})
