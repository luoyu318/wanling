import fs from "fs"
import path from "path"
import { configDir } from "../config.js"

export interface CardEntry {
  msgId: string
  convId: string
  type: "permission" | "question"
  directory?: string
  data?: Record<string, unknown>
  createdAt?: number
  // 聚合模式:交互卡嵌入聚合卡元素时,记录目标元素 element_id + 所属 sessionId,
  // 供反向流/孤儿清理在聚合卡 elements 里定位该元素(非聚合模式不设置)。
  elementId?: string
  sessionId?: string
}

const STORE_PATH = path.join(configDir(), "pending-cards.json")

let cache: Record<string, CardEntry> | null = null

function loadStore(): Record<string, CardEntry> {
  if (cache) return cache
  const dir = path.dirname(STORE_PATH)
  try {
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
    if (fs.existsSync(STORE_PATH)) {
      cache = JSON.parse(fs.readFileSync(STORE_PATH, "utf-8"))
      return cache as Record<string, CardEntry>
    }
  } catch (err) {
    console.warn(`[card_store] pending-cards.json 解析失败，重置为空: ${err}`)
  }
  cache = {}
  return cache
}

function persist(): void {
  if (!cache) return
  const dir = path.dirname(STORE_PATH)
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true })
  fs.writeFileSync(STORE_PATH, JSON.stringify(cache, null, 2))
}

export function saveCard(ocRequestId: string, entry: CardEntry): void {
  const store = loadStore()
  store[ocRequestId] = { ...entry, createdAt: entry.createdAt ?? Date.now() }
  persist()
}

export function getCard(ocRequestId: string): CardEntry | null {
  return loadStore()[ocRequestId] || null
}

export function deleteCard(ocRequestId: string): void {
  const store = loadStore()
  if (!(ocRequestId in store)) return
  delete store[ocRequestId]
  persist()
}

export function getAllCards(): Record<string, CardEntry> {
  return loadStore()
}

// 存活信号 S2:某 opencode session 是否有未决(permission/question)交互卡。
export function hasPendingCardForSession(sessionId: string): boolean {
  return Object.values(loadStore()).some((e) => e.sessionId === sessionId)
}
