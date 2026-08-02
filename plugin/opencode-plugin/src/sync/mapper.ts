import { readFileSync, writeFileSync, existsSync, mkdirSync, copyFileSync } from "fs"
import { join } from "path"
import { configDir } from "../config.js"

export interface SessionMap {
  wanlingConvId: string
  opencodeSessionId: string
  lastSyncAt: string
  messageCount: number
}

interface Store {
  maps: SessionMap[]
}

const STORE_PATH = join(configDir(), "session-maps.json")

let cache: Store | null = null

function loadStore(): Store {
  if (cache) return cache
  try {
    if (existsSync(STORE_PATH)) {
      cache = JSON.parse(readFileSync(STORE_PATH, "utf-8"))
      return cache as Store
    }
  } catch (err) {
    const backup = `${STORE_PATH}.corrupt.${Date.now()}`
    try { copyFileSync(STORE_PATH, backup) } catch { /* 备份失败不阻断重置 */ }
    console.warn(`[mapper] session-maps.json 解析失败，已备份到 ${backup}，重置为空: ${err}`)
  }
  cache = { maps: [] }
  return cache
}

function saveStore(): void {
  mkdirSync(configDir(), { recursive: true })
  writeFileSync(STORE_PATH, JSON.stringify(cache, null, 2), "utf-8")
}

export function getSessionMap(wanlingConvId: string): SessionMap | undefined {
  return loadStore().maps.find((m) => m.wanlingConvId === wanlingConvId)
}

export function findBySessionId(opencodeSessionId: string): SessionMap | undefined {
  const matches = loadStore().maps.filter((m) => m.opencodeSessionId === opencodeSessionId)
  if (matches.length === 0) return undefined
  if (matches.length === 1) return matches[0]
  // 多个同 session 映射（重配后残留）：返回最新的，清理旧的
  matches.sort((a, b) => b.lastSyncAt.localeCompare(a.lastSyncAt))
  cleanupMaps(matches.slice(1).map((m) => m.wanlingConvId))
  return matches[0]
}

function cleanupMaps(convIds: string[]): void {
  const store = loadStore()
  store.maps = store.maps.filter((m) => !convIds.includes(m.wanlingConvId))
  saveStore()
}

export function upsertSessionMap(map: SessionMap): void {
  const store = loadStore()
  const idx = store.maps.findIndex((m) => m.wanlingConvId === map.wanlingConvId)
  if (idx >= 0) {
    store.maps[idx] = { ...store.maps[idx], ...map }
  } else {
    store.maps.push(map)
  }
  saveStore()
}

export function removeSessionMap(wanlingConvId: string): void {
  const store = loadStore()
  store.maps = store.maps.filter((m) => m.wanlingConvId !== wanlingConvId)
  saveStore()
}

export function listSessionMaps(): SessionMap[] {
  return loadStore().maps
}

// pending TUI 消息:proxy 拦截到 prompt 但 session 映射未建(ensureConversation
// 还在 flight)时暂存,建群后 drain 补发,避免新 session 首条消息丢失。
// 仅存内存(进程重启丢弃,合理:pending 是极短窗口的 race 兜底,非持久态)。
const pendingTuiMessages = new Map<string, string[]>()

export function enqueuePendingTuiMessage(sessionId: string, text: string): void {
  const arr = pendingTuiMessages.get(sessionId) ?? []
  arr.push(text)
  pendingTuiMessages.set(sessionId, arr)
}

export function drainPendingTuiMessages(sessionId: string): string[] {
  const arr = pendingTuiMessages.get(sessionId)
  pendingTuiMessages.delete(sessionId)
  return arr ?? []
}
