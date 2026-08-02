type LogLevel = "debug" | "info" | "warn" | "error" | "none"

const LEVEL_ORDER: Record<LogLevel, number> = {
  debug: 0,
  info: 1,
  warn: 2,
  error: 3,
  none: 4,
}

function resolveLevel(): LogLevel {
  const env = process.env.WANLING_LOG_LEVEL?.toLowerCase()
  if (env && env in LEVEL_ORDER) return env as LogLevel
  return "info"
}

const activeLevel = resolveLevel()

function shouldLog(level: LogLevel): boolean {
  return LEVEL_ORDER[activeLevel] <= LEVEL_ORDER[level]
}

export const logger = {
  debug(msg: string, ...args: unknown[]): void {
    if (shouldLog("debug")) console.log(msg, ...args)
  },
  info(msg: string, ...args: unknown[]): void {
    if (shouldLog("info")) console.log(msg, ...args)
  },
  warn(msg: string, ...args: unknown[]): void {
    if (shouldLog("warn")) console.warn(msg, ...args)
  },
  error(msg: string, ...args: unknown[]): void {
    if (shouldLog("error")) console.error(msg, ...args)
  },
}
