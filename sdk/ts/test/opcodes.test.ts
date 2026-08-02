import { describe, it, expect } from "vitest"
import {
  OP_DISPATCH, OP_HEARTBEAT, OP_IDENTIFY, OP_SET_ACTIVE_CONV,
  OP_RESUME, OP_RECONNECT, OP_HELLO, OP_HEARTBEAT_ACK,
  OP_PLUGIN_CALL, OP_PLUGIN_RESULT, OP_STREAM,
} from "../src/opcodes.js"

// 对照 server/internal/model/opcodes.go 的 const 块,server 改动需同步本文件
describe("opcodes 与 server 对齐", () => {
  it("WS opcode 数值与 server/internal/model/opcodes.go 一致", () => {
    expect(OP_DISPATCH).toBe(0)
    expect(OP_HEARTBEAT).toBe(1)
    expect(OP_IDENTIFY).toBe(2)
    expect(OP_SET_ACTIVE_CONV).toBe(3)
    expect(OP_RESUME).toBe(6)
    expect(OP_RECONNECT).toBe(7)
    expect(OP_HELLO).toBe(10)
    expect(OP_HEARTBEAT_ACK).toBe(11)
    expect(OP_PLUGIN_CALL).toBe(12)
    expect(OP_PLUGIN_RESULT).toBe(13)
    expect(OP_STREAM).toBe(14)
  })
})
