"""WebSocket 状态机 — Hello→Identify→Heartbeat→Resume + 事件分发。

参考 send_test_message.py 和 server/handler/ws_handler.go。
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Callable
from typing import Any

import websockets
from websockets.asyncio.client import ClientConnection
from websockets.exceptions import ConnectionClosed, WebSocketException

from wanling.types import OpCode, EventType

logger = logging.getLogger("wanling.ws")

DispatchCallback = Callable[[str, dict[str, Any]], None]


class WanlingWS:
    """WebSocket 客户端（agent 侧）。

    用法:
        ws = WanlingWS("http://localhost:18008", "jwt-token")
        ws.on_dispatch = lambda event_type, payload: print(event_type, payload)
        await ws.connect()
        await ws.send_message("conv_xxx", "hello")
        await ws.close()
    """

    def __init__(self, base_url: str, token: str):
        ws_base = base_url.replace("http://", "ws://").replace("https://", "wss://").rstrip("/")
        self._url = f"{ws_base}/ws"
        self._token = token
        self._conn: ClientConnection | None = None
        self._seq: int = 0
        self._heartbeat_interval: int = 30000  # 默认 30s
        self.on_dispatch: DispatchCallback | None = None

        self._stop = asyncio.Event()

    # ── public ──

    async def connect(self) -> None:
        """建立 WS 连接，完成 Hello→Identify 握手，启动心跳。"""
        self._stop.clear()
        self._conn = await websockets.connect(self._url)

        # 1. 等 Hello
        raw = await asyncio.wait_for(self._conn.recv(), timeout=10)
        hello = json.loads(raw)
        if hello.get("op") != OpCode.HELLO:
            await self._conn.close()
            raise RuntimeError(f"期望 Hello (op=10)，收到: {hello}")
        self._heartbeat_interval = hello.get("d", {}).get("heartbeat_interval", 30000)
        logger.info("Hello 完成，心跳间隔 %d ms", self._heartbeat_interval)

        # 2. 发 Identify
        await self._send_raw({"op": OpCode.IDENTIFY, "d": {"token": self._token}})
        logger.info("Identify 已发送")

        # 3. 启动后台任务
        self._tasks = [
            asyncio.create_task(self._heartbeat_loop()),
            asyncio.create_task(self._read_loop()),
        ]

        # 4. 等一小段让服务端 Register
        await asyncio.sleep(0.1)

    async def close(self) -> None:
        """关闭连接和后台任务。"""
        self._stop.set()
        for t in getattr(self, "_tasks", []):
            t.cancel()
        if self._conn:
            await self._conn.close()
            self._conn = None

    async def send_message(self, user_id: str, text: str) -> None:
        """通过 WS 发一条 MESSAGE_CREATE（op=0, t=MESSAGE_CREATE）。

        user_id 是目标用户的 ID。服务端 agent 路径从 payload.user_id 取对端。"""
        await self._send_raw({
            "op": OpCode.DISPATCH,
            "t": EventType.MESSAGE_CREATE,
            "d": {
                "user_id": user_id,
                "content": {"msg_type": "text", "data": {"text": text}},
            },
        })

    # ── internal ──

    async def _send_raw(self, msg: dict[str, Any]) -> None:
        if not self._conn:
            raise RuntimeError("WS 未连接")
        await self._conn.send(json.dumps(msg))

    async def _heartbeat_loop(self) -> None:
        """后台心跳，断开时静默退出。"""
        while not self._stop.is_set():
            try:
                await asyncio.sleep(self._heartbeat_interval / 1000)
                await self._send_raw({"op": OpCode.HEARTBEAT})
            except (ConnectionClosed, WebSocketException):
                return
            except asyncio.CancelledError:
                return

    async def _read_loop(self) -> None:
        """读取服务端推送，分发给 on_dispatch。"""
        while not self._stop.is_set():
            try:
                raw = await self._conn.recv()
            except (ConnectionClosed, WebSocketException):
                logger.info("WS 连接断开")
                break
            except asyncio.CancelledError:
                break

            try:
                msg = json.loads(raw)
            except json.JSONDecodeError:
                continue

            op = msg.get("op")

            if op == OpCode.DISPATCH:
                self._seq = msg.get("s", self._seq)
                event_type = msg.get("t", "")
                payload = msg.get("d", {})
                if isinstance(payload, str):
                    try:
                        payload = json.loads(payload)
                    except json.JSONDecodeError:
                        payload = {}
                if self.on_dispatch:
                    self.on_dispatch(event_type, payload)

            elif op == OpCode.HEARTBEAT_ACK:
                pass  # 心跳 ACK，静默

            elif op == OpCode.RECONNECT:
                logger.info("服务端要求重连 (op=7)")
                break

    @property
    def last_seq(self) -> int:
        return self._seq
