import { describe, it, expect } from "vitest"
import { decodeJwtExp } from "./jwt.js"

describe("decodeJwtExp", () => {
  it("正确解码有效 JWT 的 exp", () => {
    // header.payload.signature
    // payload = {"exp": 1800000000} → base64url
    const payload = Buffer.from(JSON.stringify({ exp: 1800000000 })).toString("base64url")
    const token = `eyJhbGciOiJIUzI1NiJ9.${payload}.sig`
    expect(decodeJwtExp(token)).toBe(1800000000)
  })

  it("无效 token 返回 null", () => {
    expect(decodeJwtExp("not-a-jwt")).toBeNull()
    expect(decodeJwtExp("")).toBeNull()
    expect(decodeJwtExp("a.b")).toBeNull()
  })

  it("payload 无 exp 字段返回 null", () => {
    const payload = Buffer.from(JSON.stringify({ sub: "agent-1" })).toString("base64url")
    const token = `eyJhbGciOiJIUzI1NiJ9.${payload}.sig`
    expect(decodeJwtExp(token)).toBeNull()
  })

  it("payload 不是合法 JSON 返回 null", () => {
    const token = `eyJhbGciOiJIUzI1NiJ9.notjson.sig`
    expect(decodeJwtExp(token)).toBeNull()
  })
})
