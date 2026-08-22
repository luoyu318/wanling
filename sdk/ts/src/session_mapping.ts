import { copyFileSync, existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs"
import { dirname } from "node:path"

export interface SessionMappingOptions {
  /** 映射文件落盘路径(JSON)。 */
  path: string
}

interface MappingEntry {
  conversationId: string
  sessionId: string
  createdAt: string
}

/**
 * 外部 session ↔ conversation 持久映射:dsh 模式 — tmp+rename 原子写、
 * 双 Map 索引(bySession/byConversation 双向查)、损坏文件备份后重置、
 * miss 时经注入的 createConversation 建会话(幂等)。
 */
export class SessionMapping {
  private byConv = new Map<string, MappingEntry>()
  private bySess = new Map<string, MappingEntry>()
  private readonly path: string
  private loaded = false

  constructor(
    path: string,
    private readonly createConversation: (
      sessionId: string,
      opts: { title: string; ownerUserId?: string; directory?: string },
    ) => Promise<string | undefined>,
  ) {
    this.path = path
  }

  // 懒加载:首次查询/写操作前读盘;损坏(JSON 解析失败)备份原文件后
  // 重置为空索引(fail soft:映射文件不是真相源,会话可在 server 侧重建)。
  load(): void {
    if (this.loaded) return
    this.loaded = true
    if (!existsSync(this.path)) return
    try {
      const raw = JSON.parse(readFileSync(this.path, "utf8")) as { mappings?: Record<string, MappingEntry> }
      for (const [convId, entry] of Object.entries(raw.mappings ?? {})) {
        const full = { ...entry, conversationId: convId }
        this.byConv.set(convId, full)
        this.bySess.set(full.sessionId, full)
      }
    } catch {
      // 损坏备份(带时间戳后缀),索引保持空
      copyFileSync(this.path, `${this.path}.corrupt.${Date.now()}`)
    }
  }

  bySession(sessionId: string): string | undefined {
    this.load()
    return this.bySess.get(sessionId)?.conversationId
  }

  byConversation(convId: string): string | undefined {
    this.load()
    return this.byConv.get(convId)?.sessionId
  }

  /** 查映射,miss 时建会话并落盘(已知 session 幂等直接返回;并发防重由
   * createConversation 实现方保证)。createConversation 返回 undefined 视为放弃。 */
  async ensureConversation(
    sessionId: string,
    opts: { title: string; ownerUserId?: string; directory?: string },
  ): Promise<string | undefined> {
    this.load()
    const known = this.bySess.get(sessionId)
    if (known !== undefined) return known.conversationId
    const convId = await this.createConversation(sessionId, opts)
    if (convId === undefined) return undefined
    const entry = { conversationId: convId, sessionId, createdAt: new Date().toISOString() }
    this.byConv.set(convId, entry)
    this.bySess.set(sessionId, entry)
    this.save()
    return convId
  }

  remove(sessionId: string): void {
    this.load()
    const entry = this.bySess.get(sessionId)
    if (entry === undefined) return
    this.bySess.delete(sessionId)
    this.byConv.delete(entry.conversationId)
    this.save()
  }

  // 原子写:先写 tmp 再 rename,读方不会看到半截 JSON。
  private save(): void {
    const mappings: Record<string, { sessionId: string; createdAt: string }> = {}
    for (const [convId, e] of this.byConv) mappings[convId] = { sessionId: e.sessionId, createdAt: e.createdAt }
    mkdirSync(dirname(this.path), { recursive: true })
    const tmp = `${this.path}.tmp`
    writeFileSync(tmp, JSON.stringify({ version: 1, mappings }, null, 2))
    renameSync(tmp, this.path)
  }
}
