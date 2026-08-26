"""流式输出会话(与 TS stream_session.ts 对称)。

首帧立即、后续按 throttle_ms 节流、尾部定时器兜底 flush。每帧发累积全量
快照(协议语义:APP 按 stream_id 定位占位后整体替换 text,非增量拼接)。
终态消息由调用方发(带 _stream_id,APP 同位替换占位);end 前 flush 余量,
abort 丢弃缓冲。
"""

from __future__ import annotations

import asyncio
import math
import uuid
from collections.abc import Callable
from typing import Any

# 流式帧 wire 载荷:op=14 绕过 dispatchBuffer,不落库/不计未读/不补发;
# aggregate 定位字段展开为 snake_case(APP _applyAggregateStreamUpdate 消费)
StreamSendFn = Callable[[str, dict[str, Any]], None]


class StreamSession:
    def __init__(self, conv_id: str, send: StreamSendFn, opts: dict[str, Any] | None = None) -> None:
        self.stream_id = str(uuid.uuid4())
        self._conv_id = conv_id
        self._send = send
        self._opts: dict[str, Any] = dict(opts or {})
        # 累积文本(全量快照源)
        self._text = ""
        # 上次已发出的快照,相同内容不重复发
        self._last_flushed = ""
        self._last_flush = -math.inf
        self._timer: asyncio.TimerHandle | None = None
        self._closed = False

    def push(self, delta: str) -> None:
        """增量 push:距上次 flush 满 throttle_ms 立即发,否则挂兜底定时器。"""
        if self._closed:
            return
        self._text += delta
        loop = asyncio.get_running_loop()
        now = loop.time()
        throttle_s = self._opts.get("throttle_ms", 300) / 1000
        if now - self._last_flush >= throttle_s:
            self._flush(loop)
            return
        if self._timer is None:
            # 兜底延迟取节流间隔与尾部窗口的较小者:既不超一个节流周期,
            # 也不超尾部静默窗(tail_ms 调小可收紧尾部延迟)
            delay = min(throttle_s, self._opts.get("tail_ms", 500) / 1000)
            self._timer = loop.call_later(delay, self._on_tail_timer)

    def _on_tail_timer(self) -> None:
        self._timer = None
        self._flush(asyncio.get_running_loop())

    async def end(self, final_text: str) -> None:
        """终态:清兜底定时器并 flush 余量;终态消息由调用方随 MESSAGE_CREATE
        带 _stream_id(APP 替换占位),final_text 不经流式通道发送。"""
        if self._closed:
            return
        self._closed = True
        self._cancel_timer()
        self._flush(asyncio.get_running_loop())

    def abort(self) -> None:
        """中止:丢弃缓冲,不再发帧。"""
        self._closed = True
        self._cancel_timer()

    def _cancel_timer(self) -> None:
        if self._timer is not None:
            self._timer.cancel()
            self._timer = None

    def _flush(self, loop: asyncio.AbstractEventLoop) -> None:
        if self._text == self._last_flushed:
            return
        self._last_flush = loop.time()
        self._last_flushed = self._text
        frame: dict[str, Any] = {
            "stream_id": self.stream_id,
            "msg_type": self._opts.get("msg_type", "text"),
            "text": self._text,
        }
        agg = self._opts.get("aggregate")
        if agg is not None:
            frame["aggregate"] = {"message_id": agg["message_id"], "element_id": agg["element_id"]}
        self._send(self._conv_id, frame)
