import { describe, it, expect } from "vitest"
import { RPCError } from "./types.js"

describe("RPCError", () => {
  it("是 Error 子类,携带 code + message", () => {
    const e = new RPCError(-32601, "session not created")
    expect(e).toBeInstanceOf(Error)
    expect(e).toBeInstanceOf(RPCError)
    expect(e.code).toBe(-32601)
    expect(e.message).toBe("session not created")
    expect(e.name).toBe("RPCError")
  })

  it("可被 try/catch + instanceof 识别", () => {
    try {
      throw new RPCError(-32602, "invalid params")
    } catch (e) {
      expect(e instanceof RPCError).toBe(true)
      if (e instanceof RPCError) {
        expect(e.code).toBe(-32602)
      }
    }
  })
})
