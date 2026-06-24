"""
Wanling Platform Adapter for Hermes Agent.

Connects to an Wanling server (standard IM Bot-style WebSocket protocol over JWT):
  1. HTTP POST /api/agents/:id/token  with agent_id + secret_key → JWT token
  2. WebSocket connect /ws
  3. Receive Hello (op=10, contains heartbeat_interval)
  4. Send Identify (op=2, d={token})
  5. Periodic Heartbeat (op=1) every heartbeat_interval ms
  6. Receive Dispatch events (op=0): MESSAGE_CREATE / AGENT_ONLINE / ...

Outbound message (agent → user): WS send {op:0, t:'MESSAGE_CREATE', d:{user_id, content:{msg_type, data}}}
Inbound message (user → agent): received as {op:0, t:'MESSAGE_CREATE', d:{conversation_id, sender_type:'user', sender_id, content}}

Configuration in config.yaml::

    gateway:
      platforms:
        wanling:
          enabled: true
          extra:
            server_url: http://localhost:18008
            agent_id: <UUID>
            secret_key: <64-char hex>
            home_user: <UUID>          # optional, for cron delivery
            allowed_users: []          # empty = use allow_all flag

Or via environment variables (overrides config.yaml):
    WANLING_SERVER_URL, WANLING_AGENT_ID, WANLING_SECRET_KEY,
    WANLING_HOME_USER, WANLING_ALLOWED_USERS, WANLING_ALLOW_ALL_USERS
"""

import asyncio
import glob
import json
import logging
import os
import random
import re
import time
import urllib.request
import uuid
from datetime import datetime
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Lazy imports from Hermes core (avoid import errors during plugin discovery)
# ---------------------------------------------------------------------------
from gateway.platforms.base import (
    BasePlatformAdapter,
    MessageEvent,
    MessageType,
    SendResult,
    cache_image_from_url,
)
from gateway.config import Platform

# websockets is a Hermes runtime dependency (used by other adapters)
import websockets


# ---------------------------------------------------------------------------
# Protocol constants (mirror server/internal/model/opcodes.go)
# ---------------------------------------------------------------------------
OP_DISPATCH = 0
OP_HEARTBEAT = 1
OP_IDENTIFY = 2
OP_RESUME = 6
OP_RECONNECT = 7
OP_HELLO = 10
OP_HEARTBEAT_ACK = 11

EVENT_MESSAGE_CREATE = "MESSAGE_CREATE"
EVENT_APPROVAL_DECIDED = "APPROVAL_DECIDED"
EVENT_APPROVAL_EXPIRED = "APPROVAL_EXPIRED"

# 单文件上传大小上限（20MB），防止 agent 被诱导上传大文件 OOM。
# IM 场景图片通常 <5MB，20MB 给截图/扫描件留余量。
MAX_UPLOAD_SIZE = 20 * 1024 * 1024

# 入站文件下载缓存目录。跟 hermes 自己的 cache/images/ 同级，独立子目录避免污染。
# 文件名用 <file_id>.<ext> 保证幂等，LLM 可能反复读同一图片不重复下载。
DOWNLOAD_CACHE_DIR = os.path.expanduser("~/.hermes/cache/wanling_files")

