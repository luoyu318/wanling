import { EventEmitter } from "events"
import type { OpencodeClient } from "@opencode-ai/sdk"
import { logger } from "../utils/logger.js"

export interface PartUpdatedPayload {
  sessionID: string
  part: {
    id: string
    type: string
    text?: string
    tool?: string
    callID?: string
    state?: Record<string, unknown>
    time?: { start?: number; end?: number }
    snapshot?: string
    reason?: string
    cost?: number
    tokens?: Record<string, unknown>
  }
  time: number
  skipUserText?: boolean
}

export interface PartDeltaPayload {
  sessionID: string
  messageID: string
  partID: string
  field: string
  delta: string
}

export interface SessionStatusPayload {
  sessionID: string
  status: {
    type: string
    attempt?: number
    message?: string
    next?: number
  }
}

export interface ApprovalRequestPayload {
  id: string
  sessionID: string
  directory: string
  action: string
  resources: string[]
  source: { type: string; messageID: string; callID: string }
  save?: string[]
  metadata?: Record<string, unknown>
}

export interface QuestionAskedPayload {
  id: string
  sessionID: string
  directory: string
  questions: Array<{
    question: string
    header: string
    options: Array<{ label: string; description: string }>
    multiple?: boolean
    custom?: boolean
  }>
  tool?: { messageID: string; callID: string }
}

export interface PermissionRepliedPayload {
  sessionID: string
  requestID: string
  reply: "once" | "always" | "reject"
}

export interface QuestionRepliedPayload {
  sessionID: string
  requestID: string
  answers: Array<Array<string>>
}

export interface QuestionRejectedPayload {
  sessionID: string
  requestID: string
}

export interface SessionModelInfo {
  id: string
  providerID: string
  variant?: string
}

export interface SessionUpdatedPayload {
  sessionID: string
  title: string
  mode: string
  model: SessionModelInfo
  directory: string
  tokens?: {
    input: number
    output: number
    reasoning: number
    cache: { read: number; write: number }
  }
}

export interface VcsBranchUpdatedPayload {
  sessionID: string
  directory: string
  branch: string
}

export interface SubscriberEvents {
  part_updated: [PartUpdatedPayload]
  part_delta: [PartDeltaPayload]
  session_status: [SessionStatusPayload]
  session_idle: [{ sessionID: string }]
  session_updated: [SessionUpdatedPayload]
  vcs_branch_updated: [VcsBranchUpdatedPayload]
  approval_request: [ApprovalRequestPayload]
  question_asked: [QuestionAskedPayload]
  permission_replied: [PermissionRepliedPayload]
  question_replied: [QuestionRepliedPayload]
  question_rejected: [QuestionRejectedPayload]
  // 排队消息状态:delivery=queue 时 opencode 发入队(admitted)/调度(prompted)事件。
  // 供 streamer 同步 queued_status 给 APP(气泡排队徽标)与聚合卡分段。
  queue_admitted: [{ sessionID: string; messageID: string; text: string }]
  queue_prompted: [{ sessionID: string; messageID: string; text: string }]
  error: [unknown]
}

export class EventSubscriber extends EventEmitter {
  private client: OpencodeClient
  private aborted = false
  private lastEventId: string | undefined
  private stream: AsyncIterable<unknown> | null = null
  private abortController: AbortController | null = null
  private currentIteration: Promise<void> | null = null
  private userMessageIds: Set<string> = new Set()
  private static readonly MAX_USER_MSG_IDS = 5000
  // 最近 assistant message 的 time 缓存(回合结束耗时来源):message.updated 事件
  // 携带 info.time(created→completed,毫秒),回合结束时已落库。step-finish part
  // 不含 time,footer 耗时从这里读(比拉 messages 可靠,避免 completed 未落库竞态)。
  private messageTimeCache: Map<string, { created?: number; completed?: number }> = new Map()

  constructor(client: OpencodeClient) {
    super()
    this.client = client
  }

  // 回合结束耗时:读最近 assistant message 缓存(毫秒 created→completed)。
  // 无缓存 / 无 completed → undefined(调用方降级为不显示耗时)。
  peekMessageTime(sessionID: string): { created?: number; completed?: number } | undefined {
    return this.messageTimeCache.get(sessionID)
  }

