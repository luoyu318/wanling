import type { WanlingClient } from "../wanling/client.js"
import { logger } from "../utils/logger.js"
import type { MessageCreatePayload, GenerationAbortPayload, ConvUpdatePayload } from "../wanling/types.js"
import type { OpencodeBridge } from "../opencode/bridge.js"
import type { WanlingDownloader } from "../storage/downloader.js"
import type {
  SessionMap} from "./mapper.js";
import {
  upsertSessionMap,
  getSessionMap,
  listSessionMaps,
} from "./mapper.js"
import { getCard, deleteCard } from "./card_store.js"
import { EventEmitter } from "events"

export class SyncEngine extends EventEmitter {
  private wanling: WanlingClient
  private opencode: OpencodeBridge
  private readonly downloader: WanlingDownloader | null
  private readonly defaultDirectory: string
  private syncInProgress: boolean = false

  constructor(
    wanling: WanlingClient,
    opencode: OpencodeBridge,
    defaultDirectory: string = "",
    downloader: WanlingDownloader | null = null,
  ) {
    super()
    this.wanling = wanling
    this.opencode = opencode
    this.defaultDirectory = defaultDirectory
    this.downloader = downloader
  }

  start(): void {
    this.wanling.on("message", (payload: MessageCreatePayload) => {
      this.handleIncomingMessage(payload).catch((err) =>
        this.emit("error", err),
      )
    })
    this.wanling.on("abort", (payload: GenerationAbortPayload) => {
      this.handleAbort(payload).catch((err) =>
        this.emit("error", err),
      )
    })
    this.wanling.on("conv_update", (payload: ConvUpdatePayload) => {
      this.handleConvUpdate(payload).catch((err) =>
        this.emit("error", err),
      )
    })
  }

