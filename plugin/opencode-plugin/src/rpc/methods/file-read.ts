import { resolve, relative } from "path"
import { readFile } from "fs/promises"
import { statSync } from "fs"
import { getSessionMap } from "../../sync/mapper.js"
import { probeByContent } from "../../file/probe.js"
import { RPCError } from "../types.js"
import { fetchSessionDirectory, type RPCContext } from "../utils.js"

const DEFAULT_MAX_BYTES = 262144
const HARD_MAX_BYTES = 512 * 1024
const IMAGE_MAX_SIZE = 384 * 1024

type FileReadResult = {
  path: string
  type: "text" | "image" | "binary"
  mime: string
  size: number
  content?: string
  content_base64?: string
  truncated?: boolean
}

export const fileReadHandler = async (
  params: unknown,
  ctx: RPCContext,
): Promise<FileReadResult> => {
  const p = params as Record<string, unknown>
  const convId = p?.wanling_conv_id
  if (typeof convId !== "string" || convId === "") {
    throw new RPCError(-32602, "invalid params: wanling_conv_id required")
  }
  const filePath = p?.path
  if (typeof filePath !== "string" || filePath === "") {
    throw new RPCError(-32602, "invalid params: path required")
  }

  let directory: string | null =
    typeof p?.directory === "string" && p.directory !== "" ? p.directory : null
  if (!directory) {
    const map = getSessionMap(convId)
    if (!map) {
      throw new RPCError(-32601, "session not created")
    }
    directory = await fetchSessionDirectory(ctx.getClient, map.opencodeSessionId)
  }
  if (!directory) {
    throw new RPCError(-32603, "directory not anchored")
  }

  const absCwd = resolve(directory)
  const absPath = resolve(absCwd, filePath)
  const rel = relative(absCwd, absPath)
  if (rel.startsWith("..") || rel === "..") {
    throw new RPCError(-32602, `path escapes session.directory: ${filePath}`)
  }

  const probe = await probeByContent(filePath, absPath)
  const requestedMax = typeof p?.max_bytes === "number" && p.max_bytes > 0 ? p.max_bytes : DEFAULT_MAX_BYTES
  const maxBytes = Math.min(requestedMax, HARD_MAX_BYTES)

  let size = 0
  try {
    size = statSync(absPath).size
  } catch (e) {
    throw new RPCError(-32605, `read failed: ${(e as Error).message}`)
  }

  if (probe.kind === "binary") {
    return {
      path: filePath,
      type: "binary",
      mime: probe.mime,
      size,
    }
  }

  if (probe.kind === "image") {
    if (size > IMAGE_MAX_SIZE) {
      throw new RPCError(-32605, `image too large: ${size} bytes (max ${IMAGE_MAX_SIZE})`)
    }
    try {
      const buf = await readFile(absPath)
      return {
        path: filePath,
        type: "image",
        mime: probe.mime,
        size,
        content_base64: buf.toString("base64"),
        truncated: false,
      }
    } catch (e) {
      throw new RPCError(-32605, `read failed: ${(e as Error).message}`)
    }
  }

  try {
    const content = await readFile(absPath, { encoding: "utf-8" })
    const truncated = content.length > maxBytes
    return {
      path: filePath,
      type: "text",
      mime: probe.mime,
      size,
      content: truncated ? content.slice(0, maxBytes) : content,
      truncated,
    }
  } catch (e) {
    throw new RPCError(-32605, `read failed: ${(e as Error).message}`)
  }
}