  private addUserMessageId(msgId: string): void {
    if (this.userMessageIds.size >= EventSubscriber.MAX_USER_MSG_IDS) {
      const oldest = this.userMessageIds.values().next().value
      if (oldest !== undefined) this.userMessageIds.delete(oldest)
    }
    this.userMessageIds.add(msgId)
  }

  async start(): Promise<void> {
    this.aborted = false
    this.currentIteration = this.runLoop()
    try {
      await this.currentIteration
    } finally {
      this.currentIteration = null
    }
  }

  private async runLoop(): Promise<void> {
    let backoff = 1
    while (!this.aborted) {
      this.abortController = new AbortController()
      try {
        const sseOptions = {
          onSseEvent: (e: { id?: string }) => {
            if (e.id) this.lastEventId = e.id
          },
          signal: this.abortController.signal,
          ...(this.lastEventId
            ? { headers: { "Last-Event-ID": this.lastEventId } }
            : {}),
        }
        // SDK SSE options 类型不完整，运行时由 opencode 校验
        const result = await this.client.global.event(sseOptions as unknown as Parameters<typeof this.client.global.event>[0])
        this.stream = result.stream as AsyncIterable<unknown>
        backoff = 1
        logger.info(`[SSE] 连接建立${this.lastEventId ? ` (resume from ${this.lastEventId.slice(0, 16)})` : ""}`)

        for await (const raw of this.stream) {
          if (this.aborted) break
          this.processEvent(raw)
        }
        logger.info(`[SSE] 流结束（对端关闭）`)
      } catch (err) {
        if (!this.aborted) {
          logger.warn(`[SSE] 连接异常: ${err instanceof Error ? err.message : err}`)
          super.emit("error", err)
        }
      } finally {
        this.abortController = null
      }

      if (this.aborted) return

      const jitter = backoff * 0.2 * Math.random()
      await new Promise((r) => setTimeout(r, (backoff + jitter) * 1000))
      backoff = Math.min(backoff * 2, 30)
    }
  }