  private async handleIncomingMessage(
    payload: MessageCreatePayload,
  ): Promise<void> {
    logger.info(`[sync] handleIncomingMessage msgId=${payload.id?.slice(0, 8)} sender=${payload.sender_type} conv=${payload.conversation_id?.slice(0, 8)}`)
    if (payload.sender_type !== "user") return
    if (!payload.sender_id) return

    const convId = payload.conversation_id
    const content = payload.content || {}
    const msgType = content.msg_type || "text"
    const data = (content.data || {}) as Record<string, unknown>

    if (msgType === "permission_reply") {
      await this.handlePermissionReply(convId, data)
      return
    }
    if (msgType === "question_reply") {
      await this.handleQuestionReply(convId, data)
      return
    }

    // _slash 分支优先于 text/markdown:命令调用走专用通道,与 promptAsync 互斥。
    // 即使 data.text 为空也允许进入(_slash 不依赖 text)。
    const slashPayload = data._slash as { name?: string; args?: string } | undefined
    const isSlashCommand = !!slashPayload?.name

    // media 分支优先于 text 守卫:image/file/mixed 走下载+提示路径,
    // 不依赖 data.text(纯媒体消息通常无 text 字段)。
    if (!isSlashCommand && (msgType === "image" || msgType === "file" || msgType === "mixed")) {
      // mixed 消息的顶层 text(用户随图附言):trim 后空串视为无文字,维持原提示格式
      const mixedText =
        typeof data.text === "string" && data.text.trim().length > 0
          ? data.text.trim()
          : undefined
      const mediaItems = this.extractMediaItems(data)
      let map = getSessionMap(convId)
      if (!map) {
        // 与 text 分支同一份 session 创建逻辑(directory 透传给 OC)。
        const directory = (data._directory as string) || this.defaultDirectory || undefined
        const sessionId = await this.opencode.createSession("万灵对话", directory)
        console.warn(`[sync] 为 conv ${convId.slice(0, 8)}… 创建新 session ${sessionId.slice(0, 12)}… (media, directory=${directory ?? "default"})`)
        map = {
          wanlingConvId: convId,
          opencodeSessionId: sessionId,
          lastSyncAt: new Date().toISOString(),
          messageCount: 0,
        }
        upsertSessionMap(map)
      }
      this.wanling.sendTyping(convId)
      await this.handleMediaMessage(map.opencodeSessionId, msgType, mediaItems, payload.id, mixedText)
      upsertSessionMap({ ...map, lastSyncAt: new Date().toISOString() })
      return
    }

    if (!isSlashCommand) {
      // 非 _slash 路径保留原 text 守卫
      const text =
        msgType === "text" || msgType === "markdown"
          ? String(data.text || "")
          : ""
      if (!text) return
    }

    let map = getSessionMap(convId)
    if (!map) {
      // directory 透传给 OC createSession(OC 才是工作目录真相源)。
      // 不再写 mapper.directory —— 该字段已升级到 server conversations.directory 一级列,
      // plugin 不缓存,RPC 方法按需调 bridge.getSessionDirectory 拉。
      const directory = (data._directory as string) || this.defaultDirectory || undefined
      const sessionId = await this.opencode.createSession("万灵对话", directory)
      logger.info(`[sync] 为 conv ${convId.slice(0, 8)}… 创建新 session ${sessionId.slice(0, 12)}… (directory=${directory ?? "default"})`)
      map = {
        wanlingConvId: convId,
        opencodeSessionId: sessionId,
        lastSyncAt: new Date().toISOString(),
        messageCount: 0,
      }
      upsertSessionMap(map)
    }

    this.wanling.sendTyping(convId)

    try {
      if (isSlashCommand && slashPayload?.name) {
        const slashName = slashPayload.name
        const slashArgs = slashPayload.args ?? ""

        // /compact 特判:OC 真实端点是 v1 /summarize(抓包确认),
        // 不走通用 /command 通道。需要 model 字段(必填),缺失时 fail-fast。
        if (slashName === "compact") {
          const rawModel = data._model as { provider_id?: string; model_id?: string } | undefined
          if (!rawModel?.provider_id || !rawModel?.model_id) {
            throw new Error("compact 命令缺少 _model 字段(provider_id/model_id)")
          }
          await this.opencode.summarizeSession(
            map.opencodeSessionId,
            rawModel.provider_id,
            rawModel.model_id,
          )
        } else {
          await this.opencode.runCommand(
            map.opencodeSessionId,
            slashName,
            slashArgs,
          )
        }
      } else {
        // 原路径:promptAsync + mode/model 透传
        const agent = (data._mode as string) || undefined
        // APP 端 modelOverride 透传:_model = {provider_id, model_id}(snake_case 来自 WS 协议)
        // 转换为 opencode SDK 的 camelCase: {providerID, modelID}
        // 单一真相点:snake→camel 转换只在这里发生,bridge 层只接受 camelCase。
        // 防御:部分字段缺失(如 APP bug)时降级为 undefined,不传残缺 model 给 OC。
        const rawModel = data._model as { provider_id?: string; model_id?: string } | undefined
        const model = rawModel && rawModel.provider_id && rawModel.model_id
          ? { providerID: rawModel.provider_id, modelID: rawModel.model_id }
          : undefined
        await this.sendPromptWithInterrupt(map.opencodeSessionId, payload.id, String(data.text || ""), agent, model)
      }
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      console.error(`[sync] inject failed: ${msg}`)
      this.wanling.sendTypedMessage(convId, "markdown", {
        text: `⚠️ 消息投递失败: ${msg}`,
      })
    }

    upsertSessionMap({
      ...map,
      lastSyncAt: new Date().toISOString(),
    })
  }

  // 处理停止生成信号:user 点击停止按钮 → server dispatch GENERATION_ABORT →
  // 查 mapper 拿到 ocSessionId → 调 bridge.abortSession 中止当前生成。
  // 幂等:无 session 映射 / session 不存在时静默跳过(用户可重复点击不报错)。
  private async handleAbort(payload: GenerationAbortPayload): Promise<void> {
    const convId = payload.conversation_id
    const map = getSessionMap(convId)
    if (!map) {
      logger.info(`[sync] abort conv=${convId.slice(0, 8)}… 无 session 映射,跳过`)
      return
    }
    try {
      await this.opencode.abortSession(map.opencodeSessionId)
      logger.info(`[sync] abort conv=${convId.slice(0, 8)}… session=${map.opencodeSessionId.slice(0, 12)}… 已发送中止信号`)
      // 聚合卡主动收尾定格:abort 后 opencode 不再推 step-finish footer,
      // 由 streamer 侧对主 session 聚合卡 finishCard("stop"),APP footer 显示「已停止」。
      // 经事件解耦(engine 不持有 streamer),index.ts 接线到 streamer.finishCardForSession。
      this.emit("aggregate_finish", { sessionId: map.opencodeSessionId, reason: "stop" as const })
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      console.error(`[sync] abort conv=${convId.slice(0, 8)}… 失败: ${msg}`)
    }
  }

