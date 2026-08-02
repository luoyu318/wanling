import { RPCError } from "./types.js"

export type JSONRPCRequest = {
  jsonrpc: "2.0"
  id: string
  method: string
  params?: unknown
}

export type JSONRPCResponse = {
  jsonrpc: "2.0"
  id: string
  result?: unknown
  error?: { code: number; message: string; data?: unknown }
}

export type RPCHandler = (params: unknown) => Promise<unknown>

export type MethodDef = {
  handler: RPCHandler
  timeoutHintMs?: number
}

const ERR_METHOD_NOT_FOUND = -32601
const ERR_INTERNAL = -32603

const DEFAULT_TIMEOUT_HINT_MS = 5000

export class RPCDispatcher {
  private handlers = new Map<string, MethodDef>()

  register(name: string, handler: RPCHandler, opts?: { timeoutHintMs?: number }): void {
    this.handlers.set(name, { handler, timeoutHintMs: opts?.timeoutHintMs })
  }

  methods(): string[] {
    return Array.from(this.handlers.keys())
  }

  listMethods(): Array<{ name: string; timeout_hint_ms: number }> {
    return Array.from(this.handlers.entries()).map(([name, def]) => ({
      name,
      timeout_hint_ms: def.timeoutHintMs ?? DEFAULT_TIMEOUT_HINT_MS,
    }))
  }

  async dispatch(call: JSONRPCRequest): Promise<JSONRPCResponse> {
    const def = this.handlers.get(call.method)
    if (!def) {
      return {
        jsonrpc: "2.0", id: call.id,
        error: { code: ERR_METHOD_NOT_FOUND, message: `method not found: ${call.method}` },
      }
    }
    try {
      const result = await def.handler(call.params)
      return { jsonrpc: "2.0", id: call.id, result }
    } catch (e) {
      if (e instanceof RPCError) {
        return {
          jsonrpc: "2.0", id: call.id,
          error: { code: e.code, message: e.message },
        }
      }
      const message = e instanceof Error ? e.message : String(e)
      return {
        jsonrpc: "2.0", id: call.id,
        error: { code: ERR_INTERNAL, message },
      }
    }
  }
}
