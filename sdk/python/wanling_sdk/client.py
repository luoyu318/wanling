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

from .aggregate_card import AggregateCard
from .approvals import Approvals
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
from .session_mapping import SessionMapping
from .stream_session import StreamSession

logger = logging.getLogger(__name__)


class _RestAggregateIO:
    """聚合卡 io 适配器:rest 四方法包一层(client.aggregate 工厂用)。"""

    def __init__(self, rest: WanlingRestClient, conv_id: str) -> None:
        self._rest = rest
        self._conv_id = conv_id

    async def send_card(self, data: dict) -> str:
        # 建卡 silent=True:回合进行中不打扰,计未读由 finish 翻转 set_silent 承接
        return await self._rest.send_card_message(self._conv_id, data["msg_type"], data["data"], True)

    async def patch(self, message_id: str, op: dict) -> None:
        await self._rest.patch_aggregate_message(message_id, op)

    async def update_content(self, message_id: str, content: dict) -> None:
        await self._rest.update_message_content(message_id, content)

    async def recall(self, message_id: str) -> None:
        await self._rest.recall_message(message_id)


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
        # 审批/提问高层封装(ask 发卡等决策)。构造时挂事件监听(self.on 不依赖
        # WS 状态,挂一次即可,重连不重复挂),断线重连后 resync 主动兜底未决项
        self.approvals = Approvals(
            self.rest.create_approval,
            self.rest.get_approval,
            self.on,
            lambda msg: logger.info("[wanling] %s", msg),
        )

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
                # 重连后未决审批可能错过 WS 推送,REST 兜底查询一次
                # (首次连接 pending 为空,空跑无害)
                asyncio.create_task(self._resync_approvals())
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

    async def send_stream(
        self,
        conversation_id: str,
        stream_id: str,
        msg_type: str,
        text: str,
        aggregate: dict | None = None,
    ) -> None:
        """op=14 流式帧(累积全量快照,不落库/不计未读/不补发)。

        aggregate 定位(聚合模式卡内元素流式)展开为 snake_case,
        APP 定位 aggregate_card 消息内 element_id 匹配元素整体替换 data.text。
        WS 未连接时静默丢弃(流式为瞬态,终态消息兜底)。
        """
        if self._ws is None:
            return
        d: dict[str, Any] = {
            "conversation_id": conversation_id,
            "stream_id": stream_id,
            "msg_type": msg_type,
            "text": text,
        }
        if aggregate is not None:
            d["aggregate"] = aggregate
        await self._ws.send(json.dumps({"op": OP_STREAM, "d": d}))

    async def send_typing(self, conversation_id: str) -> None:
        if self._ws is None:
            return
        await self._ws.send(json.dumps({"op": OP_DISPATCH, "t": EVENT_TYPING_START, "d": {"conversation_id": conversation_id}}))

    def _now_iso(self) -> str:
        import datetime

        return datetime.datetime.now(datetime.timezone.utc).isoformat()

    async def _resync_approvals(self) -> None:
        """重连后审批兜底查询(失败仅记日志,不影响连接循环)。"""
        try:
            await self.approvals.resync()
        except Exception as e:  # noqa: BLE001 - 兜底查询失败不影响连接循环
            logger.warning("approvals resync failed: %s", e)

    def aggregate(self, conv_id: str, opts: dict | None = None) -> AggregateCard:
        """聚合卡工厂:一次问答一张卡(append/update/finish/interrupt)。"""
        return AggregateCard(conv_id, _RestAggregateIO(self.rest, conv_id), opts)

    def stream(self, conv_id: str, opts: dict | None = None) -> StreamSession:
        """流式会话工厂:首帧立即 + 节流 + 兜底 flush,终态消息由调用方带 _stream_id 发。"""

        def _send(cid: str, frame: dict) -> None:
            # fire-and-forget,对齐 TS sendStream 同步 void 语义;done-callback
            # 记录异常(对齐 _resync_approvals 兜底记日志风格,防后台 task
            # 异常无人接触发 "Task exception was never retrieved" 静默丢错)
            task = asyncio.ensure_future(
                self.send_stream(cid, frame["stream_id"], frame["msg_type"], frame["text"], frame.get("aggregate"))
            )

            def _log_failure(t: asyncio.Task) -> None:
                if t.cancelled():
                    return
                exc = t.exception()
                if exc is not None:
                    logger.warning("stream send failed: %s", exc)

            task.add_done_callback(_log_failure)

        return StreamSession(conv_id, _send, opts)

    def session_mapping(self, path: str, owner_user_id: str | None = None) -> SessionMapping:
        """会话映射工厂:外部 session ↔ conversation 持久映射(miss 时建 agent_session 群)。

        owner_user_id 可在工厂注入或 ensure_conversation 时传入(server 强制
        user_id 必须是 agent 的 owner,缺失时 fail fast 不发请求)。
        """
        factory_owner = owner_user_id

        async def _create_conversation(_session_id: str, o: dict) -> str | None:
            owner = o.get("owner_user_id") or factory_owner
            if not owner:
                raise RuntimeError("session_mapping 需要 owner_user_id(工厂参数或 ensure_conversation 参数提供)")
            return await self.rest.create_group_as_agent(owner, "agent_session", o["title"], o.get("directory"))

        return SessionMapping(path, _create_conversation)

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