  private processEvent(raw: unknown): void {
    const event = raw as {
      directory?: string
      payload?: { id?: string; type: string; properties: Record<string, unknown> }
    }
    if (!event?.payload) return

    const { type, properties } = event.payload
    const sessionID = properties?.sessionID as string | undefined
    const directory = event.directory || ""

    if (type === "sync" || type === "server.connected" || type === "server.heartbeat") return

    if (!sessionID) return

    switch (type) {
      case "message.part.updated": {
        const partObj = properties.part as PartUpdatedPayload["part"] & { messageID?: string }
        const skip = partObj.type === "text" && !!partObj.messageID && this.userMessageIds.has(partObj.messageID)
        console.log(`[RAW] part_updated type=${partObj.type} id=${partObj.id?.slice(0, 12)} time=${JSON.stringify(partObj.time)} textLen=${(partObj.text ?? "").length} reason=${partObj.reason ?? "-"} tool=${partObj.tool ?? "-"} status=${(partObj.state as Record<string, unknown> | undefined)?.status ?? "-"}`)
        this.emit("part_updated", {
          sessionID,
          part: partObj,
          time: properties.time as number,
          skipUserText: skip,
        })
        break
      }

      case "message.part.delta":
        this.emit("part_delta", {
          sessionID,
          messageID: properties.messageID as string,
          partID: properties.partID as string,
          field: properties.field as string,
          delta: properties.delta as string,
        })
        break

      case "message.updated": {
        const info = properties.info as Record<string, unknown> | undefined
        console.log(`[RAW] message.updated role=${info?.role ?? "-"} id=${(info as { id?: string })?.id ?? "-"} keys=${Object.keys(info ?? {}).join(",")}`)
        if (info?.role === "user") {
          const msgId = (info as { id?: string }).id
          if (msgId) this.addUserMessageId(msgId)
        }
        // 缓存 assistant message 的 time(回合结束耗时来源)。info.time 形如
        // {created, completed}(毫秒)。message.updated 会推多次:完成前(无 finish,
        // completed 缺失)与完成后(带 finish,completed 有值)。仅 message 完成时
        // (finish 字段存在)更新 completed,避免完成前的中间态覆盖掉已完成值。
        if (info?.role === "assistant") {
          const t = info.time as { created?: number; completed?: number } | undefined
          if (t && typeof t === "object") {
            const prev = this.messageTimeCache.get(sessionID)
            const next = { created: t.created ?? prev?.created, completed: t.completed ?? prev?.completed }
            if (info.finish !== undefined || next.completed !== undefined) {
              this.messageTimeCache.set(sessionID, next)
            }
          }
        }
        break
      }

      case "session.status":
        this.emit("session_status", {
          sessionID,
          status: properties.status as {
            type: string
            attempt?: number
            message?: string
            next?: number
          },
        })
        break

      case "session.idle":
        this.emit("session_idle", { sessionID })
        break

      case "session.updated": {
        const info = properties.info as {
          title?: string
          agent?: string
          model?: { id?: string; providerID?: string; variant?: string }
          tokens?: {
            input?: number
            output?: number
            reasoning?: number
            cache?: { read?: number; write?: number }
          }
        } | undefined
        const model = info?.model
        const rawTokens = info?.tokens
        this.emit("session_updated", {
          sessionID,
          title: info?.title ?? "",
          mode: info?.agent ?? "",
          model: {
            id: model?.id ?? "",
            providerID: model?.providerID ?? "",
            variant: model?.variant,
          },
          directory,
          tokens: rawTokens && typeof rawTokens.input === "number"
            ? {
                input: rawTokens.input,
                output: rawTokens.output ?? 0,
                reasoning: rawTokens.reasoning ?? 0,
                cache: {
                  read: rawTokens.cache?.read ?? 0,
                  write: rawTokens.cache?.write ?? 0,
                },
              }
            : undefined,
        })
        break
      }

      case "vcs.branch.updated": {
        const branch = properties.branch as string | undefined
        if (!branch) return
        this.emit("vcs_branch_updated", {
          sessionID,
          directory,
          branch,
        })
        break
      }

      case "permission.asked": {
        this.emit("approval_request", {
          id: properties.id as string,
          sessionID,
          directory,
          action: properties.permission as string,
          resources: properties.patterns as string[],
          source: properties.tool as ApprovalRequestPayload["source"],
          save: properties.always as string[] | undefined,
          metadata: properties.metadata as Record<string, unknown> | undefined,
        })
        break
      }

      case "question.asked": {
        this.emit("question_asked", {
          id: properties.id as string,
          sessionID,
          directory,
          questions: (properties.questions as QuestionAskedPayload["questions"]) || [],
          tool: properties.tool as QuestionAskedPayload["tool"],
        })
        break
      }

      case "permission.replied": {
        this.emit("permission_replied", {
          sessionID,
          requestID: (properties.requestID as string) || "",
          reply: (properties.reply as PermissionRepliedPayload["reply"]) || "reject",
        })
        break
      }

      case "question.replied": {
        this.emit("question_replied", {
          sessionID,
          requestID: (properties.requestID as string) || "",
          answers: (properties.answers as Array<Array<string>>) || [],
        })
        break
      }

      case "question.rejected": {
        this.emit("question_rejected", {
          sessionID,
          requestID: (properties.requestID as string) || "",
        })
        break
      }

      case "session.next.prompt.admitted": {
        const text = (properties.prompt as { text?: string } | undefined)?.text ?? ""
        this.emit("queue_admitted", {
          sessionID: sessionID as string,
          messageID: properties.messageID as string,
          text,
        })
        break
      }

      case "session.next.prompted": {
        const text = (properties.prompt as { text?: string } | undefined)?.text ?? ""
        this.emit("queue_prompted", {
          sessionID: sessionID as string,
          messageID: properties.messageID as string,
          text,
        })
        break
      }

      default:
        logger.debug(`[SSE] 未处理事件 ${type}: ${JSON.stringify(properties).slice(0, 300)}`)
    }
  }

  emit<K extends keyof SubscriberEvents>(event: K, ...args: SubscriberEvents[K]): boolean {
    return super.emit(event, ...args)
  }

  on<K extends keyof SubscriberEvents>(event: K, listener: (...args: SubscriberEvents[K]) => void): this {
    return super.on(event, listener as (...args: unknown[]) => void)
  }

  stop(): void {
    this.aborted = true
    this.lastEventId = undefined
    // 显式取消进行中的 SSE fetch，避免 socket 泄漏累积（EADDRNOTAVAIL 根因）
    this.abortController?.abort()
    this.abortController = null
  }

  async stopAsync(): Promise<void> {
    this.stop()
    if (this.currentIteration) {
      await this.currentIteration.catch(() => {})
    }
  }
}