# 单文件下载大小上限，跟上传对称。超限返回 None 触发降级 stub。
MAX_DOWNLOAD_SIZE = MAX_UPLOAD_SIZE


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
def _exchange_token(server_url: str, agent_id: str, secret_key: str) -> str:
    """HTTP POST /api/agents/:id/token → JWT token.

    Raises on failure (hermes gateway will retry connect() with backoff).
    """
    req = urllib.request.Request(
        f"{server_url.rstrip('/')}/api/agents/{agent_id}/token",
        data=json.dumps({"agent_id": agent_id, "secret_key": secret_key}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())["token"]


def _ws_url(server_url: str) -> str:
    """Convert http(s)://host to ws(s)://host/ws."""
    base = server_url.rstrip("/")
    if base.startswith("https://"):
        return base.replace("https://", "wss://", 1) + "/ws"
    return base.replace("http://", "ws://", 1) + "/ws"


# ---------------------------------------------------------------------------
# Adapter
# ---------------------------------------------------------------------------
class WanlingAdapter(BasePlatformAdapter):
    """Async Wanling adapter implementing the BasePlatformAdapter interface."""

    def __init__(self, config, **kwargs):
        platform = Platform("wanling")
        super().__init__(config=config, platform=platform)

        extra = getattr(config, "extra", {}) or {}

        # Connection settings
        self.server_url = (
            os.getenv("WANLING_SERVER_URL")
            or extra.get("server_url")
            or "http://localhost:18008"
        )
        self.agent_id = os.getenv("WANLING_AGENT_ID") or extra.get("agent_id", "")
        self.secret_key = os.getenv("WANLING_SECRET_KEY") or extra.get("secret_key", "")

        # Cron / notification delivery target
        self.home_user = os.getenv("WANLING_HOME_USER") or extra.get("home_user", "")

        # Authorization
        allowed = os.getenv("WANLING_ALLOWED_USERS")
        if allowed:
            self.allowed_users = [u.strip() for u in allowed.split(",") if u.strip()]
        else:
            self.allowed_users = list(extra.get("allowed_users", []))
        self.allow_all = (
            os.getenv("WANLING_ALLOW_ALL_USERS", "").lower() in {"1", "true", "yes"}
        )

        # Runtime state
        self._ws: Optional[Any] = None
        self._token: Optional[str] = None
        self._recv_task: Optional[asyncio.Task] = None
        self._heartbeat_task: Optional[asyncio.Task] = None
        # Resume：本连接最后收到的 dispatch seq（来自服务端 WSMessage.s）。
        # 重连时若 >0 发 OpResume 让服务端补发断线期间的消息，避免丢消息。
        # 注意：seq 是 per-client 的，必须记录本 adapter 实例自己收到的最后值。
        self._last_seq: int = 0
        # _stopping 跟 _running 区别：_running 是父类管理的，需要 _mark_connected 后才 True，
        # 但我们要在 connect 后立刻启动 _receive_loop（_running 还是 False），所以用单独标志。
        self._stopping = False
        # Typing debounce: chat_id → last TYPING_START timestamp (epoch seconds)
        self._typing_sent_at: Dict[str, float] = {}

        # user_id → conv_id 缓存。双向来源：
        #   1. 入站 MESSAGE_CREATE 的 conversation_id 字段（高频路径，命中即可零开销）
        #   2. POST /api/agents/me/conversations（agent 视角 findOrCreate）HTTP 兜底，
        #      miss 时调一次后填缓存，下次命中。
        # 待审批状态：send_exec_approval 发卡片后立即返回（不等 user 决策），
        # hermes gateway 通过 tools/approval.py 自己的 queue 等待 user 响应。
        # user 决策由 APPROVAL_DECIDED 事件触发，调 resolve_gateway_approval 唤醒。
        # （_pending_approvals 字段已删除：send_exec_approval 不再本地 await user 决策，
        #  改为立即返回，由 hermes gateway 自己管 approval 等待）
        self._conv_id_by_user: Dict[str, str] = {}

    @property
    def name(self) -> str:
        return "Wanling"

    # ── Connection lifecycle ──────────────────────────────────────────────

    async def connect(self) -> bool:
        if not self.agent_id or not self.secret_key:
            logger.error("Wanling: agent_id and secret_key must be configured")
            self._set_fatal_error(
                "config_missing",
                "WANLING_AGENT_ID and WANLING_SECRET_KEY must be set",
                retryable=False,
            )
            return False

        # 首次连接：只换 token 验证配置（WS 建立由 _receive_loop 接管，失败自动 backoff retry）。
        # 这样 connect() 失败仅限 token 换不到（fatal），WS 偶发失败不阻断启动。
        try:
            self._token = await asyncio.to_thread(
                _exchange_token, self.server_url, self.agent_id, self.secret_key
            )
        except Exception as e:
            logger.error("Wanling: token exchange failed — %s", e)
            self._set_fatal_error("token_failed", str(e), retryable=True)
            return False

        # 启动 _receive_loop：内部自己建 WS + 重连 + 启动 heartbeat task
        self._recv_task = asyncio.create_task(self._receive_loop())
        return True

    async def disconnect(self) -> None:
        self._stopping = True  # 通知 _receive_loop 退出
        await self._cleanup_ws()
        logger.info("Wanling: disconnected")

    async def _close_ws_and_heartbeat(self) -> None:
        """关闭 WS + 取消 heartbeat task（保留 recv_task）。

        供 _receive_loop 异常分支重连前调用，避免 cancel 自己（recv_task）。
        """
        if self._heartbeat_task and not self._heartbeat_task.done():
            self._heartbeat_task.cancel()
            try:
                await self._heartbeat_task
            except Exception:
                pass
        self._heartbeat_task = None

        if self._ws:
            try:
                await self._ws.close()
            except Exception:
                pass
            self._ws = None

    async def _cleanup_ws(self) -> None:
        """关闭 WS + 取消所有 task（heartbeat + recv）。

        仅 disconnect 调，不在 _receive_loop 内调（会自杀 recv_task）。
        """
        await self._close_ws_and_heartbeat()
        if self._recv_task and not self._recv_task.done():
            self._recv_task.cancel()
            try:
                await self._recv_task
            except (asyncio.CancelledError, Exception):
                pass
        self._recv_task = None

    async def _establish_ws(self) -> int:
        """建 WS + 换 token（如需）+ 收 Hello + 发 Identify，返回 heartbeat_interval_ms。

        不启动 task、不调 _mark_connected（调用方负责）。
        失败抛异常让调用方决定降级。
        """
        # token 已在 connect() 首次换过；重连时复用 self._token
        if not self._token:
            self._token = await asyncio.to_thread(
                _exchange_token, self.server_url, self.agent_id, self.secret_key
            )

        self._ws = await asyncio.wait_for(
            websockets.connect(_ws_url(self.server_url)),
            timeout=15,
        )

        hello_raw = await asyncio.wait_for(self._ws.recv(), timeout=10)
        hello = json.loads(hello_raw)
        if hello.get("op") != OP_HELLO:
            raise RuntimeError(f"expected Hello (op=10), got {hello}")

        # 握手必须先 Identify：server ws_handler 要求首条消息必须是 Identify，
        # 否则直接关闭连接（不支持握手阶段直接发 Resume）。
        # 故总是先 Identify 让 server 注册 client，再补 Resume 拉取断线期间
        # 错过的 dispatch（对齐 app/lib/services/websocket_service.dart 的做法）。
        # server 重启后 dispatch buffer 为空，Resume 不会补到任何消息，无害。
        await self._ws.send(json.dumps({"op": OP_IDENTIFY, "d": {"token": self._token}}))
        if self._last_seq > 0:
            await self._ws.send(json.dumps(
                {"op": OP_RESUME, "d": {"last_seq": self._last_seq}}
            ))
            logger.info("Wanling: resume requested (last_seq=%d)", self._last_seq)

        return hello.get("d", {}).get("heartbeat_interval", 30000)

    async def _restart_heartbeat_task(self, interval_s: float) -> None:
        """取消旧 heartbeat task + 启动新的（用最新连接的 interval）。

        每次 _receive_loop 成功建连后调一次。旧 task 一般已 done
        （_heartbeat_loop 失败时 close ws 后 return），但防御性 cancel 一下。
        """
        if self._heartbeat_task and not self._heartbeat_task.done():
            self._heartbeat_task.cancel()
            try:
                await self._heartbeat_task  # 等取消完成
            except Exception:
                pass
        self._heartbeat_task = asyncio.create_task(self._heartbeat_loop(interval_s))

    # ── Background loops ──────────────────────────────────────────────────

    async def _heartbeat_loop(self, interval_s: float) -> None:
        while True:
            try:
                await asyncio.sleep(interval_s)
                if self._ws is not None:
                    await self._ws.send(json.dumps({"op": OP_HEARTBEAT}))
            except asyncio.CancelledError:
                return
            except Exception as e:
                logger.warning(
                    "Wanling: heartbeat failed — %s, closing WS to trigger reconnect", e
                )
                # 主动 close 让 _receive_loop 的 async for 抛异常进重连分支
                try:
                    if self._ws is not None:
                        await self._ws.close()
                except Exception:
                    pass
                return  # task 退出，_receive_loop 重连后会通过 _restart_heartbeat_task 重启

    async def _receive_loop(self) -> None:
        backoff = 1.0
        while not self._stopping:
            try:
                heartbeat_interval_ms = await self._establish_ws()
                self._mark_connected()
                logger.info(
                    "Wanling: connected to %s as agent %s (heartbeat %dms)",
                    self.server_url, self.agent_id, heartbeat_interval_ms,
                )
                backoff = 1.0  # 成功后重置
                await self._restart_heartbeat_task(heartbeat_interval_ms / 1000)

                async for raw in self._ws:
                    try:
                        msg = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    await self._handle_ws_message(msg)
                # async for 退出无异常 = WS 被对端正常关闭，仍走重连
                raise ConnectionError("WS closed by peer")
            except asyncio.CancelledError:
                return
            except Exception as e:
                if self._stopping:
                    return
                logger.warning(
                    "Wanling: receive loop ended — %s (reconnect in %.1fs)", e, backoff
                )
                self._mark_disconnected()
                await self._close_ws_and_heartbeat()  # 不要 cancel 自己
                # 20% jitter 防 thundering herd（仿 signal _sse_listener）
                jitter = backoff * 0.2 * random.random()
                await asyncio.sleep(backoff + jitter)
                backoff = min(backoff * 2, 30.0)  # 上限 30s

    async def _handle_ws_message(self, msg: dict) -> None:
        op = msg.get("op")
        if op == OP_HEARTBEAT_ACK:
            return  # silent
        if op == OP_RECONNECT:
            # server 要求短暂断开重连（如服务端重启），close WS 让 _receive_loop
            # 的 async for 抛异常进重连分支。不要调 disconnect（会永久 _stopping=True）。
            logger.info("Wanling: server requested reconnect, closing WS")
            try:
                if self._ws is not None:
                    await self._ws.close()
            except Exception:
                pass
            return
        if op == OP_DISPATCH:
            # 记录 seq 用于断线重连 Resume。服务端 WSMessage.s 是 per-client 单调递增，
            # 重连带上 last_seq 可让服务端 getAfter 补发断线期间错过的 dispatch。
            s = msg.get("s")
            if isinstance(s, int) and s > self._last_seq:
                self._last_seq = s
            t = msg.get("t")
            if t == EVENT_MESSAGE_CREATE:
                await self._on_message_create(msg["d"])
            elif t == EVENT_APPROVAL_DECIDED:
                await self._on_approval_decided(msg["d"])
            elif t == EVENT_APPROVAL_EXPIRED:
                await self._on_approval_expired(msg["d"])
            return
        # Unhandled — log for debugging
        logger.debug("Wanling: unhandled msg op=%s t=%s", op, msg.get("t"))

    async def _on_message_create(self, d: dict) -> None:
        # Ignore agent's own messages (server broadcasts to sender too)
        if d.get("sender_type") == "agent":
            return

        user_id = d.get("sender_id")
        if not user_id:
            return

        # 缓存 user_id → conv_id，供 send_exec_approval 用（高频路径，命中即可零开销）；
        # miss 时 send_exec_approval 会调 HTTP findOrCreate 兜底。
        conv_id = d.get("conversation_id")
        if conv_id and user_id:
            self._conv_id_by_user[user_id] = conv_id

        # Authorization
        if not self.allow_all and self.allowed_users:
            if user_id not in self.allowed_users:
                logger.info("Wanling: ignoring unauthorized user %s", user_id)
                return

        # Parse content payload
        content = d.get("content") or {}
        msg_type = content.get("msg_type", "text") if isinstance(content, dict) else "text"
        data_raw = content.get("data") if isinstance(content, dict) else None
        data = data_raw if isinstance(data_raw, dict) else {}

        # 按 msg_type 分支处理。image/file 走下载 + media_urls 让 vision LLM 看到。
        text = ""
        media_urls: List[str] = []
        media_types: List[str] = []
        event_type = MessageType.TEXT

        if msg_type in ("text", "markdown"):
            text = str(data.get("text", ""))

        elif msg_type == "image":
            file_id = data.get("file_id")
            if file_id:
                local = await self._download_file(file_id)
                if local:
                    media_urls.append(local)
                    media_types.append(self._guess_mime(local))
                    event_type = MessageType.PHOTO
            # 下载失败兜底：让 LLM 至少知道用户发了图
            if not media_urls:
                text = "[用户发了一张图片，但下载失败]"

        elif msg_type == "file":
            file_id = data.get("file_id")
            if file_id:
                local = await self._download_file(file_id)
                if local:
                    media_urls.append(local)
                    media_types.append(self._guess_mime(local))
                    event_type = MessageType.DOCUMENT
            if not media_urls:
                text = "[用户发了一个文件，但下载失败]"

        elif msg_type == "mixed":
            # mixed 消息：text + 多个 file_id（图片/文件混合）。
            # 取 text 部分；file_id 列表里的图片下载填 media_urls。
            # 当前 server/APP 不发 mixed，但 server 已定义类型，预留分支避免吞消息。
            # 推断格式 {text, items: [{type, file_id}]}，加守卫避免多图把 PHOTO 覆盖。
            text = str(data.get("text", ""))
            for item in (data.get("items") or []):
                if not isinstance(item, dict):
                    continue
                item_file_id = item.get("file_id")
                if not item_file_id:
                    continue
                local = await self._download_file(item_file_id)
                if not local:
                    continue
                media_urls.append(local)
                mime = self._guess_mime(local)
                media_types.append(mime)
                if mime.startswith("image/") and event_type == MessageType.TEXT:
                    event_type = MessageType.PHOTO

        else:
            # 未知 msg_type：兜底尝试取 text 字段，避免吞消息
            text = str(data.get("text", "")) if isinstance(data, dict) else ""

        source = self.build_source(
            chat_id=user_id,           # one-on-one: chat_id = user_id
            chat_name=f"user:{user_id[:8]}",
            chat_type="dm",
            user_id=user_id,
            user_name=f"user:{user_id[:8]}",
        )

        event = MessageEvent(
            text=text,
            message_type=event_type,
            source=source,
            media_urls=media_urls,
            media_types=media_types,
            message_id=d.get("id") or uuid.uuid4().hex[:12],
            timestamp=datetime.now(),
        )

        await self.handle_message(event)

    # ── Approval (agent → user 卡片决策) ─────────────────────────────────

    async def _on_approval_decided(self, d: dict) -> None:
        """APPROVAL_DECIDED 事件处理：按 card_type 分流唤醒 hermes 的等待。

        两类审批走不同的 hermes 解析原语：

        1. exec_approval（card_type=command/tool/file，decision=allow_once/allow_always/deny）
           → tools.approval.resolve_gateway_approval(session_key, choice)
           choice 映射：allow_once→once, allow_always→always, deny→deny

        2. slash_confirm（card_type=slash_confirm，decision=once/always/cancel）
           → tools.slash_confirm.resolve(session_key, confirm_id, choice)
           decision 直接是 hermes 的 choice 枚举，无需映射；但需要 confirm_id 定位。
        """
        session_key = d.get("session_key")
        if not session_key:
            logger.warning("Wanling: APPROVAL_DECIDED missing session_key — %s", d)
            return

        decision = d.get("decision", "")
        confirm_id = d.get("confirm_id")

        # 分流判断：slash_confirm 的 decision 是 once/always/cancel
        if decision in ("once", "always", "cancel") and confirm_id:
            await self._resolve_slash_confirm(session_key, confirm_id, decision, d)
            return

        # exec_approval 路径
        choice = {
            "allow_once": "once",
            "allow_always": "always",
            "deny": "deny",
        }.get(decision)
        if choice is None:
            logger.warning("Wanling: APPROVAL_DECIDED unknown decision %r — %s", decision, d)
            return

        try:
            # lazy import：避免插件加载时硬依赖 hermes 内部模块（测试隔离）
            from tools.approval import resolve_gateway_approval
            count = resolve_gateway_approval(session_key, choice)
            logger.info(
                "Wanling: APPROVAL_DECIDED resolved %d approval(s) for session %s "
                "(choice=%s, decided_by=%s)",
                count, session_key, choice, d.get("decided_by"),
            )
        except Exception as e:
            logger.error(
                "Wanling: resolve_gateway_approval failed for session %s: %s",
                session_key, e,
            )

    async def _resolve_slash_confirm(
        self, session_key: str, confirm_id: str, choice: str, d: dict,
    ) -> None:
        """slash_confirm 决策：调 tools.slash_confirm.resolve 唤醒 hermes 的 slash 确认队列。

        resolve 是 async（run handler 在事件循环上），需要 await。
        """
        try:
            from tools.slash_confirm import resolve as slash_resolve
            await slash_resolve(session_key, confirm_id, choice)
            logger.info(
                "Wanling: slash_confirm resolved session %s confirm %s (choice=%s, decided_by=%s)",
                session_key, confirm_id, choice, d.get("decided_by"),
            )
        except Exception as e:
            logger.error(
                "Wanling: slash_confirm.resolve failed session %s confirm %s: %s",
                session_key, confirm_id, e,
            )

    async def _on_approval_expired(self, d: dict) -> None:
        """APPROVAL_EXPIRED 事件处理：仅日志记录。

        hermes gateway 通过 tools/approval.py 自己的 queue 管超时
        （_gateway_queues 有独立的 timeout 机制），不依赖本事件驱动。
        本事件主要用于本地状态可视化和调试。
        """
        session_key = d.get("session_key")
        logger.info(
            "Wanling: APPROVAL_EXPIRED session %s (hermes gateway 自己管 timeout)",
            session_key,
        )

    async def _resolve_conv_id(self, user_id: str) -> Optional[str]:
        """从本地缓存或 HTTP 拿 user_id 对应 conv_id。

        缓存优先（命中就不调 HTTP，零开销）；miss 时调
        POST /api/agents/me/conversations findOrCreate，成功后填缓存下次命中。
        """
        cached = self._conv_id_by_user.get(user_id)
        if cached:
            return cached
        # HTTP 兜底（同步阻塞调用，丢线程池里跑避免阻塞事件循环）
        try:
            conv_id = await asyncio.to_thread(self._find_conv_as_agent_sync, user_id)
        except Exception as e:
            logger.error("Wanling: find conv as agent failed — %s", e)
            return None
        if conv_id:
            self._conv_id_by_user[user_id] = conv_id
        return conv_id

    def _find_conv_as_agent_sync(self, user_id: str) -> Optional[str]:
        """POST /api/agents/me/conversations findOrCreate，返回 conv_id。

        agent JWT 鉴权。失败时返回 None（调用方走文本兜底）。
        """
        if not self._token:
            return None
        req = urllib.request.Request(
            f"{self.server_url.rstrip('/')}/api/agents/me/conversations",
            data=json.dumps({"user_id": user_id}).encode(),
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {self._token}",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                payload = json.loads(resp.read())
            return payload.get("id")
        except Exception as e:
            logger.error("Wanling._find_conv_as_agent_sync: failed — %s", e)
            return None

    async def send_exec_approval(
        self,
        chat_id: str,
        command: str,
        session_key: str,
        description: str = "dangerous command",
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        """发起命令审批卡片（hermes gateway 的跨平台契约）。

        重要语义：本方法只负责**发出审批卡片**，立即返回。不等 user 决策。
        hermes gateway 通过 tools/approval.py 的 queue 自己管 approval 等待，
        user 在万灵 APP 点按钮 → 服务端推 APPROVAL_DECIDED → adapter 的
        _on_approval_decided 调 resolve_gateway_approval 唤醒等待。

        流程：
          1. 拿 conv_id（缓存优先，miss 时 POST /api/agents/me/conversations）
          2. POST /api/conversations/:id/approvals 创建审批卡片
             - 命中 allow_pattern 白名单时服务端返 auto_approved=true，agent 立即继续
             - 否则卡片落到 user 端，本方法返回 success=True（卡片已发出）
          3. user 决策由 APPROVAL_DECIDED 事件异步触发 hermes 唤醒，不在本方法内等待

        返回：
          success=True — 卡片已发出（或命中白名单直接通过）
          success=False — 卡片发送失败（hermes gateway 会走文本兜底）
        """
        if self._ws is None:
            return SendResult(success=False, error="Not connected")

        # 1. 拿 conv_id（缓存优先，miss 时 HTTP findOrCreate 兜底）
        conv_id = await self._resolve_conv_id(chat_id)
        if not conv_id:
            return SendResult(
                success=False,
                error=f"resolve conv_id failed for user {chat_id}",
            )

        # 2. 构造审批请求体（命令审批独有 allow_pattern，由 metadata 传入）
        allow_pattern = None
        if metadata and isinstance(metadata, dict):
            allow_pattern = metadata.get("allow_pattern")

        body: Dict[str, Any] = {
            "card_type": "command",
            "title": "命令执行审批",
            "preview": command,
            "session_key": session_key,
            "timeout_sec": 300,
            "meta": [
                {"icon": "📝", "text": description or "dangerous command"},
            ],
        }
        if allow_pattern:
            body["allow_pattern"] = allow_pattern

        # 3. POST 创建审批
        try:
            create_resp = await asyncio.to_thread(
                self._create_approval_sync, conv_id, body,
            )
        except Exception as e:
            return SendResult(success=False, error=f"create approval failed: {e}")

        if create_resp is None:
            return SendResult(success=False, error="create approval HTTP failed")

        # 4. 命中白名单 → agent 立即继续（不发卡片）
        if create_resp.get("auto_approved"):
            logger.info("Wanling: approval auto-approved by pattern — %s", command[:60])
            return SendResult(success=True, message_id=create_resp.get("approval_id", ""))

        approval_id = create_resp.get("approval_id")
        if not approval_id:
            return SendResult(success=False, error="missing approval_id in response")

        # 5. 卡片已发出，立即返回。user 决策由 APPROVAL_DECIDED 事件异步唤醒 hermes。
        logger.info(
            "Wanling: approval card sent for session %s (approval_id=%s) — "
            "awaiting user decision via APPROVAL_DECIDED event",
            session_key, approval_id,
        )
        return SendResult(success=True, message_id=approval_id)

    async def send_slash_confirm(
        self,
        chat_id: str,
        title: str,
        message: str,
        session_key: str,
        confirm_id: str,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        """发起 slash 命令确认卡片（hermes gateway 的跨平台契约）。

        用于 /new /clear /reset /undo 等破坏性 slash 命令的三选一确认。
        与 send_exec_approval 语义一致：只负责发卡片，立即返回，不等 user 决策。
        user 决策由 APPROVAL_DECIDED 事件异步唤醒 hermes 的 slash_confirm 队列
        （见 _on_approval_decided → _resolve_slash_confirm）。

        title 形如 "/new"，message 是带 detail 的 markdown 提示文案。
        confirm_id 由 hermes tools/slash_confirm.register 生成，决策时必须透传回去定位。
        """
        if self._ws is None:
            return SendResult(success=False, error="Not connected")

        conv_id = await self._resolve_conv_id(chat_id)
        if not conv_id:
            return SendResult(
                success=False,
                error=f"resolve conv_id failed for user {chat_id}",
            )

        body: Dict[str, Any] = {
            "card_type": "slash_confirm",
            "title": f"确认 {title}",
            "preview": message,  # 详情文案走 preview 块展示
            "session_key": session_key,
            "confirm_id": confirm_id,
            "timeout_sec": 300,
        }

        try:
            create_resp = await asyncio.to_thread(
                self._create_approval_sync, conv_id, body,
            )
        except Exception as e:
            return SendResult(success=False, error=f"create slash_confirm failed: {e}")

        if create_resp is None:
            return SendResult(success=False, error="create slash_confirm HTTP failed")

        approval_id = create_resp.get("approval_id")
        if not approval_id:
            return SendResult(success=False, error="missing approval_id in response")

        logger.info(
            "Wanling: slash_confirm card sent session %s confirm %s (approval_id=%s) — "
            "awaiting user decision via APPROVAL_DECIDED event",
            session_key, confirm_id, approval_id,
        )
        return SendResult(success=True, message_id=approval_id)

    def _create_approval_sync(self, conv_id: str, body: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """同步实现：POST /api/conversations/:id/approvals（走 agentAuth）。

        返回响应 dict（含 approval_id/message_id/state/expires_at 或 auto_approved=true）；
        失败返回 None。
        """
        if not self._token:
            return None
        req = urllib.request.Request(
            f"{self.server_url.rstrip('/')}/api/conversations/{conv_id}/approvals",
            data=json.dumps(body).encode(),
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {self._token}",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                return json.loads(resp.read())
        except Exception as e:
            logger.error("Wanling._create_approval_sync: failed — %s", e)
            return None

    # ── Outbound (agent → user) ──────────────────────────────────────────

    async def send(
        self,
        chat_id: str,
        content: str,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        if self._ws is None:
            return SendResult(success=False, error="Not connected")

        # hermes 的 extract_images 只识别 markdown ![](https://...) 格式的 URL，
        # 不识别本地路径。LLM 输出本地图片路径（如 /home/k/.hermes/cache/xxx.jpg
        # 或 🖼️ Image: <path>）会被当 markdown 文本发出，APP 看到的是路径字符串。
        # 这里在 send 入口扫描本地图片路径，发现就上传 server 发 msg_type=image，
        # 并从 content 删除该路径。
        content = await self._strip_and_send_local_images(chat_id, content)

        # 上传 + 发送图片后可能只剩空白（LLM 整段都在描述图片），跳过 markdown 发送
        if not content.strip():
            return SendResult(success=True, message_id=uuid.uuid4().hex[:12])

        # chat_id is user_id (one-on-one IM)
        try:
            await self._ws.send(json.dumps({
                "op": OP_DISPATCH,
                "t": EVENT_MESSAGE_CREATE,
                "d": {
                    "user_id": chat_id,
                    "content": {"msg_type": "markdown", "data": {"text": content}},
                },
            }))
        except Exception as e:
            return SendResult(success=False, error=str(e))

        return SendResult(success=True, message_id=uuid.uuid4().hex[:12])

    # 匹配本地图片绝对路径（/...jpg|png|gif|webp|bmp）。不匹配 http(s):// URL（hermes
    # 上游 extract_images 已处理）。否定后顾排除 : 防 https:// 被误匹配（: 后第一个 /）。
    _LOCAL_IMAGE_RE = re.compile(
        r"(?<![\w/:])(?P<path>/[\w./\-]+\.(?:jpg|jpeg|png|gif|webp|bmp))",
        re.IGNORECASE,
    )

    async def _strip_and_send_local_images(self, chat_id: str, content: str) -> str:
        """扫描 content 里的本地图片路径，上传 + WS 发 image，从 content 删除已发的路径。

        上传失败的路径保留在 content（让 user 看到原始输出，不静默吞）。
        """
        if not content:
            return content

        matches = list(self._LOCAL_IMAGE_RE.finditer(content))
        if not matches:
            return content

        sent_paths: List[str] = []
        for m in matches:
            path = m.group("path")
            if not os.path.isfile(path):
                continue  # 不是本地文件，可能是 URL 残留或幻觉路径
            file_id = await self._upload_file(path)
            if not file_id:
                logger.warning("Wanling.send: upload local image failed, keep in text — %s", path)
                continue
            try:
                await self._ws.send(json.dumps({
                    "op": OP_DISPATCH,
                    "t": EVENT_MESSAGE_CREATE,
                    "d": {
                        "user_id": chat_id,
                        "content": {"msg_type": "image", "data": {"file_id": file_id}},
                    },
                }))
                sent_paths.append(path)
            except Exception as e:
                logger.warning("Wanling.send: WS send image failed — %s", e)

        if not sent_paths:
            return content

        # 从 content 中删除已发送的路径
        for path in sent_paths:
            content = content.replace(path, "")
        # 清理多余空白：连续 3+ 换行压成 2 个，首尾空白去掉
        content = re.sub(r"\n{3,}", "\n\n", content).strip()
        return content

    @staticmethod
    def _guess_mime(filename: str) -> str:
        """根据扩展名猜 MIME，覆盖 IM 常见图片格式；其他默认 octet-stream。"""
        ext = os.path.splitext(filename)[1].lower()
        return {
            ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
            ".png": "image/png", ".gif": "image/gif",
            ".webp": "image/webp", ".bmp": "image/bmp",
        }.get(ext, "application/octet-stream")

    # 安全扩展名白名单。来自 server Content-Disposition 的 ext 必须在白名单内，
    # 否则用 .bin 兜底，防止路径注入和未知类型 LLM 处理出错。
    _SAFE_EXTS = frozenset({
        # 图片
        ".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp",
        # 文本（hermes 内部 DOCUMENT 处理可读）
        ".txt", ".md", ".csv", ".log", ".json", ".xml", ".yaml", ".yml",
        ".toml", ".ini", ".cfg",
        # 常见文档
        ".pdf", ".doc", ".docx", ".xls", ".xlsx", ".ppt", ".pptx",
    })

    @classmethod
    def _guess_safe_ext(cls, filename: str) -> str:
        """从 filename 拿扩展名，白名单外的扩展名 fallback .bin。"""
        ext = os.path.splitext(filename)[1].lower()
        return ext if ext in cls._SAFE_EXTS else ".bin"

    @staticmethod
    def _parse_filename_from_disposition(disp: str) -> Optional[str]:
        """从 'inline; filename="cat.jpg"' 解析 filename，失败返回 None。

        兼容带引号和不带引号两种格式。主要为了拿扩展名（cat.jpg → .jpg）。
        """
        if not disp:
            return None
        m = re.search(r'filename="([^"]+)"', disp) or re.search(r"filename=([^;\s]+)", disp)
        return m.group(1) if m else None

    def _upload_file_sync(self, local_path: str) -> Optional[str]:
        """POST /api/upload 上传文件（同步实现），返回 file_id；失败返回 None。

        用 agent JWT（self._token）鉴权，multipart 字段名 'file'。
        失败不抛异常，让调用方决定是否降级。
        """
        if not self._token:
            logger.error("Wanling._upload_file_sync: no JWT token")
            return None

        # size 上限校验，防止大文件 OOM
        try:
            size = os.path.getsize(local_path)
        except OSError as e:
            logger.error("Wanling._upload_file_sync: stat %s failed — %s", local_path, e)
            return None
        if size > MAX_UPLOAD_SIZE:
            logger.warning(
                "Wanling._upload_file_sync: %s too large (%d bytes > %d), skip",
                local_path, size, MAX_UPLOAD_SIZE,
            )
            return None

        # filename 转义：避免 " \ \r \n 破坏 multipart 结构 / header injection
        # filename 来自 os.path.basename，cache_image_from_url 生成的临时名由 hermes 控制，
        # 但稳健起见仍做转义。
        filename = os.path.basename(local_path)
        safe_filename = (
            filename.replace("\\", "/")
            .replace('"', "'")
            .replace("\r", "_")
            .replace("\n", "_")
        )
        safe_filename = os.path.basename(safe_filename)  # 兜底去掉路径残留

        mime = self._guess_mime(safe_filename)

        try:
            with open(local_path, "rb") as f:
                file_bytes = f.read()
        except OSError as e:
            logger.error("Wanling._upload_file_sync: read %s failed — %s", local_path, e)
            return None

        # 构造 multipart body（标准库，不引入 requests 依赖）
        boundary = "----WanlingBoundary" + os.urandom(8).hex()
        body = (
            (f"--{boundary}\r\n"
             f'Content-Disposition: form-data; name="file"; filename="{safe_filename}"\r\n'
             f"Content-Type: {mime}\r\n\r\n").encode()
            + file_bytes
            + f"\r\n--{boundary}--\r\n".encode()
        )

        req = urllib.request.Request(
            f"{self.server_url.rstrip('/')}/api/upload",
            data=body,
            headers={
                "Content-Type": f"multipart/form-data; boundary={boundary}",
                "Authorization": f"Bearer {self._token}",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                payload = json.loads(resp.read())
            return payload.get("id")
        except Exception as e:
            logger.error("Wanling._upload_file_sync: upload failed — %s", e)
            return None

    async def _upload_file(self, local_path: str) -> Optional[str]:
        """async 包装：把同步 IO 丢到线程，避免阻塞事件循环（send/heartbeat）。"""
        return await asyncio.to_thread(self._upload_file_sync, local_path)

    def _download_file_sync(self, file_id: str) -> Optional[str]:
        """GET /api/files/:id 下载到本地缓存，返回本地路径；失败返回 None。

        用 agent JWT 鉴权。文件名从 Content-Disposition 解析（主要拿扩展名），
        存为 <file_id>.<ext>。幂等：同一 file_id 已存在直接返回。
        """
        # file_id 期望是 server 生成的 UUID。加白名单防御 server 端 bug 或被攻破时
        # 的路径注入。允许字母数字下划线短横线（UUID 形态），长度 1-64。
        if not re.match(r"^[A-Za-z0-9_-]{1,64}$", file_id):
            logger.error("Wanling._download_file_sync: invalid file_id %r", file_id)
            return None

        if not self._token:
            logger.error("Wanling._download_file_sync: no JWT token")
            return None

        # 幂等：先扫目录找已下载的同 file_id 文件
        existing = glob.glob(os.path.join(DOWNLOAD_CACHE_DIR, f"{file_id}.*"))
        if existing:
            return existing[0]

        os.makedirs(DOWNLOAD_CACHE_DIR, exist_ok=True)

        req = urllib.request.Request(
            f"{self.server_url.rstrip('/')}/api/files/{file_id}",
            headers={"Authorization": f"Bearer {self._token}"},
            method="GET",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                # 先查 Content-Length，避免 read() 把恶意大文件全读进内存
                content_length = resp.headers.get("Content-Length")
                if content_length and int(content_length) > MAX_DOWNLOAD_SIZE:
                    logger.warning(
                        "Wanling._download_file_sync: %s Content-Length %s exceeds %d",
                        file_id, content_length, MAX_DOWNLOAD_SIZE,
                    )
                    return None

                disp = resp.headers.get("Content-Disposition", "")
                filename = self._parse_filename_from_disposition(disp) or f"{file_id}.bin"
                ext = self._guess_safe_ext(filename)

                data = resp.read()
                # 双重校验：Content-Length 可能缺失或被伪造，read 后再查一次
                if len(data) > MAX_DOWNLOAD_SIZE:
                    logger.warning(
                        "Wanling._download_file_sync: %s actual %d bytes > %d",
                        file_id, len(data), MAX_DOWNLOAD_SIZE,
                    )
                    return None

                local_path = os.path.join(DOWNLOAD_CACHE_DIR, f"{file_id}{ext}")
                with open(local_path, "wb") as f:
                    f.write(data)
                return local_path
        except Exception as e:
            logger.error("Wanling._download_file_sync: download %s failed — %s", file_id, e)
            return None

    async def _download_file(self, file_id: str) -> Optional[str]:
        """_download_file_sync 的 async 包装，避免阻塞事件循环。

        跟 _upload_file 风格一致（同步实现 + asyncio.to_thread 包装）。
        """
        return await asyncio.to_thread(self._download_file_sync, file_id)

    async def send_image(
        self,
        chat_id: str,
        image_url: str,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        """覆盖默认 fallback：上传到 server 拿 file_id，发 msg_type=image。

        流程：
          1. 解析 image_url：本地路径直接用；http(s):// 调 cache_image_from_url 下载
          2. 调 _send_image_path 上传 + 发 image 消息

        降级：路径解析失败或上传失败时走 send() 发文本，保证对话不中断。
        """
        # 1. 解析路径：本地文件优先，http(s) 走 hermes 缓存工具下载
        local_path: Optional[str] = None
        try:
            if os.path.isfile(image_url):
                local_path = image_url
            elif image_url.startswith(("http://", "https://")):
                local_path = await asyncio.to_thread(cache_image_from_url, image_url)
        except Exception as e:
            logger.warning("Wanling.send_image: resolve %s failed — %s", image_url, e)

        if local_path:
            return await self._send_image_path(chat_id, local_path, caption)

        # 路径解析失败 → 降级为文本
        degraded = caption or f"[图片] {image_url}"
        logger.warning("Wanling.send_image: degrade to text — %s", degraded[:60])
        return await self.send(chat_id, degraded)

    async def send_image_file(
        self,
        chat_id: str,
        image_path: str,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **kwargs,
    ) -> SendResult:
        """覆盖默认 fallback（默认会把路径转成 '🖼️ Image: <path>' 文本走 send，
        导致 user 收到一条多余文本消息）。

        hermes 上游用 file:// URL 调图片发送时，base.py 会自动剥前缀改调本方法
        而不是 send_image，所以必须 override 它才能正确处理 LLM 工具生成的本地图片。
        """
        if not image_path or not os.path.isfile(image_path):
            degraded = caption or f"[图片] {image_path}"
            logger.warning("Wanling.send_image_file: missing file, degrade — %s", degraded[:60])
            return await self.send(chat_id, degraded)
        return await self._send_image_path(chat_id, image_path, caption)

    async def _send_image_path(
        self,
        chat_id: str,
        local_path: str,
        caption: Optional[str] = None,
    ) -> SendResult:
        """上传本地图片到 server + 发 msg_type=image 消息（+ caption 追加一条 markdown）。

        send_image（接 URL）和 send_image_file（接 path）共用此 helper。
        上传失败时降级走 send() 发文本。
        """
        if self._ws is None:
            return SendResult(success=False, error="Not connected")

        file_id = await self._upload_file(local_path)
        if not file_id:
            degraded = caption or f"[图片] {local_path}"
            logger.warning("Wanling._send_image_path: upload failed, degrade — %s", degraded[:60])
            return await self.send(chat_id, degraded)

        try:
            await self._ws.send(json.dumps({
                "op": OP_DISPATCH,
                "t": EVENT_MESSAGE_CREATE,
                "d": {
                    "user_id": chat_id,
                    "content": {"msg_type": "image", "data": {"file_id": file_id}},
                },
            }))
        except Exception as e:
            return SendResult(success=False, error=str(e))

        if caption:
            await self.send(chat_id, caption)
        return SendResult(success=True, message_id=uuid.uuid4().hex[:12])

    async def send_typing(self, chat_id: str, metadata=None) -> None:
        """Send typing indicator to user.

        Emits a TYPING_START dispatch via WS; server forwards to user.
        UI shows "对方正在输入..." + loading bubble. Auto-cleared on next
        MESSAGE_CREATE from this agent.

        Debounced: 1 send per 3s per chat_id to avoid flooding WS during
        long LLM streams (gateway already calls this every few seconds
        while streaming).
        """
        if self._ws is None:
            return

        now = time.time()
        last = self._typing_sent_at.get(chat_id, 0.0)
        if now - last < 3.0:
            return
        self._typing_sent_at[chat_id] = now

        try:
            await self._ws.send(json.dumps({
                "op": OP_DISPATCH,
                "t": "TYPING_START",
                "d": {
                    "user_id": chat_id,
                    "agent_id": self.agent_id,
                },
            }))
        except Exception as e:
            logger.debug("Wanling.send_typing failed (non-fatal): %s", e)

    async def get_chat_info(self, chat_id: str) -> Dict[str, Any]:
        # chat_id is user_id; we don't have a separate user name lookup
        return {
            "name": f"user:{chat_id[:8]}",
            "type": "dm",
            "chat_id": chat_id,
        }


# ---------------------------------------------------------------------------
# Plugin entry point
# ---------------------------------------------------------------------------

def check_requirements() -> bool:
    """Configured when both agent_id and secret_key are set."""
    return bool(os.getenv("WANLING_AGENT_ID") and os.getenv("WANLING_SECRET_KEY"))


def validate_config(config) -> bool:
    extra = getattr(config, "extra", {}) or {}
    return bool(
        os.getenv("WANLING_AGENT_ID")
        or extra.get("agent_id")
    ) and bool(
        os.getenv("WANLING_SECRET_KEY")
        or extra.get("secret_key")
    )


def is_connected(config) -> bool:
    return check_requirements()


def _env_enablement() -> Optional[dict]:
    """Seed PlatformConfig.extra + home_channel from env vars."""
    agent_id = os.getenv("WANLING_AGENT_ID")
    if not agent_id:
        return None
    extra: Dict[str, Any] = {
        "server_url": os.getenv("WANLING_SERVER_URL", "http://localhost:18008"),
        "agent_id": agent_id,
        "secret_key": os.getenv("WANLING_SECRET_KEY", ""),
    }
    home_user = os.getenv("WANLING_HOME_USER")
    home_channel = {"chat_id": home_user, "name": "Wanling Home"} if home_user else None
    return {"extra": extra, "home_channel": home_channel}


async def _standalone_send(pconfig, chat_id: str, message: str) -> dict:
    """Out-of-process send for cron delivery: spin up a minimal WS client."""
    try:
        extra = getattr(pconfig, "extra", {}) or {}
        server_url = extra.get("server_url", "http://localhost:18008")
        agent_id = extra.get("agent_id", "")
        secret_key = extra.get("secret_key", "")
        token = await asyncio.to_thread(_exchange_token, server_url, agent_id, secret_key)

        async with websockets.connect(_ws_url(server_url)) as ws:
            hello = json.loads(await asyncio.wait_for(ws.recv(), timeout=10))
            interval = hello["d"]["heartbeat_interval"] / 1000
            await ws.send(json.dumps({"op": OP_IDENTIFY, "d": {"token": token}}))

            async def beat():
                while True:
                    await asyncio.sleep(interval)
                    try:
                        await ws.send(json.dumps({"op": OP_HEARTBEAT}))
                    except Exception:
                        return

            task = asyncio.create_task(beat())
            try:
                await ws.send(json.dumps({
                    "op": OP_DISPATCH,
                    "t": EVENT_MESSAGE_CREATE,
                    "d": {
                        "user_id": chat_id,
                        "content": {"msg_type": "markdown", "data": {"text": message}},
                    },
                }))
                return {"ok": True}
            finally:
                task.cancel()
    except Exception as e:
        return {"ok": False, "error": str(e)}


def register(ctx):
    """Plugin entry point: register the Wanling platform."""
    ctx.register_platform(
        name="wanling",
        label="Wanling",
        adapter_factory=lambda cfg: WanlingAdapter(cfg),
        check_fn=check_requirements,
        validate_config=validate_config,
        is_connected=is_connected,
        required_env=["WANLING_AGENT_ID", "WANLING_SECRET_KEY"],
        install_hint="Requires websockets (already a Hermes dependency)",
        env_enablement_fn=_env_enablement,
        cron_deliver_env_var="WANLING_HOME_USER",
        standalone_sender_fn=_standalone_send,
        allowed_users_env="WANLING_ALLOWED_USERS",
        allow_all_env="WANLING_ALLOW_ALL_USERS",
        emoji="💬",
        pii_safe=True,
        allow_update_command=True,
        platform_hint=(
            "你正在通过万灵（Wanling）—— 一个一对一 IM 平台 —— 与用户对话。"
            "客户端支持 Markdown 渲染。消息没有硬性长度限制，"
            "但应保持简洁、有对话感。没有频道或群组的概念，"
            "每一次对话都是用户与 agent 之间的私聊。"
            "你可以发送图片：回复中任何图片 URL（http/https）或本地文件路径"
            "都会被自动上传，并内联渲染为图片气泡。"
            "当视觉内容有助于表达时（图解、截图、生成的图）可以使用。"
        ),
    )