  // 处理会话标题变更(万灵→OC 单向同步):APP 改会话名 → server 广播
  // CONVERSATION_UPDATE 给全员(含 agent) → 插件调本方法 → bridge.renameSession
  // 改 OC session 标题。
  // OC 端改完后回 session.updated,但 server 端 UpdateTitleAsAgent 只广播给 user
  // (BroadcastConversationUpdateToUsers),插件收不到自己触发的回声,物理断环。
  // 空标题 = 仅改头像的事件(server 空串语义=不动),跳过不当作改名。
  private async handleConvUpdate(payload: ConvUpdatePayload): Promise<void> {
    const convId = payload.conv_id
    const title = (payload.title || "").trim()
    if (!title) return
    const map = getSessionMap(convId)
    if (!map) return
    try {
      await this.opencode.renameSession(map.opencodeSessionId, title)
      logger.info(`[sync] 标题同步 conv=${convId.slice(0, 8)}… → session=${map.opencodeSessionId.slice(0, 12)}… title="${title}"`)
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      console.error(`[sync] 标题同步 conv=${convId.slice(0, 8)}… 失败: ${msg}`)
    }
  }

  // prompt 带指数退避重试(瞬时故障自愈):OpenCode Serve 抖动 / 短暂不可达时
  // 避免单次失败直接丢消息。全 N 次失败才向上抛(由调用方告知用户)。
  private async promptWithRetry(
    sessionId: string,
    text: string,
    agent?: string,
    model?: { providerID: string; modelID: string },
  ): Promise<void> {
    const MAX_RETRIES = 3
    const BASE_DELAY = 1000
    let lastErr: Error | null = null
    for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
      try {
        await this.opencode.promptAsync(sessionId, text, agent, model)
        return
      } catch (err) {
        lastErr = err instanceof Error ? err : new Error(String(err))
        if (attempt < MAX_RETRIES) {
          const delay = BASE_DELAY * Math.pow(2, attempt)
          console.warn(`[sync] prompt 第 ${attempt + 1} 次失败,${delay}ms 后重试: ${lastErr.message}`)
          await new Promise((r) => setTimeout(r, delay))
        }
      }
    }
    throw lastErr ?? new Error("promptWithRetry: unreachable")
  }

  // 发送 prompt:用户消息直接 v1 promptAsync 异步发送(不阻塞,opencode 自带排队)。
  // 聚合卡分段由消息边界驱动:opencode 对连续消息每条 user→assistant 建独立
  // message,subscriber 检测新回合(assistant_message_started)→ streamer 收尾旧卡。
  private async sendPromptWithInterrupt(
    sessionId: string,
    wanlingMsgId: string,
    text: string,
    agent?: string,
    model?: { providerID: string; modelID: string },
  ): Promise<void> {
    await this.promptWithRetry(sessionId, text, agent, model)
  }

  // media 消息可下载条目提取:mixed 按 items 全量(不再只取首项),image/file
  // 取顶层 file_id。file_id 非空字符串即收(image/file 类型均可,桥不区分)。
  private extractMediaItems(
    data: Record<string, unknown>,
  ): Array<{ fileId: string; filename?: string }> {
    const items = data.items as Array<{ file_id?: unknown; filename?: unknown }> | undefined
    if (!items) {
      const fileId = data.file_id
      if (typeof fileId === "string" && fileId.length > 0) {
        const filename = data.filename
        return [
          {
            fileId,
            ...(typeof filename === "string" && filename ? { filename } : {}),
          },
        ]
      }
      return []
    }
    return items
      .filter(
        (it): it is { file_id: string; filename?: unknown } =>
          typeof it?.file_id === "string" && it.file_id.length > 0,
      )
      .map((it) => {
        const filename = it.filename
        return {
          fileId: it.file_id,
          ...(typeof filename === "string" && filename ? { filename } : {}),
        }
      })
  }

  // media 消息处理:fail fast(条目为空即 warn 跳过,不阻塞会话)→
  // 逐条下载(mixed 多附件全量处理;单条失败 warn 跳过,部分成功时 agent
  // 仍可看到可用附件,全部失败才退化占位文本)→ 成功发路径提示文本。
  // downloader 缺失配置时也退化为提示文本(保证会话不中断)。
  private async handleMediaMessage(
    sessionId: string,
    msgType: string,
    mediaItems: Array<{ fileId: string; filename?: string }>,
    wanlingMsgId?: string,
    mixedText?: string,
  ): Promise<void> {
    if (mediaItems.length === 0) {
      console.warn("[sync] media message missing file_id, skip")
      return
    }
    if (!this.downloader) {
      console.warn("[sync] downloader not configured, cannot handle media message")
      await this.sendPromptWithInterrupt(sessionId, wanlingMsgId ?? "", this.fallbackText(msgType))
      return
    }

    // 下载与提示拆开:单条下载失败不中断其余附件(部分成功优先);
    // 全部失败 → 退化文本。下载成功后若提示失败(重试耗尽),向上抛到
    // start() 的 catch(emit "error"),与 text 分支行为一致。
    const paths: string[] = []
    for (const item of mediaItems) {
      const expectedExt = item.filename ? extFromFilename(item.filename) : undefined
      try {
        const result = await this.downloader.download({ fileId: item.fileId, expectedExt })
        paths.push(result.path)
      } catch (e) {
        const msg = e instanceof Error ? e.message : String(e)
        console.warn(`[sync] media download failed (${item.fileId}): ${msg}`)
      }
    }
    if (paths.length === 0) {
      await this.sendPromptWithInterrupt(sessionId, wanlingMsgId ?? "", this.fallbackText(msgType))
      return
    }
    await this.sendPromptWithInterrupt(sessionId, wanlingMsgId ?? "", this.mediaPromptText(msgType, paths, mixedText))
  }

  private mediaPromptText(msgType: string, paths: string[], mixedText?: string): string {
    const label = msgType === "image" ? "一张图片" : msgType === "file" ? "一个文件" : "混合内容"
    const loc = paths.join("、")
    // mixed 携带用户文字时拼入提示(agent 同回合看到附件+文字);其余类型无此字段
    if (msgType === "mixed" && mixedText) {
      return `[用户发送了${label}: ${mixedText},位于: ${loc}]`
    }
    return `[用户发送了${label},位于: ${loc}]`
  }

  private fallbackText(msgType: string): string {
    const label = msgType === "image" ? "一张图片" : msgType === "file" ? "一个文件" : "混合内容"
    return `[用户发送了${label},但下载失败]`
  }

  private async handlePermissionReply(
    convId: string,
    data: Record<string, unknown>,
  ): Promise<void> {
    const ocRequestId = data.oc_request_id as string
    const reply = data.reply as "once" | "always" | "reject"

    try {
      const entry = await getCard(ocRequestId)
      await this.opencode.replyPermission(ocRequestId, reply, entry?.directory)

      // 聚合模式(entry.elementId 已存):独立 permission_card PATCH 会把聚合卡整个
      // 改写坏(聚合卡是 aggregate_card 结构)。card 状态更新交给 OC 的 permission.replied
      // 回声 → interaction.onPermissionReplied 更新聚合卡内元素;这里不 deleteCard,
      // 保留 entry 供回声消费(回声幂等:interaction 更新后 deleteCard)。
      if (entry && !entry.elementId) {
        const status = reply === "reject" ? "denied" : "approved"
        await this.wanling.updateMessageContent(entry.msgId, {
          msg_type: "permission_card",
          data: { ...(entry.data || {}), oc_request_id: ocRequestId, status, result: reply },
        })
        await deleteCard(ocRequestId)
      }
    } catch (err) {
      // 404: TUI 端已处理，静默跳过（双向去重不变量）
      if (isNotFound(err)) {
        const msg = (err as Error).message
        logger.info(`[sync] permission ${ocRequestId} already handled, skip (err: ${msg})`)
        await deleteCard(ocRequestId)
        return
      }
      const msg = (err as Error).message
      console.error(`[sync] permission reply failed: ${msg}`)
      this.wanling.sendTypedMessage(convId, "markdown", {
        text: `⚠️ 权限审批失败: ${msg}`,
      })
    }
  }

  private async handleQuestionReply(
    convId: string,
    data: Record<string, unknown>,
  ): Promise<void> {
    const ocRequestId = data.oc_request_id as string
    const rejected = data.rejected as boolean | undefined
    const answers = data.answers as Array<Array<string>> | undefined

    try {
      const entry = await getCard(ocRequestId)
      const directory = entry?.directory
      if (rejected) {
        await this.opencode.rejectQuestion(ocRequestId, directory)
      } else {
        await this.opencode.replyQuestion(ocRequestId, answers || [], directory)
      }

      // 聚合模式(entry.elementId 已存):独立 question_card PATCH 会把聚合卡整个
      // 改写坏。card 状态更新交给 OC 的 question.replied/question.rejected 回声 →
      // interaction.onQuestionReplied/onQuestionRejected 更新聚合卡内元素;
      // 这里不 deleteCard,保留 entry 供回声消费。
      if (entry && !entry.elementId) {
        const status = rejected ? "rejected" : "answered"
        const result = rejected
          ? "rejected"
          : (answers || []).map((a) => a.join(", ")).join(" / ")
        await this.wanling.updateMessageContent(entry.msgId, {
          msg_type: "question_card",
          data: { ...(entry.data || {}), oc_request_id: ocRequestId, status, result },
        })
        await deleteCard(ocRequestId)
      }
    } catch (err) {
      // 404: TUI 端已处理，静默跳过（双向去重不变量）
      if (isNotFound(err)) {
        logger.info(`[sync] question ${ocRequestId} already handled, skip`)
        await deleteCard(ocRequestId)
        return
      }
      const msg = (err as Error).message
      console.error(`[sync] question reply failed: ${msg}`)
      this.wanling.sendTypedMessage(convId, "markdown", {
        text: `⚠️ 问题回答失败: ${msg}`,
      })
    }
  }

  async syncCliToApp(
    wanlingConvId: string,
    sessionId: string,
  ): Promise<void> {
    if (this.syncInProgress) {
      throw new Error("sync already in progress")
    }
    this.syncInProgress = true
    try {
      const history = await this.opencode.getMessageHistory(sessionId)
      let sentCount = 0
      for (const msg of history) {
        if (!msg.text.trim()) continue
        const isUser = msg.role === "user"
        this.wanling.sendTypedMessage(
          wanlingConvId,
          isUser ? "tui_user" : "markdown",
          { text: msg.text },
          // user 消息(tui_user)带 silent:true,与 proxy/http.ts trySyncPrompt 实时路径对齐:
          // 批量回填属历史同步,不应给 user 产生未读(实时路径的 tui_user 同样 silent)。
          isUser ? { silent: true } : undefined,
        )
        sentCount++
        await delay(50)
      }

      upsertSessionMap({
        wanlingConvId,
        opencodeSessionId: sessionId,
        lastSyncAt: new Date().toISOString(),
        messageCount: sentCount,
      })
    } finally {
      this.syncInProgress = false
    }
  }

  getStatus(): {
    connected: boolean
    sessions: SessionMap[]
    syncInProgress: boolean
  } {
    return {
      connected: true,
      sessions: listSessionMaps(),
      syncInProgress: this.syncInProgress,
    }
  }
}

/**
 * 判断是否"未找到"类错误（agent 不存在 / session 已结束）。
 * 优先检查结构化字段（sdkError.code/status），文本匹配仅作 fallback。
 * TODO: 上游 SDK 统一返回结构化 status code 时移除文本匹配。
 */
function isNotFound(err: unknown): boolean {
  const e = err as { sdkError?: { code?: number; status?: number; statusCode?: number }; message?: string }
  const code = e?.sdkError?.code ?? e?.sdkError?.status ?? e?.sdkError?.statusCode
  if (code === 404) return true
  const lower = (e?.message ?? "").toLowerCase()
  return lower.includes("404")
    || lower.includes("not found")
    || lower.includes("does not exist")
    || lower.includes("no longer exists")
    || (lower.includes("session") && lower.includes("ended"))
}

function delay(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms))
}

// 从文件名提取扩展名(含点,小写)。无扩展名时返回 undefined。
// 用于 WanlingDownloader 的 expectedExt 提示(server 端可能不返 Content-Disposition)。
function extFromFilename(name: string): string | undefined {
  const dot = name.lastIndexOf(".")
  if (dot < 0) return undefined
  return name.slice(dot).toLowerCase()
}
