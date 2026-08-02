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
