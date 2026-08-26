export interface StreamSessionOptions {
  /** 聚合模式定位(卡内流式元素);独立流式占位省略。 */
  aggregate?: { messageId: string; elementId: string }
  /** 节流间隔,默认 300ms(对齐 opencode 实测)。 */
  throttleMs?: number
  /** 尾部兜底静默窗口,默认 500ms(与节流间隔取小者为兜底定时器延迟)。 */
  tailMs?: number
  /** 流式帧 msg_type,默认 "text"(APP 仅放行 reasoning/markdown/text)。 */
  msgType?: string
}

// 流式帧 wire 载荷:op=14 绕过 dispatchBuffer,不落库/不计未读/不补发;
// text 为累积全量快照(APP 同位置 copyWith 替换,非增量拼接);
// aggregate 定位字段展开为 snake_case(APP _applyAggregateStreamUpdate 消费)。
interface StreamFrame {
  stream_id: string
  msg_type: string
  text: string
  aggregate?: { message_id: string; element_id: string }
}

/**
 * 流式输出会话:首帧立即、后续按 throttleMs 节流、尾部定时器兜底 flush。
 * 每帧发累积全量快照(协议语义:APP 按 stream_id 定位占位后整体替换 text)。
 * 终态消息由调用方发(带 _stream_id: streamId,APP 同位替换占位);
 * end 前 flush 余量,abort 丢弃缓冲。
 */
export class StreamSession {
  readonly streamId = crypto.randomUUID()
  // 累积文本(全量快照源)
  private text = ""
  // 上次已发出的快照,相同内容不重复发
  private lastFlushed = ""
  private lastFlush = 0
  private timer: ReturnType<typeof setTimeout> | null = null
  private closed = false

  constructor(
    private readonly convId: string,
    private readonly send: (convId: string, frame: StreamFrame) => void,
    private readonly opts: StreamSessionOptions = {},
  ) {}

  /** 增量 push:距上次 flush 满 throttleMs 立即发,否则挂兜底定时器。 */
  push(delta: string): void {
    if (this.closed) return
    this.text += delta
    const now = Date.now()
    const throttleMs = this.opts.throttleMs ?? 300
    if (now - this.lastFlush >= throttleMs) {
      this.flush()
      return
    }
    if (this.timer === null) {
      // 兜底延迟取节流间隔与尾部窗口的较小者:既不超一个节流周期,
      // 也不超尾部静默窗(tailMs 调小可收紧尾部延迟)
      const delay = Math.min(throttleMs, this.opts.tailMs ?? 500)
      this.timer = setTimeout(() => {
        this.timer = null
        this.flush()
      }, delay)
    }
  }

  /** 终态:清兜底定时器并 flush 余量;终态消息由调用方随 MESSAGE_CREATE 带
   * _stream_id(APP 替换占位),finalText 不经流式通道发送。 */
  async end(finalText: string): Promise<void> {
    if (this.closed) return
    this.closed = true
    if (this.timer !== null) {
      clearTimeout(this.timer)
      this.timer = null
    }
    this.flush()
    void finalText
  }

  /** 中止:丢弃缓冲,不再发帧。 */
  abort(): void {
    this.closed = true
    if (this.timer !== null) {
      clearTimeout(this.timer)
      this.timer = null
    }
  }

  private flush(): void {
    if (this.text === this.lastFlushed) return
    this.lastFlush = Date.now()
    this.lastFlushed = this.text
    const agg = this.opts.aggregate
    this.send(this.convId, {
      stream_id: this.streamId,
      msg_type: this.opts.msgType ?? "text",
      text: this.text,
      ...(agg !== undefined ? { aggregate: { message_id: agg.messageId, element_id: agg.elementId } } : {}),
    })
  }
}
