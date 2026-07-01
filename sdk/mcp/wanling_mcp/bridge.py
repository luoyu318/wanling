"""Bridge — 持有 SDK WanlingAgentClient，桥接 WS 事件到本地 store。"""

from __future__ import annotations

import asyncio
import logging

from wanling import WanlingAgentClient

from wanling_mcp.store import MessageStore

logger = logging.getLogger("wanling.mcp.bridge")


class Bridge:
    """SDK + Store 的组合体，MCP tools 通过它调 SDK。

    后台自动连接 WS 并处理重连。tools 调用时若 WS 未连接会返回错误。
    """

    def __init__(self, agent_id: str, secret_key: str,
                 base_url: str = "http://localhost:18008"):
        self.sdk = WanlingAgentClient(agent_id, secret_key, base_url)
        self.store = MessageStore()
        self.sdk.on_dispatch = self.store.on_dispatch
        self._connected = False

    async def run(self) -> None:
        """后台运行：连接 WS + 断线自动重连。"""
        while True:
            try:
                await self.sdk.connect()
                self._connected = True
                logger.info("Bridge WS 已连接")
                # read_loop 返回即表示连接断开
                await self._wait_disconnect()
            except Exception as exc:
                logger.warning("Bridge 连接失败: %s，3 秒后重连", exc)
            finally:
                self._connected = False
            await asyncio.sleep(3)

    async def _wait_disconnect(self) -> None:
        """等待 WS 断开（阻塞直到连接断开）。"""
        # WanlingWS 的 _read_loop 会在连接断开时退出，
        # 但 task 被 cancel/except 后没有事件通知外部。
        # 简便方案：周期性检查任务是否存活。
        while True:
            await asyncio.sleep(5)
            # 检查 read_loop 是否还在运行
            for task in getattr(self.sdk.ws, "_tasks", []):
                if task.done():
                    exc = task.exception()
                    if exc:
                        logger.warning("WS 任务异常: %s", exc)
                    return

    async def stop(self) -> None:
        await self.sdk.close()

    @property
    def connected(self) -> bool:
        return self._connected

    async def ensure_connected(self) -> None:
        """确保 WS 已连接，否则抛错。tools 调用前检查。"""
        if not self._connected:
            raise RuntimeError("万灵 WS 未连接，请稍后重试")
