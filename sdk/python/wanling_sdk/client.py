"""WanlingClient:连接生命周期 + 事件分发 + 发送/上报能力(与 TS client.ts 语义对齐)。"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import random
from collections import defaultdict
from collections.abc import Callable
from typing import Any

import websockets

from .opcodes import (
    EVENT_AGENT_MODELS,
    EVENT_AGENT_MODES,
    EVENT_AGENT_OFFLINE,
    EVENT_AGENT_ONLINE,
    EVENT_AGENT_PRESETS,
    EVENT_AGENT_SLASH_CATALOG,
    EVENT_APPROVAL_DECIDED,
    EVENT_APPROVAL_EXPIRED,
    EVENT_CONVERSATION_PARTICIPANT_JOIN,
    EVENT_CONVERSATION_PARTICIPANT_LEAVE,
    EVENT_CONVERSATION_UPDATE,
    EVENT_GENERATION_ABORT,
    EVENT_MESSAGE_CREATE,
    EVENT_MESSAGE_DELETE,
    EVENT_MESSAGE_READ,
    EVENT_MESSAGE_UPDATE,
    EVENT_PLUGIN_CAPABILITIES,
    EVENT_SESSION_META_UPDATE,
    EVENT_TYPING_START,
    OP_DISPATCH,
    OP_HEARTBEAT,
    OP_HEARTBEAT_ACK,
    OP_HELLO,
    OP_IDENTIFY,
    OP_PLUGIN_CALL,
    OP_PLUGIN_RESULT,
    OP_RECONNECT,
    OP_RESUME,
    OP_STREAM,
)
from .rest import WanlingRestClient
from .rpc import RPCDispatcher

logger = logging.getLogger(__name__)


def _ws_url(server_url: str) -> str:
    base = server_url.rstrip("/")
    if base.startswith("https://"):
        return base.replace("https://", "wss://", 1) + "/ws"
    return base.replace("http://", "ws://", 1) + "/ws"


def _decode_jwt_exp(token: str) -> int | None:
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        data = json.loads(base64.urlsafe_b64decode(payload))
        exp = data.get("exp")
        return int(exp) if isinstance(exp, (int, float)) else None
    except Exception:  # noqa: BLE001 - 非 JWT/损坏 token 一律视为无过期时间
        return None


class WanlingClient:
    def __init__(
        self,
        server_url: str,
        agent_id: str,
        secret_key: str,
        ws_connect_timeout: float = 15.0,
        request_timeout: float = 10.0,
    ) -> None:
        self.server_url = server_url
        self.agent_id = agent_id
        self.secret_key = secret_key
        self.ws_connect_timeout = ws_connect_timeout
        self.request_timeout = request_timeout
        self._listeners: defaultdict[str, list[Callable]] = defaultdict(list)
        self._token: str | None = None
        self._ws = None
        self._last_seq = 0
        self._stopping = False
        self._heartbeat_task: asyncio.Task | None = None
        self._receive_task: asyncio.Task | None = None
        self._refresh_task: asyncio.Task | None = None
        self.dispatcher = RPCDispatcher()
        self.rest = WanlingRestClient(server_url, self.get_token)

    def on(self, event: str, callback: Callable) -> None:
        self._listeners[event].append(callback)

    async def _emit(self, event: str, *args: Any) -> None:
        for cb in self._listeners.get(event, []):
            res = cb(*args)
            if asyncio.iscoroutine(res):
                await res

    async def get_token(self) -> str:
        if not self._token:
            raise RuntimeError("client not started")
        return self._token

    async def _exchange_token(self) -> str:
        import urllib.request

        url = f"{self.server_url.rstrip('/')}/api/agents/{self.agent_id}/token"
        body = json.dumps({"agent_id": self.agent_id, "secret_key": self.secret_key}).encode()
        req = urllib.request.Request(
            url,
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            resp = await asyncio.to_thread(
                urllib.request.urlopen, req, timeout=self.request_timeout
            )
        except Exception as e:
            raise RuntimeError(f"token exchange failed: {e}") from e
        data = json.loads(resp.read())
        token = data.get("data", {}).get("token") if data.get("ok") else None
        if not token:
            raise RuntimeError("token exchange: invalid response")
        return token

    async def start(self) -> None:
        if not self.agent_id or not self.secret_key:
            raise ValueError("agent_id and secret_key must be configured")
        self._stopping = False
        self._receive_task = asyncio.create_task(self._receive_loop())
        self._refresh_task = asyncio.create_task(self._token_refresh_loop())

    async def stop(self) -> None:
        self._stopping = True
        for task in (self._heartbeat_task, self._refresh_task, self._receive_task):
            if task and not task.done():
                task.cancel()
        if self._ws is not None:
            try:
                await self._ws.close()
            except Exception:  # noqa: S110, BLE001 - 关闭阶段忽略 WS 关闭异常
                pass

    async def _token_refresh_loop(self) -> None:
        """每 60 秒检查一次 agent token 剩余 TTL,剩 <1h 时提前换新。"""
        import time

        while not self._stopping:
            await asyncio.sleep(60)
            if not self._token:
                continue
            exp = _decode_jwt_exp(self._token)
            if exp is None:
                continue
            if exp - time.time() < 3600:
                try:
                    self._token = await self._exchange_token()
                    logger.info("token refreshed")
                except Exception as e:  # noqa: BLE001 - 刷新失败降级为日志,循环续跑
                    logger.warning("token refresh failed: %s", e)

    async def _cleanup_ws(self) -> None:
        if self._heartbeat_task and not self._heartbeat_task.done():
            self._heartbeat_task.cancel()
            self._heartbeat_task = None
        if self._ws is not None:
            try:
                await self._ws.close()
            except Exception:  # noqa: S110, BLE001 - 关闭阶段忽略 WS 关闭异常
                pass
            self._ws = None

    async def _establish_ws(self) -> int:
        try:
            self._token = await self._exchange_token()
            self._ws = await asyncio.wait_for(
                websockets.connect(_ws_url(self.server_url)),
                timeout=self.ws_connect_timeout,
            )
            hello_raw = await asyncio.wait_for(self._ws.recv(), timeout=10)
            hello = json.loads(hello_raw)
            if hello.get("op") != OP_HELLO:
                raise RuntimeError(f"expected Hello (op=10), got {hello}")
            await self._ws.send(json.dumps({"op": OP_IDENTIFY, "d": {"token": self._token}}))
            if self._last_seq > 0:
                await self._ws.send(json.dumps({"op": OP_RESUME, "d": {"last_seq": self._last_seq}}))
            return hello.get("d", {}).get("heartbeat_interval", 30000)
        except Exception:
            await self._cleanup_ws()
            raise

    async def _heartbeat_loop(self, interval_s: float) -> None:
        while True:
            try:
                await asyncio.sleep(interval_s)
                if self._ws is not None:
                    await self._ws.send(json.dumps({"op": OP_HEARTBEAT}))
            except asyncio.CancelledError:
                return
            except Exception as e:  # noqa: BLE001 - 心跳失败关 WS 触发重连
                logger.warning("heartbeat failed — %s, closing WS", e)
                try:
                    if self._ws is not None:
                        await self._ws.close()
                except Exception:  # noqa: S110, BLE001 - 关闭异常忽略
                    pass
                return

    async def _receive_loop(self) -> None:
        backoff = 1.0
        while not self._stopping:
            try:
                interval_ms = await self._establish_ws()
                backoff = 1.0
                await self._emit("connected")
                if self._heartbeat_task and not self._heartbeat_task.done():
                    self._heartbeat_task.cancel()
                self._heartbeat_task = asyncio.create_task(
                    self._heartbeat_loop(interval_ms / 1000)
                )
                async for raw in self._ws:
                    try:
                        msg = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    await self._handle_message(msg)
                raise ConnectionError("WS closed by peer")
            except asyncio.CancelledError:
                return
            except Exception as e:  # noqa: BLE001 - 兜底进入重连退避,不抛到外层
                if self._stopping:
                    return
                logger.warning("receive loop ended — %s (reconnect in %.1fs)", e, backoff)
                await self._cleanup_ws()
                await self._emit("disconnected")
                jitter = backoff * 0.2 * random.random()
                await asyncio.sleep(backoff + jitter)
                backoff = min(backoff * 2, 30.0)

    async def _handle_message(self, msg: dict[str, Any]) -> None:
        op = msg.get("op")
        if op == OP_HEARTBEAT_ACK:
            return
        if op == OP_RECONNECT:
            try:
                if self._ws is not None:
                    await self._ws.close()
            except Exception:  # noqa: S110, BLE001 - 关闭异常忽略,由重连接管
                pass
            return
        if op == OP_DISPATCH:
            s = msg.get("s")
            if isinstance(s, int) and s > self._last_seq:
                self._last_seq = s
            t = msg.get("t")
            d = msg.get("d", {})
            mapping = {
                EVENT_MESSAGE_CREATE: "message",
                EVENT_MESSAGE_UPDATE: "message.update",
                EVENT_MESSAGE_DELETE: "message.delete",
                EVENT_MESSAGE_READ: "message.read",
                EVENT_TYPING_START: "typing",
                EVENT_GENERATION_ABORT: "abort",
                EVENT_CONVERSATION_UPDATE: "conv_update",
                EVENT_CONVERSATION_PARTICIPANT_JOIN: "conv.participant.join",
                EVENT_CONVERSATION_PARTICIPANT_LEAVE: "conv.participant.leave",
                EVENT_SESSION_META_UPDATE: "session.meta.update",
                EVENT_AGENT_ONLINE: "agent.online",
                EVENT_AGENT_OFFLINE: "agent.offline",
                EVENT_APPROVAL_DECIDED: "approval.decided",
                EVENT_APPROVAL_EXPIRED: "approval.expired",
            }
            event = mapping.get(t)
            if event:
                await self._emit(event, d)
            return
        if op == OP_PLUGIN_CALL:
            resp = await self.dispatcher.dispatch(msg.get("d") or {})
            if self._ws is not None:
                await self._ws.send(json.dumps({"op": OP_PLUGIN_RESULT, "d": resp}))
            return

    async def _send_dispatch(self, t: str, d: dict[str, Any]) -> None:
        if self._ws is None:
            raise RuntimeError("WS not connected")
        await self._ws.send(json.dumps({"op": OP_DISPATCH, "t": t, "d": d}))

    async def send(self, conversation_id: str, content: dict) -> None:
        await self._send_dispatch(EVENT_MESSAGE_CREATE, {"conversation_id": conversation_id, "content": content})

    async def send_typed(
        self,
        conversation_id: str,
        msg_type: str,
        data: dict,
        *,
        silent: bool = False,
        parent_msg_id: str | None = None,
        root_msg_id: str | None = None,
    ) -> None:
        content: dict[str, Any] = {"msg_type": msg_type, "data": data}
        if silent:
            content["silent"] = True
        if parent_msg_id:
            content["parent_msg_id"] = parent_msg_id
        if root_msg_id:
            content["root_msg_id"] = root_msg_id
        await self.send(conversation_id, content)

    async def send_stream(self, conversation_id: str, stream_id: str, msg_type: str, text: str) -> None:
        if self._ws is None:
            return
        await self._ws.send(
            json.dumps({
                "op": OP_STREAM,
                "d": {"conversation_id": conversation_id, "stream_id": stream_id, "msg_type": msg_type, "text": text},
            })
        )

    async def send_typing(self, conversation_id: str) -> None:
        if self._ws is None:
            return
        await self._ws.send(json.dumps({"op": OP_DISPATCH, "t": EVENT_TYPING_START, "d": {"conversation_id": conversation_id}}))

    def _now_iso(self) -> str:
        import datetime

        return datetime.datetime.now(datetime.timezone.utc).isoformat()

    async def report_models(self, models: list[dict]) -> None:
        if self._ws is None:
            logger.warning("report_models: WS 未连接,跳过上报")
            return
        await self._send_dispatch(EVENT_AGENT_MODELS, {"agent_id": self.agent_id, "models": models, "reported_at": self._now_iso()})

    async def report_slash_catalog(self, commands: list[dict]) -> None:
        if self._ws is None:
            logger.warning("report_slash_catalog: WS 未连接,跳过上报")
            return
        await self._send_dispatch(EVENT_AGENT_SLASH_CATALOG, {"agent_id": self.agent_id, "commands": commands, "reported_at": self._now_iso()})

    async def report_capabilities(self, methods: list[dict]) -> None:
        if self._ws is None:
            logger.warning("report_capabilities: WS 未连接,跳过上报")
            return
        await self._send_dispatch(EVENT_PLUGIN_CAPABILITIES, {"agent_id": self.agent_id, "methods": methods, "reported_at": self._now_iso()})

    async def report_modes(self, modes: list[dict]) -> None:
        """上报 agent 模式清单(能力上报管线第四成员)。

        server 写 ModeRegistry 内存缓存,APP 渲染模式色条按 session-meta
        mode id 查清单取 label/style。style 为受控渲染档位:
        "default" | "plan" | "warn"。
        """
        if self._ws is None:
            logger.warning("report_modes: WS 未连接,跳过上报")
            return
        await self._send_dispatch(EVENT_AGENT_MODES, {"agent_id": self.agent_id, "modes": modes, "reported_at": self._now_iso()})

    async def report_presets(self, presets: list[dict]) -> None:
        """上报 agent 预设清单(能力上报管线第五成员)。

        预设是 per-session 能力组合,集合开放(user 可自创)。
        trust 区分 "system"(部署内置)/"user"(用户自创);无预设
        概念的 plugin 不调用本方法即可(APP 据空清单隐藏选择步骤)。
        """
        if self._ws is None:
            logger.warning("report_presets: WS 未连接,跳过上报")
            return
        await self._send_dispatch(EVENT_AGENT_PRESETS, {"agent_id": self.agent_id, "presets": presets, "reported_at": self._now_iso()})

    def register_method(self, name: str, handler: Callable, timeout_hint_ms: int = 5000) -> None:
        self.dispatcher.register(name, handler, timeout_hint_ms)
