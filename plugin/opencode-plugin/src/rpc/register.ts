import type { OpencodeClient as OpencodeClientV2 } from "@opencode-ai/sdk/v2"
import { RPCDispatcher } from "./dispatcher.js"
import { echoHandler } from "./methods/echo.js"
import { projectListHandler } from "./methods/project-list.js"
import { sessionDiffHandler } from "./methods/session-diff.js"
import { fileListHandler } from "./methods/file-list.js"
import { fileReadHandler } from "./methods/file-read.js"
import { sessionCreateHandler } from "./methods/session-create.js"

export function createDefaultDispatcher(opts: {
  getClient: () => OpencodeClientV2 | null
}): RPCDispatcher {
  const d = new RPCDispatcher()
  const ctx = { getClient: opts.getClient }
  d.register("echo", echoHandler, { timeoutHintMs: 3000 })
  d.register(
    "project.list",
    (params) => projectListHandler(params, ctx),
    { timeoutHintMs: 5000 },
  )
  d.register(
    "session.diff",
    (params) => sessionDiffHandler(params, ctx),
    { timeoutHintMs: 10000 },
  )
  d.register(
    "file.list",
    (params) => fileListHandler(params, ctx),
    { timeoutHintMs: 5000 },
  )
  d.register(
    "file.read",
    (params) => fileReadHandler(params, ctx),
    { timeoutHintMs: 5000 },
  )
  d.register(
    "session.create",
    (params) => sessionCreateHandler(params, ctx),
    { timeoutHintMs: 10000 },
  )
  return d
}
