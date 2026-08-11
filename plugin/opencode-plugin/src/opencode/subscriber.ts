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

export interface AssistantMessageCompletedPayload {
  sessionID: string
  messageID: string
  parentID: string
  created: number
  completed: number
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
  // 新 assistant 回合开始(message.updated role=assistant 的 parentID 变化)。
  // 聚合卡分段信号:opencode 对连续消息每条 user→assistant 建独立 message,
  // 新 assistant 的 parentID 指向新 user 消息即新回合 → 结束旧聚合卡开新卡。
  // 同回合多 step(工具循环)的 assistant parentID 相同,不触发分段。
  assistant_message_started: [{ sessionID: string; messageID: string; parentID: string }]
  // assistant 回合完成(message.updated role=assistant 带 completed 且 finish 非
  // tool-calls/unknown,对齐 TUI final() 判定)。聚合卡 footer 收尾信号:此时
  // completed 已落库,回合耗时 = completed - user.created(parentID 归属)可直接计算,
  // 无需轮询等待。created 为完成时 message 的 time.created。
  assistant_message_completed: [AssistantMessageCompletedPayload]
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
  // 最近 assistant message 的 parentID(聚合卡分段信号来源):新 user→assistant
  // 回合开始时,opencode 建新 assistant message,parentID 指向新 user 消息。
  // 同回合多 step(工具循环)的 assistant parentID 相同,不触发分段。
  private lastAssistantParent: Map<string, string> = new Map()
  // 最近 assistant message 的 finish(聚合卡分段判定):opencode 总是先完成旧
  // assistant(推 finish)再创建新 assistant。新 assistant 出现时若旧 finish 是
  // tool-calls(旧回合被新消息打断,未正常 stop)→ 需 interrupt 收尾旧卡;
  // 若旧 finish 是 stop(旧回合正常结束,step-finish 已定稿)→ 不 emit 不打断。
  private lastAssistantFinish: Map<string, string> = new Map()
  // user 消息创建时间缓存(messageID → created):回合耗时起点。assistant_message_completed
  // 事件携带 parentID,需要 parent user 消息的 created 计算完整回合耗时
  // (completed - user.created,对齐 TUI)。上限保护避免长会话无限增长。
  private userCreatedByParent: Map<string, number> = new Map()
  private static readonly MAX_USER_CREATED = 5000

  constructor(client: OpencodeClient) {
    super()
    this.client = client
  }

  // 回合耗时起点:读 parent user 消息的 created(毫秒)。
  // 无缓存 → undefined(调用方降级为不显示耗时)。
  peekUserCreated(parentID: string): number | undefined {
    return this.userCreatedByParent.get(parentID)
  }

  private rememberUserCreated(parentID: string, created: number): void {
    if (this.userCreatedByParent.size >= EventSubscriber.MAX_USER_CREATED) {
      const oldest = this.userCreatedByParent.keys().next().value
      if (oldest !== undefined) this.userCreatedByParent.delete(oldest)
    }
    this.userCreatedByParent.set(parentID, created)
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
        const infoId = (info as { id?: string })?.id ?? "-"
        const infoTime = (info?.time ?? {}) as Record<string, unknown>
        const infoFinish = (info as { finish?: unknown })?.finish
        console.log(
          `[RAW] message.updated role=${info?.role ?? "-"} id=${infoId.slice(0, 20)} parentID=${((info as { parentID?: string })?.parentID ?? "-").slice(0, 20)} time=${JSON.stringify(infoTime)} finish=${infoFinish === undefined ? "-" : JSON.stringify(infoFinish)}`,
        )
        if (info?.role === "user") {
          const msgId = (info as { id?: string }).id
          const created = (info?.time as { created?: number } | undefined)?.created
          if (msgId && created) {
            // 记录 user 消息创建时间:回合耗时起点(assistant_message_completed 时
            // 按 parentID 查 user.created 算完整回合耗时)。message.updated 会推多次,
            // 幂等覆盖同 id。
            this.rememberUserCreated(msgId, created)
          }
          if (msgId && !this.userMessageIds.has(msgId)) {
            const isFirstUser = this.userMessageIds.size === 0
            this.addUserMessageId(msgId)
            console.log(`[subscriber] user message first-seen id=${msgId.slice(0, 12)} isFirst=${isFirstUser} setSize=${this.userMessageIds.size}`)
          }
        }
        // assistant 回合边界(聚合卡分段):新 assistant message 的 parentID 指向
        // 新 user 消息 = 新回合开始。message.updated 会推多次(创建/完成/重推),
        // 同 message parentID 不变,仅首次(与上次不同)emit。
        // 判定:仅当旧 assistant 以 tool-calls 完成(旧回合被新消息打断,未正常 stop)
        // 才 emit —— 旧回合 stop 时 step-finish 已正常定稿聚合卡,无需 interrupt。
        if (info?.role === "assistant") {
          const parentID = (info as { parentID?: string }).parentID
          const msgId = (info as { id?: string }).id
          if (parentID && msgId) {
            const prev = this.lastAssistantParent.get(sessionID)
            if (prev !== undefined && prev !== parentID) {
              const prevFinish = this.lastAssistantFinish.get(sessionID)
              if (prevFinish !== "stop") {
                console.log(`[subscriber] assistant round started id=${msgId.slice(0, 12)} parentID=${parentID.slice(0, 12)} prevFinish=${prevFinish ?? "-"}`)
                this.emit("assistant_message_started", { sessionID: sessionID as string, messageID: msgId, parentID })
              } else {
                console.log(`[subscriber] assistant round 旧回合已 stop 定稿,不打断 prevFinish=${prevFinish}`)
              }
            }
            this.lastAssistantParent.set(sessionID, parentID)
          }
          // 记录最近 assistant 的 finish:完成时(带 finish)更新,用于下个 assistant 的
          // 分段判定(旧回合是否被 tool-calls 打断)。
          const finish = (info as { finish?: unknown }).finish
          if (typeof finish === "string") {
            this.lastAssistantFinish.set(sessionID, finish)
          }
          // assistant 回合完成(聚合卡 footer 收尾信号):completed 已落库且 finish 非
          // tool-calls/unknown(对齐 TUI final() 判定 = 回合真正结束)。此时回合耗时
          // completed - user.created 可直接计算,无需轮询等待落库。
          // message.updated 会推多次,仅首次(带 completed 且 final)emit。
          const t = info.time as { created?: number; completed?: number } | undefined
          const isFinal = finish !== undefined && typeof finish === "string" && !["tool-calls", "unknown"].includes(finish)
          if (isFinal && t && typeof t.created === "number" && typeof t.completed === "number") {
            console.log(`[subscriber] assistant round completed id=${msgId?.slice(0, 12)} parent=${parentID?.slice(0, 12)} finish=${finish} dur=${((t.completed - t.created) / 1000).toFixed(1)}s`)
            if (parentID && msgId) {
              this.emit("assistant_message_completed", {
                sessionID: sessionID as string,
                messageID: msgId,
                parentID,
                created: t.created,
                completed: t.completed,
              })
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
