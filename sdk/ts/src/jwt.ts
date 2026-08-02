export function decodeJwtExp(token: string): number | null {
  const parts = token.split(".")
  if (parts.length < 2) return null
  try {
    const payload = JSON.parse(
      Buffer.from(parts[1], "base64url").toString("utf-8"),
    )
    if (typeof payload?.exp !== "number") return null
    return payload.exp
  } catch {
    return null
  }
}
