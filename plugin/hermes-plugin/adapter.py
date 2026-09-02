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
            home_conv: <UUID>          # install.sh 自动写入,无需手填
            allowed_users: []          # empty = use allow_all flag

Or via environment variables (overrides config.yaml):
    WANLING_SERVER_URL, WANLING_AGENT_ID, WANLING_SECRET_KEY,
    WANLING_HOME_CONV, WANLING_ALLOWED_USERS, WANLING_ALLOW_ALL_USERS
"""

import asyncio
import glob
import http.client
import json
import logging
import os
import random
import re
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid
from datetime import datetime
from typing import Any, Dict, List, Optional
from urllib.parse import urlparse

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

# 聚合卡核心（本插件聚合模式）：hook 事件 → REST 建卡/PATCH。
# 兼容两种加载：hermes 插件包内（相对导入）/ 自检脚本直接运行（绝对导入）。
try:
    from . import aggregate_card as _aggregate_card  # noqa: E402
except ImportError:  # pragma: no cover
    import aggregate_card as _aggregate_card  # noqa: E402,F401

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
def _safe_request(
    req: "urllib.request.Request",
    context: str,
    timeout: float,
) -> Optional[Dict[str, Any]]:
    """统一发请求 + 剥 envelope + 错误处理，返回 data 或 None。

    后端 envelope：成功 `{ok: true, data: <T | null>}` / 失败 `{ok: false, error: {code, message}}`。
    失败时记录包含 code/message/status 的错误日志并返回 None。
    调用方需要 raise 时（如 agent token 失败）应自行处理。

    注意：成功但 data 为 null（业务无返回值）时也返 None，
    调用方需用 isinstance(data, dict) 区分「成功 + data 为 dict」和其他情况。
    """
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            try:
                payload = json.loads(resp.read())
            except json.JSONDecodeError as e:
                logger.error("%s: response not JSON — %s", context, e)
                return None
        if not isinstance(payload, dict) or not payload.get("ok"):
            err = payload.get("error") or {}
            logger.error("%s: code=%s message=%s",
                         context, err.get("code"), err.get("message"))
            return None
        return payload.get("data")
    except urllib.error.HTTPError as e:
        try:
            err_body = json.loads(e.read())
            err = err_body.get("error") or {}
            logger.error("%s: code=%s message=%s status=%d",
                         context, err.get("code"), err.get("message"), e.code)
        except Exception:
            logger.error("%s: HTTP %d 无 JSON body", context, e.code)
        return None
    except Exception as e:
        logger.error("%s: %s", context, e)
        return None


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
    data = _safe_request(req, "agent_token", timeout=10)
    if not isinstance(data, dict) or not data.get("token"):
        raise RuntimeError("换 agent token 失败")
    return data["token"]


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

        # Cron / notification delivery target — chat_id 概念对齐 hermes 上游 18 平台
        # (Telegram chat_id / Discord channel_id / QQ openid / ...),值为 conv_id。
        # install.sh 自动写入,用户不直接填(UUID 不友好)。
        self.home_conv = os.getenv("WANLING_HOME_CONV") or extra.get("home_conv", "")

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
        # 流式编辑 REST 通道：send() 建消息 / edit_message() PATCH 共用 keep-alive 连接
        # （对齐 aggregate_card 的传输层：连接复用 + 401 刷新重试）。
        self._rest_conn: Optional[http.client.HTTPConnection] = None
        # message_id → 建消息时的 data（quote 等元数据）。PATCH 是全量替换，
        # 编辑时回填防引用块丢失。值为 None 表示虚拟 id（正文被聚合卡接管，
        # 续帧路由进聚合卡 markdown 元素而非 PATCH）。容量上限防长连泄漏。
        self._edit_meta: Dict[str, Optional[Dict[str, Any]]] = {}
        # 聚合卡图片改写 memo：本地路径/远程 URL → file_id（interim 快照去重，
        # 避免同一张图重复上传）。容量上限见 _IMAGE_MEMO_CAP，防长连泄漏。
        self._image_upload_memo: Dict[str, str] = {}
        # Resume：本连接最后收到的 dispatch seq（来自服务端 WSMessage.s）。
        # 重连时若 >0 发 OpResume 让服务端补发断线期间的消息，避免丢消息。
        # 注意：seq 是 per-client 的，必须记录本 adapter 实例自己收到的最后值。
        self._last_seq: int = 0
        # _stopping 跟 _running 区别：_running 是父类管理的，需要 _mark_connected 后才 True，
        # 但我们要在 connect 后立刻启动 _receive_loop（_running 还是 False），所以用单独标志。
        self._stopping = False
        # Typing debounce: chat_id → last TYPING_START timestamp (epoch seconds)
        self._typing_sent_at: Dict[str, float] = {}

        # 聚合卡：本 adapter 的事件队列（hook 侧 emit_event 分发进来）。
        import queue as _queue

        self.aggregate_events: "queue.Queue" = _queue.Queue(maxsize=1024)
        self._aggregate_consumer_task: Optional[asyncio.Task] = None
        # 聚合卡会话停止事件：消费者 task 在 stop 时退出。
        self._aggregate_stop: Optional[threading.Event] = None
        # user_id → conv_id 缓存（聚合卡 hook 反查 conv_id 用）。
        # 入站 MESSAGE_CREATE 高频填充；miss 时 POST /api/agents/me/conversations 兜底。
        self._user_conv: Dict[str, str] = {}
        self._user_conv_lock = threading.Lock()
        # conv_id → 最近用户消息 id（聚合卡建卡引用锚点）。agent 回复聚合卡时，
        # 建卡 POST 带 data.quote={message_id: last_user_msg_id}，server 富化引用块。
        self._last_user_msg: Dict[str, str] = {}

        # user_id → conv_id 缓存。双向来源：
        #   1. 入站 MESSAGE_CREATE 的 conversation_id 字段（高频路径，命中即可零开销）
        #   2. POST /api/agents/me/conversations（agent 视角 findOrCreate）HTTP 兜底，
        #      miss 时调一次后填缓存，下次命中。
        # 待审批状态：send_exec_approval 发卡片后立即返回（不等 user 决策），
        # hermes gateway 通过 tools/approval.py 自己的 queue 等待 user 响应。
        # user 决策由 APPROVAL_DECIDED 事件触发，调 resolve_gateway_approval 唤醒。
        # （_pending_approvals 字段已删除：send_exec_approval 不再本地 await user 决策，
        #  改为立即返回，由 hermes gateway 自己管 approval 等待）

    @property
    def name(self) -> str:
        return "Wanling"

    # ── Connection lifecycle ──────────────────────────────────────────────

    async def connect(self, *, is_reconnect: bool = False) -> bool:
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

        # 启动聚合卡消费者 task：hook 事件（worker 线程）→ 本 adapter 队列 → REST。
        self._aggregate_stop = threading.Event()
        self._aggregate_consumer_task = asyncio.create_task(
            _aggregate_card.run_event_consumer(self, stop_event=self._aggregate_stop)
        )
        _aggregate_card.register_adapter(self)
        return True

    async def disconnect(self) -> None:
        self._stopping = True  # 通知 _receive_loop 退出
        if self._aggregate_consumer_task is not None:
            if self._aggregate_stop is not None:
                self._aggregate_stop.set()
            self._aggregate_consumer_task.cancel()
            try:
                await self._aggregate_consumer_task
            except (asyncio.CancelledError, Exception):
                pass
            self._aggregate_consumer_task = None
        _aggregate_card.unregister_adapter(self)
        self._rest_close()
        self._edit_meta.clear()
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
            except (asyncio.CancelledError, Exception):
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
        # 每次建连都换 token：agent JWT TTL=72h,复用旧 token 可能在 TTL 后过期。
        # _establish_ws 只在首次连接和重连时调用,频率不高,多一次 HTTP 换 token 保安全。
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
            except (asyncio.CancelledError, Exception):
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

        # 单轨化:chat_id 概念对齐 hermes 上游 18 平台(Telegram chat_id /
        # Discord channel_id / ...),值 = conversation_id(server dispatch payload 含此字段)。
        conv_id = d.get("conversation_id") or ""

        # 聚合卡：入站记录 user_id → conv_id（hook 侧 sender_id 反查 conv_id 建卡）。
        if conv_id:
            with self._user_conv_lock:
                self._user_conv[user_id] = conv_id
            # 记录最近用户消息 id（聚合卡引用锚点）
            msg_id = d.get("id") or ""
            if msg_id:
                self._last_user_msg[conv_id] = msg_id

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

        # 审批回复（APP 聚合卡内 permission_card 按钮）→ 直接唤醒 hermes 审批队列，
        # 不进入 agent 对话流。reply: once | always | reject（APP 端选项值）。
        if msg_type == "permission_reply":
            await self._on_permission_reply(conv_id, data)
            return

        # 断卡：Agent 执行中用户发新消息 → 结束当前聚合卡段落（interrupt footer），
        # 下一条回复开新卡（对齐 opencode 消息边界分段）。仅文本/图片/文件类用户消息。
        if conv_id and msg_type in ("text", "markdown", "image", "file", "mixed"):
            if _aggregate_card.get_active_by_conv(conv_id) is not None:
                _aggregate_card.emit_event({
                    "kind": "interrupt",
                    "conv_id": conv_id,
                })

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

        # 引用消息映射:server 富化后的 content.data.quote snapshot 含
        # message_id + preview。映射到 hermes 标准 reply_to 字段,
        # 让 LLM 通过 reply_to_text 拿到被引用消息作为上下文。
        quote = data.get("quote") if isinstance(data, dict) else None
        reply_to_message_id = quote.get("message_id") if isinstance(quote, dict) else None
        reply_to_text = quote.get("preview") if isinstance(quote, dict) else None

        source = self.build_source(
            chat_id=conv_id,           # 单轨化:chat_id = conversation_id(对齐 hermes 上游)
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
            reply_to_message_id=reply_to_message_id,
            reply_to_text=reply_to_text,
        )

        await self.handle_message(event)

    # ── 聚合卡 adapter 接口（aggregate_card 模块回调） ───────────────

    def enqueue_aggregate_event(self, event: dict) -> None:
        """线程安全入队一个聚合卡事件（hook worker 线程调用）。"""
        try:
            self.aggregate_events.put_nowait(event)
        except Exception:
            logger.debug("Wanling aggregate event queue full, dropped %s", event.get("kind"))

    def lookup_conv_by_user(self, user_id: str) -> str:
        """user_id → conv_id 反查（聚合卡建卡定位会话用）。"""
        with self._user_conv_lock:
            conv_id = self._user_conv.get(user_id, "")
        if conv_id:
            return conv_id
        # miss 兜底：agent 视角 findOrCreate（对齐 send_exec_approval 注释的双来源）。
        try:
            conv_id = self._find_or_create_conv_sync(user_id)
            if conv_id:
                with self._user_conv_lock:
                    self._user_conv[user_id] = conv_id
        except Exception as e:
            logger.debug("Wanling lookup_conv_by_user HTTP fallback failed: %s", e)
        return conv_id

    def aggregate_token(self) -> str:
        """最新 agent JWT（每次 REST 请求取最新，防 TTL 过期）。"""
        return self._token or ""

    def refresh_aggregate_token(self) -> str:
        """重换 agent JWT（聚合卡 REST 401 重试用）。失败沿用旧 token。"""
        try:
            self._token = _exchange_token(self.server_url, self.agent_id, self.secret_key)
        except Exception as e:
            logger.warning("Wanling: refresh agent token failed — %s", e)
        return self._token or ""

    def last_user_msg_id(self, conv_id: str) -> str:
        """最近用户消息 id（聚合卡建卡引用锚点）。"""
        return self._last_user_msg.get(conv_id, "")

    # ── 流式编辑 REST 通道（对齐 aggregate_card 传输层） ──────────────────

    def _ensure_rest_conn(self) -> http.client.HTTPConnection:
        # 部署契约与 aggregate_card 相同：server_url 无 path 前缀。
        if self._rest_conn is None:
            parsed = urlparse(self.server_url)
            is_tls = parsed.scheme == "https"
            cls = http.client.HTTPSConnection if is_tls else http.client.HTTPConnection
            self._rest_conn = cls(
                parsed.hostname or "localhost",
                parsed.port or (443 if is_tls else 80),
                timeout=_aggregate_card.REST_TIMEOUT_S,
            )
        return self._rest_conn

    def _rest_close(self) -> None:
        """关闭 keep-alive 连接（disconnect / 传输错误重建时调）。"""
        if self._rest_conn is not None:
            try:
                self._rest_conn.close()
            except Exception:
                pass
            self._rest_conn = None

    def _rest_sync(self, method: str, path: str, body: Optional[dict]) -> Optional[Dict[str, Any]]:
        """同步 REST（从不抛异常）：keep-alive 断连重建重试一次 + 401 刷新 token 重试一次。"""
        payload = json.dumps(body).encode() if body is not None else None
        for attempt in (1, 2):
            conn = self._ensure_rest_conn()
            token = self.aggregate_token()
            try:
                conn.request(
                    method, path, body=payload,
                    headers={
                        "Content-Type": "application/json",
                        **({"Authorization": f"Bearer {token}"} if token else {}),
                    },
                )
                resp = conn.getresponse()
                raw = resp.read()  # 必须读干才能复用连接
            except (http.client.HTTPException, OSError) as e:
                self._rest_close()
                if attempt == 2:
                    logger.error("Wanling REST %s %s failed — %s", method, path, e)
                    return None
                continue
            if resp.status == 401 and attempt == 1:
                try:
                    self.refresh_aggregate_token()
                except Exception as e:
                    logger.warning("Wanling REST refresh token failed — %s", e)
                else:
                    continue
            if not raw:
                return {"ok": 200 <= resp.status < 300}
            try:
                return json.loads(raw)
            except Exception:
                return {"ok": False}
        return None

    async def _rest(self, method: str, path: str, body: Optional[dict]) -> Optional[Dict[str, Any]]:
        return await asyncio.to_thread(self._rest_sync, method, path, body)

    def _remember_edit_meta(self, msg_id: str, data: Optional[Dict[str, Any]]) -> None:
        """登记 message_id → data（虚拟 id 存 None）。超容量淘汰最旧条目。"""
        self._edit_meta[msg_id] = data
        while len(self._edit_meta) > 200:
            oldest = next(iter(self._edit_meta))
            self._edit_meta.pop(oldest, None)

    def _find_or_create_conv_sync(self, user_id: str) -> str:
        """POST /api/agents/me/conversations（agent 视角 findOrCreate）→ conv_id。"""
        if not self._token:
            return ""
        req = urllib.request.Request(
            f"{self.server_url.rstrip('/')}/api/agents/me/conversations",
            data=json.dumps({"user_id": user_id}).encode(),
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {self._token}",
            },
            method="POST",
        )
        data = _safe_request(req, "find_or_create_conv", timeout=15)
        if isinstance(data, dict):
            return str(data.get("conversation_id") or data.get("id") or "")
        return ""

    # ── Approval (agent → user 卡片决策) ─────────────────────────────────

    async def _on_permission_reply(self, conv_id: str, data: dict) -> None:
        """APP 聚合卡内 permission_card 按钮点击（permission_reply 消息）。

        reply 选项（APP 端）：once | always | reject。
        - 映射 hermes choice：once→once, always→always, reject→deny
        - 调 resolve_gateway_approval 唤醒 hermes 审批队列（session_key=oc_request_id）
        - emit permission_decided 更新聚合卡内 permission_card 元素状态
        """
        if not _aggregate_card._aggregate_enabled():
            return
        oc_request_id = str(data.get("oc_request_id") or "")
        reply = str(data.get("reply") or "")
        if not oc_request_id or not reply:
            logger.warning("Wanling: permission_reply 缺字段 conv=%s data=%s", conv_id, data)
            return

        choice = {"once": "once", "always": "always", "reject": "deny"}.get(reply)
        if choice is None:
            logger.warning("Wanling: permission_reply 未知 reply %r", reply)
            return

        try:
            from tools.approval import resolve_gateway_approval
            count = resolve_gateway_approval(oc_request_id, choice)
            logger.info(
                "Wanling: permission_reply resolved %d approval(s) session=%s (reply=%s)",
                count, oc_request_id, reply,
            )
        except Exception as e:
            logger.error("Wanling: permission_reply resolve failed session=%s: %s", oc_request_id, e)

        _aggregate_card.emit_event({
            "kind": "permission_decided",
            "conv_id": conv_id,
            "session_key": oc_request_id,
            "decision": reply,
        })

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

    async def send_exec_approval(
        self,
        chat_id: str,
        command: str,
        session_key: str,
        description: str = "dangerous command",
        metadata: Optional[Dict[str, Any]] = None,
        allow_permanent: bool = True,
        allow_session: bool = True,
        smart_denied: bool = False,
    ) -> SendResult:
        """发起命令审批卡片（hermes gateway 的跨平台契约）。

        allow_permanent / allow_session / smart_denied 为 hermes 新版
        gateway 契约入参：控制卡片是否提供 session/always 长期放行选项
        （Tirith 安全扫描会禁掉 permanent），smart_denied 表示智能审核
        已判 DENY。Wanling 卡片由 server 端渲染动作按钮，此处仅透传
        语义不影响流程，留参保持向后兼容。

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

        # chat_id 就是 conv_id(单轨化)
        conv_id = chat_id

        # 聚合卡激活：审批卡嵌入聚合卡（permission_card 元素），不建独立审批卡。
        # 纯 plugin 端实现（server/APP 协议不变）：跳过 server 审批创建（避免独立
        # 卡消息），emit permission_card 元素 → hermes queue 等待；用户点 APP 按钮
        # 发 permission_reply → _on_message_create 调 resolve_gateway_approval 唤醒。
        if _aggregate_card._aggregate_enabled() and _aggregate_card.get_active_by_conv(conv_id) is not None:
            _aggregate_card.emit_event({
                "kind": "permission_card",
                "conv_id": conv_id,
                "session_key": session_key,  # oc_request_id 用 session_key 定位
                "action": description or "command",
                "resources": [command],
                "title": "命令执行审批",
            })
            return SendResult(success=True, message_id=session_key)

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

        # chat_id 就是 conv_id(单轨化)
        conv_id = chat_id

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
        return _safe_request(req, "create_approval", timeout=15)

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

        # 两类媒体在 markdown 文本里需在发送前处理：
        # 1. 本地图片路径（裸 /xxx.jpg）→ 上传 + 发独立 image 消息 + 从 content 删除
        #    （_strip_and_send_local_images，处理 hermes 不识别本地路径的盲区）
        # 2. 远程图片 URL（![alt](https://...)）→ 下载上传 + 替换为内部 /api/files/
        #    URL（_rewrite_remote_images，处理 hermes extract_images 漏掉无扩展名 URL 的逃逸）
        # 聚合卡模式的图片处理在 consumer 侧（_rewrite_images_for_card，图进卡元素），
        # 不走此处的独立气泡路径——两行已下移到 take_conv_text/interim 分支之后。

        # 上传 + 发送图片后可能只剩空白（LLM 整段都在描述图片），跳过 markdown 发送
        if not content.strip():
            virtual = uuid.uuid4().hex[:12]
            self._remember_edit_meta(virtual, None)
            return SendResult(success=True, message_id=virtual)

        # 对齐 hermes 落库行为(conversation_loop 最终响应 strip):流式帧原样转发
        # 会带上模型 reasoning→正文 的前导空行(如 deepseek 系 "\n\n正文"),
        # 发送前整体 strip,避免 APP 消息/聚合卡正文顶部出现多余空行。
        # 仅清理两端空白,不影响 markdown 语义(引号块/代码块内空格保留)。
        content = content.strip()

        # 聚合卡接管正文：post_llm_call hook 已把正文追加为聚合卡 markdown 元素，
        # gateway 稍后调 send() 发同一正文 → 抑制独立气泡防双发（图片已在上方发出）。
        # 命中即清除标记（一次性），非聚合卡场景标记不存在 → 照常发送。
        if _aggregate_card.take_conv_text(chat_id):
            logger.debug("Wanling: aggregate card 接管正文，抑制独立气泡 conv=%s", chat_id)
            virtual = uuid.uuid4().hex[:12]
            self._remember_edit_meta(virtual, None)
            return SendResult(success=True, message_id=virtual)

        # 聚合卡激活期间的中间文本（hermes commentary/interim，如「我来看看」）：
        # 实时进聚合卡 markdown 元素（strip 流式 cursor），让卡片逐步构建。
        # 最终正文由 post_llm_call 的 assistant_response 追加（上面 take_conv_text 抑制）。
        _active = _aggregate_card.get_active_by_conv(chat_id)
        if _active is not None:
            text = content.rstrip()
            # strip 流式 cursor（hermes DEFAULT_STREAMING_CURSOR = " ▉"）
            if text.endswith("\u2589"):
                text = text.rstrip().rstrip("\u2589").rstrip()
            if text.strip():
                _aggregate_card.emit_event({
                    "kind": "markdown_update",
                    "session_id": _active.session_id,
                    "turn_id": "",
                    "text": text,
                })
            virtual = uuid.uuid4().hex[:12]
            self._remember_edit_meta(virtual, None)
            return SendResult(success=True, message_id=virtual)

        # 气泡路径图片处理（聚合卡接管/interim 分支已在上方 return，不会走到这）：
        # 本地路径 → 独立 image 气泡（msg_type=image）；远程 URL → 改写内嵌。
        content = await self._strip_and_send_local_images(chat_id, content)
        content = await self._rewrite_remote_images(content)

        # reply_to 由 hermes 上游 _reply_anchor_for_event 自动填 = 触发本次回复的
        # user 消息 id(对齐飞书 / Telegram 等 18 平台的「回复锚点」语义)。注入到
        # content.data.quote,server enrichQuote 富化 sender_name / preview 后,APP
        # 端在 agent 回复气泡上方渲染引用块。这是 IM 标准交互,不需要 LLM 知道 id。
        data: Dict[str, Any] = {"text": content}
        if reply_to:
            data["quote"] = {"message_id": reply_to}

        # 走 REST 同步建消息（对齐聚合卡/审批卡的 SendAsAgent 通道）：
        # 拿到 server 分配的真实 message_id 返回给 hermes stream consumer，
        # 后续流式帧经 edit_message() PATCH 同一条消息（原地更新）。
        # 旧 WS 路径 fire-and-forget 无回执，consumer 只拿到假 id 无法编辑，
        # edit 失败后 fallback 只能发「续文新消息」→ 一条回复被拆成两条
        # （首帧带 ▉ + 续文，引用块也随首帧滞留）。
        resp = await self._rest(
            "POST", f"/api/conversations/{chat_id}/messages",
            {"content": {"msg_type": "markdown", "data": data}},
        )
        if not (resp and resp.get("ok")):
            return SendResult(success=False, error=f"REST create 失败: {resp}")
        msg_id = str((resp.get("data") or {}).get("message_id") or "")
        if not msg_id:
            return SendResult(success=False, error="REST create 响应缺 message_id")
        # 登记建消息时的 data：edit_message PATCH 全量替换时回填 quote 等元数据
        self._remember_edit_meta(msg_id, dict(data))
        return SendResult(success=True, message_id=msg_id)

    async def edit_message(
        self,
        chat_id: str,
        message_id: str,
        content: str,
        *,
        finalize: bool = False,
    ) -> SendResult:
        """流式续帧：PATCH 同一条消息原地更新（consumer 每 ~0.8s 一次全量快照）。

        依赖 send() 走 REST 建消息拿到的真实 id + _edit_meta 映射：
        - 真实 id → PATCH /api/messages/:id 全量替换（回填建消息时的 quote），
          消息不再被拆成「首帧 + 续文」两条，▉ cursor 随终稿消失。
        - 虚拟 id（meta=None，正文被聚合卡接管）→ 续帧实时进聚合卡 markdown
          元素（流式 build），不 PATCH。
        - 未知 id（adapter 重启丢映射）→ 显式失败，consumer 走 fallback。
        """
        text = (content or "").strip()
        # 每帧都是全量替换快照，strip 必须每帧做：否则首个 PATCH 会把首帧
        # send() 已清掉的前导空行（reasoning→正文 \n\n）带回来。
        if finalize:
            # 终稿防御性去流式 cursor + 尾部空白（中间帧保留 cursor 作输入中指示）
            text = text.rstrip().rstrip("\u2589").rstrip()
        meta = self._edit_meta.get(message_id)

        if message_id not in self._edit_meta:
            return SendResult(success=False, error=f"unknown message_id: {message_id}")

        if meta is None:
            # 虚拟 id：聚合卡接管正文 → 续帧进卡（markdown 元素流式 build）
            _active = _aggregate_card.get_active_by_conv(chat_id)
            if _active is not None and text:
                _aggregate_card.emit_event({
                    "kind": "markdown_update",
                    "session_id": _active.session_id,
                    "turn_id": "",
                    "text": text,
                })
            if finalize:
                self._edit_meta.pop(message_id, None)
            return SendResult(success=True, message_id=message_id)

        if not text:
            # 空白终稿（不应发生，consumer 已前置过滤）→ 不发空 PATCH
            if finalize:
                self._edit_meta.pop(message_id, None)
            return SendResult(success=True, message_id=message_id)

        # PATCH 全量替换：回填建消息时的元数据（quote 引用块），text 换新快照
        data = {**meta, "text": text}
        resp = await self._rest(
            "PATCH", f"/api/messages/{message_id}",
            {"content": {"msg_type": "markdown", "data": data}},
        )
        ok = bool(resp and resp.get("ok"))
        if finalize:
            # 终稿后不再编辑：清理映射防泄漏
            self._edit_meta.pop(message_id, None)
        if not ok:
            return SendResult(success=False, error=f"PATCH 失败: {resp}")
        return SendResult(success=True, message_id=message_id)

    # 匹配本地图片绝对路径（/...jpg|png|gif|webp|bmp）。不匹配 http(s):// URL
    # （远程图片由下方 _REMOTE_IMAGE_RE + _rewrite_remote_images 处理）。
    # 否定后顾排除 : 防 https:// 被误匹配（: 后第一个 /）。
    _LOCAL_IMAGE_RE = re.compile(
        r"(?<![\w/:])(?P<path>/[\w./\-]+\.(?:jpg|jpeg|png|gif|webp|bmp))",
        re.IGNORECASE,
    )

    # markdown 包裹的本地图片 ![alt](/path.png)——聚合卡改写需先于裸路径处理，
    # 替换时保留 markdown 结构（只换括号内路径），避免二次包裹。
    _LOCAL_MD_IMAGE_RE = re.compile(
        r"!\[(?P<alt>[^\]]*)\]\((?P<path>/[\w./\-]+\.(?:jpg|jpeg|png|gif|webp|bmp))\)",
        re.IGNORECASE,
    )

    # 匹配 markdown 远程图片 ![alt](http(s)://...)。
    # 与 hermes 上游 extract_images 刻意不同：上游只提取带图片扩展名的 URL
    # （.png/.jpg/...），picsum.photos/300/200 这类无扩展名 URL 会漏网逃逸到
    # markdown 文本，APP 渲染端砍了网络图（SSRF 防护），用户只看到文字占位。
    # 这里不限扩展名，兜住所有 http(s) 图片 URL。只匹配 ![]() 图片语法，
    # 不碰裸 URL，避免误转正文里的网页/文档链接。
    _REMOTE_IMAGE_RE = re.compile(
        r"!\[(?P<alt>[^\]]*)\]\((?P<url>https?://[^\s\)]+)\)"
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
                        "conversation_id": chat_id,
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

    async def _rewrite_remote_images(self, content: str) -> str:
        """把 markdown 里的远程图片 URL 下载上传，替换为内部 /api/files/ 链接。

        背景：hermes 上游 extract_images 只提取带图片扩展名的 URL，picsum.photos
        这类无扩展名 URL 会逃逸到 markdown 文本。APP 渲染端砍了网络图（SSRF
        防护），只渲染 /api/files/ 前缀的内部 URL。这里兜底下载上传，让用户
        在 APP 看到真实图（图文同气泡）。

        策略（串行）：
          - 下载 cache_image_from_url（自带 SSRF 防护）→ _upload_file 拿 file_id
          - 成功：把 ![alt](外部URL) 替换为 ![alt](/api/files/{file_id})
          - 失败：原 URL 原样保留（APP 端文字占位兜底，不静默吞）
        """
        if not content:
            return content

        matches = list(self._REMOTE_IMAGE_RE.finditer(content))
        if not matches:
            return content

        for m in matches:
            url = m.group("url")
            alt = m.group("alt")
            # 下载远程图到本地缓存（is_safe_url + 重定向守卫，自带 SSRF 防护）。
            # cache_image_from_url 是 async 函数，直接 await，不要用 asyncio.to_thread
            # （to_thread 传 async 函数只返回未 await 的协程对象，下载不会真正发生）。
            try:
                local_path = await cache_image_from_url(url)
            except Exception as e:
                logger.warning("Wanling.send: download remote image failed, keep URL — %s (%s)", url, e)
                continue
            # 上传 server 拿内部 file_id
            file_id = await self._upload_file(local_path)
            if not file_id:
                logger.warning("Wanling.send: upload remote image failed, keep URL — %s", url)
                continue
            # 替换为内部 URL，APP 渲染端只放行 /api/files/ 前缀
            content = content.replace(
                m.group(0),
                f"![{alt}](/api/files/{file_id})",
            )

        return content

    # 聚合卡改写的上传 memo 容量上限（key=本地路径或远程 URL → file_id），
    # 溢出清空。对齐 _edit_meta 的防长连泄漏策略。
    _IMAGE_MEMO_CAP = 64

    async def _rewrite_images_for_card(self, content: str) -> str:
        """聚合卡模式图片改写：本地路径与远程图统一替换为 /api/files/ 内部链接。

        与气泡路径（_strip_and_send_local_images / _rewrite_remote_images）的
        区别——双模式区分的核心：不发独立 image 气泡、不从正文删除路径，而是
        就地替换成 markdown 图，图文一体进卡（APP 卡内 markdown 元素已支持
        /api/files/ 渲染 + 点击放大）。由聚合卡 consumer（_dispatch_event）对
        markdown / markdown_update 事件调用，在 consumer 侧做的原因：上传耗时
        只拖慢本卡 PATCH，不阻塞 WS 心跳与 agent worker 线程。

        memo 去重：interim 流式快照会重复携带同一路径，memo 保证只上传一次。
        失败降级：文件不存在/下载/上传失败 → 原文保留（卡里看到路径/外链兜底，
        不静默吞），与气泡路径的失败语义一致。
        """
        if not content:
            return content
        # 自检用 __new__ 构造（跳过 __init__），memo 惰性初始化兜底
        memo = getattr(self, "_image_upload_memo", None)
        if memo is None:
            memo = {}
            self._image_upload_memo = memo

        async def _resolve(key: str, local_path: Optional[str], url: Optional[str]) -> Optional[str]:
            """memo 查询 + 上传（本地直接传；远程先 cache_image_from_url 下载）。"""
            if key in memo:
                return memo[key]
            if local_path is not None:
                file_id = await self._upload_file(local_path)
            else:
                try:
                    # cache_image_from_url 是 async：直接 await（to_thread 传
                    # async 函数只会拿到未 await 的协程对象，下载不会发生）。
                    cached = await cache_image_from_url(url)
                except Exception as e:
                    logger.warning(
                        "Wanling.card rewrite: download remote image failed, keep URL — %s (%s)",
                        url, e,
                    )
                    return None
                file_id = await self._upload_file(cached)
            if file_id:
                if len(memo) >= self._IMAGE_MEMO_CAP:
                    memo.clear()
                memo[key] = file_id
            return file_id

        # 1) markdown 包裹的本地图 ![alt](/path) → ![alt](/api/files/{fid})
        #    （先于裸路径处理，只换括号内路径，保 markdown 结构）
        for m in list(self._LOCAL_MD_IMAGE_RE.finditer(content)):
            path = m.group("path")
            if not os.path.isfile(path):
                continue
            file_id = await _resolve(path, path, None)
            if file_id:
                content = content.replace(
                    m.group(0), f"![{m.group('alt')}](/api/files/{file_id})"
                )
        # 2) 裸本地路径 → ![basename](/api/files/{fid})
        for m in list(self._LOCAL_IMAGE_RE.finditer(content)):
            path = m.group("path")
            if not os.path.isfile(path):
                continue
            file_id = await _resolve(path, path, None)
            if file_id:
                content = content.replace(
                    path, f"![{os.path.basename(path)}](/api/files/{file_id})"
                )
        # 3) 远程图 ![alt](http...) → 下载转存 → ![alt](/api/files/{fid})
        for m in list(self._REMOTE_IMAGE_RE.finditer(content)):
            url = m.group("url")
            file_id = await _resolve(url, None, url)
            if file_id:
                content = content.replace(
                    m.group(0), f"![{m.group('alt')}](/api/files/{file_id})"
                )
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
        data = _safe_request(req, "upload_file", timeout=30)
        return data.get("id") if isinstance(data, dict) else None

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
        # 1. 解析路径：本地文件优先，http(s) 走 hermes 缓存工具下载。
        # cache_image_from_url 是 async 函数，直接 await（to_thread 传 async 函数无效）。
        local_path: Optional[str] = None
        try:
            if os.path.isfile(image_url):
                local_path = image_url
            elif image_url.startswith(("http://", "https://")):
                local_path = await cache_image_from_url(image_url)
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
                    "conversation_id": chat_id,
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
                    "conversation_id": chat_id,
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
    """Seed PlatformConfig.extra + home_channel from env vars.

    home_conv 由 install.sh 写入(pairing 模式从响应取,默认模式内部 find_or_create)。
    用户不直接填 conv_id(UUID 不友好)。
    """
    agent_id = os.getenv("WANLING_AGENT_ID")
    if not agent_id:
        return None
    extra: Dict[str, Any] = {
        "server_url": os.getenv("WANLING_SERVER_URL", "http://localhost:18008"),
        "agent_id": agent_id,
        "secret_key": os.getenv("WANLING_SECRET_KEY", ""),
    }
    home_conv = os.getenv("WANLING_HOME_CONV", "")
    home_channel = {"chat_id": home_conv, "name": "Wanling Home"} if home_conv else None
    return {"extra": extra, "home_channel": home_channel}


async def _standalone_send(
    pconfig,
    chat_id: str,
    message: str,
    thread_id: Optional[str] = None,
    media_files: Optional[list] = None,
    force_document: bool = False,
    **_extra,
) -> dict:
    """Out-of-process send for cron delivery: spin up a minimal WS client.

    形参对齐 hermes 上游 send_message_tool 的调用约定（关键字传参）：
    thread_id / media_files / force_document。本平台是一对一 IM（user_id 即
    会话），且 standalone 是轻量 WS 直发 markdown，不处理线程分流与媒体附件，
    这三者接下后忽略。`**_extra` 兜底上游未来新增参数，避免再次签名不匹配崩。
    """
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
                        "conversation_id": chat_id,
                        "content": {"msg_type": "markdown", "data": {"text": message}},
                    },
                }))
                return {"success": True}
            finally:
                task.cancel()
    except Exception as e:
        return {"error": str(e)}


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
        cron_deliver_env_var="WANLING_HOME_CONV",
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

    # 聚合卡：注册 hermes 生命周期 hook（raft 插件同款机制，不碰主程序）。
    # hook 在 agent worker 线程同步执行，仅入队事件；建卡/PATCH 由 adapter
    # 事件循环的消费者 task 串行执行（aggregate_card.run_event_consumer）。
    ctx.register_hook("pre_llm_call", _on_pre_llm_call)
    ctx.register_hook("pre_tool_call", _on_pre_tool_call)
    ctx.register_hook("post_tool_call", _on_post_tool_call)
    ctx.register_hook("post_llm_call", _on_post_llm_call)
    # post_api_request：每次 LLM 调用完成后触发（非回合末），kwargs 直接透传
    # 原始 assistant_message（NormalizedResponse，含该轮 reasoning）。用它把
    # 真实思考增量 PATCH 到聚合卡 reasoning 元素（段落级实时，不等回合结束）。
    ctx.register_hook("post_api_request", _on_post_api_request)
    # on_session_end：post_llm_call 的兜底——用户 /stop 中断时 hermes 的
    # post_llm_call 不触发（interrupted 守卫），但 on_session_end 每次回合都触发
    # （带 interrupted 标志），用它收尾活跃聚合卡（避免卡 generating + silent）。
    ctx.register_hook("on_session_end", _on_session_end)
    logger.info(
        "Wanling[DBG]: register() 完成，已注册 5 个 lifecycle hook (register_hook 支持=%s)",
        hasattr(ctx, "register_hook"),
    )


# ── 聚合卡 hook（模块级，worker 线程同步执行，仅入队事件） ──────────

# hermes 后台 review 回合（memory/skill 回顾，非用户主动发起）的 user_message 前缀。
# 这些回合不应产生聚合卡（review 输出走 hermes 原本的独立消息路径，不影响其功能）。
_REVIEW_TURN_PREFIX = "Review the conversation above"
# turn_id → True（review 回合标记，供工具/收尾事件跳过）。
_REVIEW_TURNS: set = set()
_REVIEW_TURNS_LOCK = threading.Lock()


def _is_review_turn(turn_id: str) -> bool:
    if not turn_id:
        return False
    with _REVIEW_TURNS_LOCK:
        return turn_id in _REVIEW_TURNS


def _platform_is_wanling(**kwargs) -> bool:
    return str(kwargs.get("platform") or "") == "wanling"


def _on_pre_llm_call(**kwargs) -> None:
    """LLM 调用前：回合开始信号。建卡由消费者处理（首个事件幂等建卡）。

    hermes 后台 review 回合（memory/skill 回顾，user_message 以
    "Review the conversation above" 开头）不建聚合卡：标记该 turn，
    后续工具/收尾事件跳过；review 输出走 hermes 原本的独立消息路径。
    """
    if not _aggregate_card._aggregate_enabled():
        return
    if not _platform_is_wanling(**kwargs):
        return
    session_id = kwargs.get("session_id") or ""
    user_message = str(kwargs.get("user_message") or "")
    if user_message.startswith(_REVIEW_TURN_PREFIX):
        turn_id = kwargs.get("turn_id") or ""
        with _REVIEW_TURNS_LOCK:
            _REVIEW_TURNS.add(turn_id)
        return
    sender_id = kwargs.get("sender_id") or ""
    _aggregate_card.remember_session_sender(session_id, sender_id)
    _aggregate_card.emit_event({
        "kind": "pre_llm_call",
        "session_id": session_id,
        "turn_id": kwargs.get("turn_id") or "",
        "sender_id": sender_id,
    })


def _on_post_api_request(**kwargs) -> None:
    """每次 LLM 调用完成：把该轮真实思考增量更新到聚合卡 reasoning 元素。

    段落级实时（非逐 token）：post_api_request 在每轮 LLM API 调用返回后触发
    （conversation_loop 工具循环内），kwargs 直接透传原始 assistant_message
    （NormalizedResponse 对象），其 reasoning / reasoning_content 含该轮完整思考。
    回合末 post_llm_call 仍会用完整 reasoning 覆盖定稿（finished=true）。
    """
    if not _aggregate_card._aggregate_enabled():
        return
    if not _platform_is_wanling(**kwargs):
        return
    if _is_review_turn(kwargs.get("turn_id") or ""):
        return
    session_id = kwargs.get("session_id") or ""
    if not session_id:
        return
    am = kwargs.get("assistant_message")
    if am is None:
        return
    # reasoning 提取兼容各 provider/路径（getattr 兼容对象与 dict）：
    # - 非流式 chat_completions / anthropic / codex / bedrock → 顶层 reasoning
    # - 流式 chat_completions → 仅 reasoning_content（provider_data）
    reasoning = (
        getattr(am, "reasoning", None)
        or getattr(am, "reasoning_content", None)
        or ""
    )
    if not isinstance(reasoning, str):
        reasoning = str(reasoning)
    if not reasoning.strip():
        return  # 纯工具轮无思考（或非思考模型），跳过
    _aggregate_card.emit_event({
        "kind": "reasoning_delta",
        "session_id": session_id,
        "turn_id": kwargs.get("turn_id") or "",
        "text": reasoning,
    })


def _on_pre_tool_call(**kwargs) -> None:
    """工具调用开始：tool_card 元素 starting。"""
    if not _aggregate_card._aggregate_enabled():
        return
    if _is_review_turn(kwargs.get("turn_id") or ""):
        return
    # pre_tool_call 无 platform 字段（raft 用 session 记忆；我们只认 wanling
    # 会话已注册的 session_id，非 wanling 会话不会出现在我们的注册表）。
    session_id = kwargs.get("session_id") or ""
    if not session_id:
        return
    if _aggregate_card.get_session(session_id) is None and not _aggregate_card.get_session_sender(session_id):
        return
    _aggregate_card.emit_event({
        "kind": "tool_start",
        "session_id": session_id,
        "turn_id": kwargs.get("turn_id") or "",
        "tool_name": kwargs.get("tool_name") or "",
        "args": kwargs.get("args"),
        "sender_id": _aggregate_card.get_session_sender(session_id),
    })


def _on_post_tool_call(**kwargs) -> None:
    """工具调用结束：tool_card 元素终态（含 output/error/duration）。"""
    if not _aggregate_card._aggregate_enabled():
        return
    if _is_review_turn(kwargs.get("turn_id") or ""):
        return
    session_id = kwargs.get("session_id") or ""
    if not session_id:
        return
    # 定位对应 tool_card 元素：pre_tool_call 已建卡，这里按工具名 + 序号
    # 匹配。pre/post 成对，且同一会话内按序出现，用单调计数区分同名工具。
    manager = _aggregate_card.get_session(session_id)
    if manager is None:
        return
    _aggregate_card.emit_event({
        "kind": "tool_end",
        "session_id": session_id,
        "turn_id": kwargs.get("turn_id") or "",
        "tool_name": kwargs.get("tool_name") or "",
        "args": kwargs.get("args"),
        "result": kwargs.get("result"),
        "status": kwargs.get("status") or "",
        "error_type": kwargs.get("error_type") or "",
        "error_message": kwargs.get("error_message") or "",
        "duration_ms": kwargs.get("duration_ms") or 0,
        "sender_id": _aggregate_card.get_session_sender(session_id),
    })


def _on_post_llm_call(**kwargs) -> None:
    """回合结束：追加 markdown 正文 + footer + 翻转 silent（计未读）。"""
    if not _aggregate_card._aggregate_enabled():
        return
    if not _platform_is_wanling(**kwargs):
        return
    if _is_review_turn(kwargs.get("turn_id") or ""):
        # review 回合不建聚合卡：释放 turn 标记（回合结束），不 emit 收尾。
        with _REVIEW_TURNS_LOCK:
            _REVIEW_TURNS.discard(kwargs.get("turn_id") or "")
        return
    session_id = kwargs.get("session_id") or ""
    if not session_id:
        return
    assistant_response = kwargs.get("assistant_response") or ""
    model = kwargs.get("model") or ""
    mode = kwargs.get("mode") or ""

    # 0) 回合末补全思考链：从 conversation_history 提取当前回合最后 assistant
    #    消息的 reasoning（对齐 hermes turn_finalizer 的 last_reasoning 逻辑，
    #    倒序遇 user 消息停，取最近的 reasoning 字段）。
    history = kwargs.get("conversation_history") or []
    reasoning_text = ""
    if isinstance(history, list):
        for _msg in reversed(history):
            if not isinstance(_msg, dict):
                continue
            if _msg.get("role") == "user":
                break
            if _msg.get("role") == "assistant" and _msg.get("reasoning"):
                reasoning_text = str(_msg["reasoning"])
                break

    # 正文已由聚合卡接管：标记 conv，让 gateway 后续的 adapter.send() 抑制独立气泡。
    # 仅当确实有正文时才接管（图片消息聚合卡元素不支持，走独立 image 气泡）。
    if str(assistant_response).strip():
        manager = _aggregate_card.get_session(session_id)
        logger.info(
            "Wanling[DBG]: post_llm_call session=%s manager=%s resp_len=%d reasoning_len=%d",
            session_id, "Y" if manager else "N", len(str(assistant_response)),
            len(reasoning_text),
        )
        if manager is not None:
            _aggregate_card.mark_conv_text_taken(manager.conv_id)
            # 0.1) 思考链 → 聚合卡 reasoning 元素
            if reasoning_text.strip():
                _aggregate_card.emit_event({
                    "kind": "reasoning",
                    "session_id": session_id,
                    "turn_id": kwargs.get("turn_id") or "",
                    "text": reasoning_text,
                })
            # 1) 正文 markdown → 聚合卡元素
            _aggregate_card.emit_event({
                "kind": "markdown",
                "session_id": session_id,
                "turn_id": kwargs.get("turn_id") or "",
                "text": str(assistant_response),
            })
    # 2) 回合收尾：footer + silent 翻转
    _aggregate_card.emit_event({
        "kind": "finish",
        "session_id": session_id,
        "turn_id": kwargs.get("turn_id") or "",
        "reason": "stop",
        "model": model or "",
        "mode": mode or "",
    })


def _on_session_end(**kwargs) -> None:
    """回合结束兜底（post_llm_call 不触发时）：用户 /stop 中断等场景。

    hermes 的 post_llm_call 在 interrupted 时不触发（`if final_response and not
    interrupted` 守卫），导致聚合卡收不了尾（卡 generating + silent）。on_session_end
    每次回合都触发（带 interrupted 标志），用它收尾活跃聚合卡：
    - interrupted=True → finish(reason="stop", stopped=True)（APP 显示「已停止」）
    - 正常结束但 post_llm_call 已处理 → 幂等跳过（finish 内部守卫）
    """
    if not _aggregate_card._aggregate_enabled():
        return
    if not _platform_is_wanling(**kwargs):
        return
    session_id = kwargs.get("session_id") or ""
    if not session_id:
        return
    manager = _aggregate_card.get_session(session_id)
    if manager is None or manager._finalized:
        return
    interrupted = bool(kwargs.get("interrupted"))
    if interrupted:
        _aggregate_card.emit_event({
            "kind": "finish",
            "session_id": session_id,
            "turn_id": kwargs.get("turn_id") or "",
            "reason": "stop",
            "stopped": True,
        })


# ---------------------------------------------------------------------------
# 自检脚本：python plugin/hermes-plugin/adapter.py
#
# 验证 _rewrite_remote_images 的核心行为，不依赖真实 server/网络：
# - monkeypatch cache_image_from_url（adapter 通过 import 持有该引用）/ _upload_file
# - 构造 WanlingAdapter 实例但不连接（_ws=None，_rewrite_remote_images 不碰 WS）
# ---------------------------------------------------------------------------
if __name__ == "__main__":
    import asyncio as _asyncio
    import sys as _sys
    from contextlib import contextmanager

    failures: List[str] = []

    def _check(cond: bool, msg: str) -> None:
        print(f"  [{'PASS' if cond else 'FAIL'}] {msg}")
        if not cond:
            failures.append(msg)

    def _asyncify(sync_fn):
        """把同步函数包成 async coroutine，匹配真实的 async 函数签名。"""
        async def _wrapper(*args, **kwargs):
            return sync_fn(*args, **kwargs)
        return _wrapper

    # adapter 顶部 `from gateway.platforms.base import cache_image_from_url` 把函数
    # 绑定到了本模块全局命名空间，_rewrite_remote_images 用的就是这个模块级引用。
    # 所以 patch 必须打在本模块（__main__）上，patch hermes 那边不生效。
    _self_module = _sys.modules[__name__]

    @contextmanager
    def _patch_download(sync_fake):
        """临时把本模块的 cache_image_from_url 换成假下载（包 async），退出还原。"""
        _orig = _self_module.cache_image_from_url
        _self_module.cache_image_from_url = _asyncify(sync_fake)
        try:
            yield
        finally:
            _self_module.cache_image_from_url = _orig

    def _make_adapter(sync_upload) -> "WanlingAdapter":
        """构造不连 server 的 adapter，注入（包了 async 的）假上传函数。"""
        adapter = WanlingAdapter.__new__(WanlingAdapter)
        adapter._ws = None
        adapter._upload_file = _asyncify(sync_upload)  # type: ignore[method-assign]
        return adapter

    def _make_send_adapter():
        """构造带假 REST 通道的 adapter，验证 send()/edit_message() 行为。

        calls 捕获 (method, path, body)；POST 返回递增真实 id（m1/m2/...），
        PATCH 返回 ok。聚合卡开关/活跃态默认不介入（fallback 直发路径）。
        媒体处理保持原样返回。
        """
        calls = []
        seq = {"n": 0}

        async def _fake_rest(method, path, body):
            calls.append((method, path, body))
            if method == "POST":
                seq["n"] += 1
                return {"ok": True, "data": {"message_id": f"m{seq['n']}"}}
            return {"ok": True}

        adapter = WanlingAdapter.__new__(WanlingAdapter)
        adapter._ws = object()  # 过 Not connected guard，不走 WS
        adapter._edit_meta = {}
        adapter._rest = _fake_rest  # type: ignore[method-assign]

        async def _identity_images(chat_id, content):
            return content

        async def _identity_rewrite(content):
            return content

        adapter._strip_and_send_local_images = _identity_images  # type: ignore[method-assign]
        adapter._rewrite_remote_images = _identity_rewrite  # type: ignore[method-assign]
        return adapter, calls

    async def _run_tests():
        print("== _rewrite_remote_images 自检 ==")

        # 用例 1：无扩展名远程图（picsum）成功 → 替换为内部 URL
        with _patch_download(lambda url: "/tmp/c.jpg"):
            out = await _make_adapter(lambda p: "fid1")._rewrite_remote_images(
                "示例图：\n![](https://picsum.photos/300/200)"
            )
        _check(
            "/api/files/fid1" in out and "picsum.photos" not in out,
            "picsum 无扩展名 URL 成功下载上传 → 替换为 /api/files/ 内部 URL",
        )

        # 用例 2：下载失败 → 原 URL 保留（不静默吞）
        def _boom(_u):
            raise RuntimeError("mock download failure")
        with _patch_download(_boom):
            out = await _make_adapter(lambda p: "fid")._rewrite_remote_images(
                "![](https://attacker.example/track.png)"
            )
        _check(
            "https://attacker.example/track.png" in out and "/api/files/" not in out,
            "下载失败 → 原 URL 保留",
        )

        # 用例 3：上传失败 → 原 URL 保留
        with _patch_download(lambda url: "/tmp/c.jpg"):
            out = await _make_adapter(lambda p: None)._rewrite_remote_images(
                "![](https://example.com/a.jpg)"
            )
        _check(
            "https://example.com/a.jpg" in out and "/api/files/" not in out,
            "上传失败 → 原 URL 保留",
        )

        # 用例 4：裸 URL 不被误转（只匹配 ![]() 图片语法）
        with _patch_download(lambda url: "/tmp/c.jpg"):
            out = await _make_adapter(lambda p: "fid")._rewrite_remote_images(
                "参考文档 https://example.com/doc 和 https://picsum.photos/300/200"
            )
        _check(
            "https://example.com/doc" in out and "https://picsum.photos/300/200" in out,
            "裸 URL（非 ![]() 语法）不被误转",
        )

        # 用例 5：alt 文本在替换后保留
        with _patch_download(lambda url: "/tmp/c.jpg"):
            out = await _make_adapter(lambda p: "abc123")._rewrite_remote_images(
                "![示意图](https://x.com/y.png)"
            )
        _check("[示意图]" in out, "alt 文本在替换后保留")

        # 用例 6：多张图串行处理各自替换
        seq = iter(["id_a", "id_b"])
        with _patch_download(lambda url: f"/tmp/{abs(hash(url))}.jpg"):
            out = await _make_adapter(lambda p: next(seq))._rewrite_remote_images(
                "![](https://a.com/1.png) ![](https://b.com/2.jpg)"
            )
        _check(
            "/api/files/id_a" in out and "/api/files/id_b" in out,
            "多张图串行处理各自替换",
        )

        # ── 聚合卡模式图片改写（_rewrite_images_for_card：图进卡元素，双模式区分） ──
        print("== _rewrite_images_for_card 自检 ==")

        # 用例 C1：markdown 包裹的本地图 → /api/files/（alt 保留）
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
            f.write(b"png-bytes")
            local_md = f.name
        try:
            out = await _make_adapter(lambda p: "fidA")._rewrite_images_for_card(
                f"![图表]({local_md})"
            )
            _check(out == f"![图表](/api/files/fidA)", "markdown 本地图改写且 alt 保留")
        finally:
            os.unlink(local_md)

        # 用例 C2：裸本地路径 → ![basename](/api/files/fid)
        with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as f:
            f.write(b"jpg-bytes")
            local_bare = f.name
        try:
            out = await _make_adapter(lambda p: "fidB")._rewrite_images_for_card(
                f"结果见 {local_bare} 以上"
            )
            base = os.path.basename(local_bare)
            _check(
                f"![{base}](/api/files/fidB)" in out and local_bare not in out,
                "裸本地路径改写为 markdown 图并移出正文",
            )
        finally:
            os.unlink(local_bare)

        # 用例 C3：本地图 + 远程图混合，各自替换
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
            f.write(b"png")
            local_mix = f.name
        try:
            seq_mix = iter(["fid1", "fid2"])
            with _patch_download(lambda url: "/tmp/mix-cache.jpg"):
                out = await _make_adapter(lambda p: next(seq_mix))._rewrite_images_for_card(
                    f"![]({local_mix}) 然后 ![](https://picsum.photos/300/200)"
                )
            _check(
                "/api/files/fid1" in out and "/api/files/fid2" in out
                and "picsum.photos" not in out and local_mix not in out,
                "本地图与远程图混合各自改写",
            )
        finally:
            os.unlink(local_mix)

        # 用例 C4：文件不存在 → 原文保留（幻觉路径不静默吞）
        out = await _make_adapter(lambda p: "fidX")._rewrite_images_for_card(
            "见 /nonexistent/ghost.png"
        )
        _check("/nonexistent/ghost.png" in out and "/api/files/" not in out, "文件不存在 → 原文保留")

        # 用例 C5：上传失败 → 原文保留
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
            f.write(b"png")
            local_fail = f.name
        try:
            out = await _make_adapter(lambda p: None)._rewrite_images_for_card(local_fail)
            _check(local_fail in out and "/api/files/" not in out, "上传失败 → 原文保留")
        finally:
            os.unlink(local_fail)

        # 用例 C6：memo 去重——同一 adapter 重复改写同一路径只上传一次
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
            f.write(b"png")
            local_memo = f.name
        try:
            calls = {"n": 0}

            def _counting_upload(_p):
                calls["n"] += 1
                return "fidMemo"

            ad = _make_adapter(_counting_upload)
            await ad._rewrite_images_for_card(f"![]({local_memo})")
            await ad._rewrite_images_for_card(f"![]({local_memo}) 第二次快照")
            _check(calls["n"] == 1, "memo 去重：同路径重复改写只上传一次")
        finally:
            os.unlink(local_memo)

        # 用例 C7：远程图下载失败 → 原 URL 保留
        def _boom(_u):
            raise RuntimeError("mock download failure")
        with _patch_download(_boom):
            out = await _make_adapter(lambda p: "fid")._rewrite_images_for_card(
                "![](https://attacker.example/track.png)"
            )
        _check(
            "https://attacker.example/track.png" in out and "/api/files/" not in out,
            "远程图下载失败 → 原 URL 保留",
        )

        # ── send()/edit_message() 流式直发路径（REST 建消息 + PATCH 原地更新） ──
        print("== send()/edit_message() 自检 ==")

        # 用例 7：前导 \n\n 清除 + 返回真实 message_id（REST 同步建消息）
        adapter, calls = _make_send_adapter()
        r = await adapter.send("conv-1", "\n\n2026年8月17日，周一", reply_to="msg-1")
        method, path, body = calls[0]
        _check(
            r.success and r.message_id == "m1"
            and method == "POST" and path == "/api/conversations/conv-1/messages",
            "REST 建消息返回真实 message_id",
        )
        _check(
            body["content"]["data"]["text"] == "2026年8月17日，周一",
            "前导 \\n\\n 被清除（reasoning→正文分段空行）",
        )

        # 用例 8：reply_to 注入 quote，且 strip 不影响
        _check(
            body["content"]["data"]["quote"] == {"message_id": "msg-1"},
            "reply_to 正常注入 quote（strip 不破坏引用）",
        )

        # 用例 9：内部空行保留、仅尾部空白清理
        adapter, calls = _make_send_adapter()
        await adapter.send("conv-2", "第一行\n\n第二行  ")
        _check(
            calls[0][2]["content"]["data"]["text"] == "第一行\n\n第二行",
            "内部空行保留、仅尾部空白清理",
        )

        # 用例 10：纯空白（图片处理后）不建消息（虚拟 id 不落 REST）
        adapter, calls = _make_send_adapter()
        r = await adapter.send("conv-3", "\n  \n")
        _check(
            calls == [] and r.success and r.message_id in adapter._edit_meta
            and adapter._edit_meta[r.message_id] is None,
            "纯空白正文不建消息（虚拟 id）",
        )

        # 用例 11：续帧 PATCH 同一条消息（quote 回填 + 前导空行每帧清理）
        adapter, calls = _make_send_adapter()
        r = await adapter.send("conv-4", "在呢", reply_to="msg-4")
        await adapter.edit_message("conv-4", r.message_id, "\n\n在呢\n\n（刚 ▉")
        method, path, body = calls[1]
        _check(
            method == "PATCH" and path == f"/api/messages/{r.message_id}"
            and body["content"]["data"]["text"] == "在呢\n\n（刚 ▉"
            and body["content"]["data"]["quote"] == {"message_id": "msg-4"},
            "续帧 PATCH 原消息：前导空行清理、中间帧保留 cursor、quote 回填",
        )

        # 用例 12：finalize 终稿去 cursor + 清理映射
        _in_edit_meta = r.message_id in adapter._edit_meta
        await adapter.edit_message("conv-4", r.message_id, "在呢\n\n（刚问你——要我修吗？） ▉", finalize=True)
        body = calls[2][2]
        _check(
            _in_edit_meta
            and body["content"]["data"]["text"] == "在呢\n\n（刚问你——要我修吗？）"
            and r.message_id not in adapter._edit_meta,
            "finalize 去 cursor/尾空白并清理映射",
        )

        # 用例 13：未知 id（重启丢映射）→ 显式失败让 consumer 走 fallback
        adapter, calls = _make_send_adapter()
        r = await adapter.edit_message("conv-5", "nonexistent", "文本")
        _check(
            not r.success and calls == [],
            "未知 message_id 显式失败（不盲 PATCH）",
        )

        # 用例 14：REST 建消息失败 → send 显式失败（consumer 下帧重试）
        adapter, calls = _make_send_adapter()

        async def _fail_rest(method, path, body):
            calls.append((method, path, body))
            return {"ok": False, "error": "boom"}

        adapter._rest = _fail_rest  # type: ignore[method-assign]
        r = await adapter.send("conv-6", "hello")
        _check(not r.success, "REST 建消息失败 → send 显式失败")

    async def _run_aggregate_tests():
        """聚合卡核心自检：mock adapter REST（io 边界），SDK AggregateCard 真跑。

        mock 边界在 adapter._rest（记录 wire 调用并返回结果），SDK AggregateCard
        与 _HermesAggregateIO 全程真实执行 —— 分卡/自愈/收尾状态机验证不打折。
        """
        agg = _aggregate_card

        class _MockServer:
            def __init__(self):
                self.cards, self.patches, self.counter = [], [], 0
                self.deletes = []
            def handle(self, method, path, body):
                if method == "POST" and "/messages" in path:
                    self.counter += 1
                    self.cards.append((path, body))
                    return {"ok": True, "data": {"message_id": f"msg-{self.counter}"}}
                if method == "PATCH":
                    self.patches.append((path.split("/")[-1], body))
                    return {"ok": True}
                if method == "DELETE":
                    self.deletes.append(path)
                    return {"ok": True}
                return {"ok": False}

        class _MockAdapter:
            """io 边界 mock：REST 走 _MockServer；fail_remaining>0 时增量
            PATCH（body 带 op）注入失败（模拟传输故障，驱动 SDK 降级自愈）。"""
            def __init__(self, srv):
                self._srv = srv
                self.fail_remaining = 0
            def aggregate_token(self):
                return "t"
            def lookup_conv_by_user(self, user_id):
                return "conv"
            async def _rest(self, method, path, body):
                data = (body or {}).get("content", {}).get("data") if isinstance(body, dict) else None
                if (
                    method == "PATCH"
                    and isinstance(data, dict)
                    and "op" in data
                    and self.fail_remaining > 0
                ):
                    self.fail_remaining -= 1
                    return {"ok": False, "error": "injected failure"}
                return self._srv.handle(method, path, body)

        _srv = _MockServer()
        _mock_adapter = _MockAdapter(_srv)

        def _ops():
            return [p[1]["content"]["data"] for p in _srv.patches]

        try:
            print("== 聚合卡自检 ==")
            # 建卡（SDK 幂等建卡 + reasoning 占位）
            await agg._dispatch_event(_mock_adapter, {"kind": "pre_llm_call", "session_id": "sess", "turn_id": "t1", "sender_id": "u"})
            _check(len(_srv.cards) == 1, "回合开始建 1 张卡")
            _check(_srv.cards[0][1]["content"]["data"]["state"] == "generating", "建卡 state=generating")
            _check(any(d.get("op") == "append" and d["element"]["type"] == "reasoning" for d in _ops()), "建卡 append reasoning 占位")
            # 工具开始
            await agg._dispatch_event(_mock_adapter, {"kind": "tool_start", "session_id": "sess", "turn_id": "t1", "tool_name": "bash", "args": {"command": "ls"}})
            _check(any(d.get("op") == "append" and d["element"]["type"] == "tool_card" for d in _ops()), "工具开始 append tool_card")
            # 工具结束（全量 data：SDK merge 后 wire 含 name/input/status/output）
            await agg._dispatch_event(_mock_adapter, {"kind": "tool_end", "session_id": "sess", "turn_id": "t1", "tool_name": "bash", "args": {"command": "ls"}, "result": "out", "status": "ok", "duration_ms": 500})
            upd = [d for d in _ops() if d.get("op") == "update"]
            _check(len(upd) == 1 and upd[0]["data"]["status"] == "completed" and upd[0]["data"]["output"] == "out", "工具结束 update tool_card（output/status）")
            _check(upd[0]["data"].get("name") == "bash" and upd[0]["data"].get("input") == {"command": "ls"}, "工具终态 update 全量传参（name/input 不丢，防旧卡整体替换丢字段）")
            # 审批卡嵌入聚合卡（特殊路由：按 conv_id 定位活跃 session）
            await agg._dispatch_event(_mock_adapter, {"kind": "permission_card", "conv_id": "conv", "session_key": "sk-1", "action": "dangerous command", "resources": ["rm -rf /"]})
            pc = [d for d in _ops() if d.get("op") == "append" and d["element"]["type"] == "permission_card"]
            _check(len(pc) == 1 and pc[0]["element"]["data"]["status"] == "pending" and pc[0]["element"]["data"]["oc_request_id"] == "sk-1", "审批卡嵌入 permission_card 元素（pending）")
            _check(any(d.get("op") == "set_silent" and d.get("silent") is False for d in _ops()), "审批 pending 翻转 silent=false 响铃（需用户介入）")
            # 审批决策（permission_reply once → approved）
            await agg._dispatch_event(_mock_adapter, {"kind": "permission_decided", "conv_id": "conv", "session_key": "sk-1", "decision": "once"})
            upd = [d for d in _ops() if d.get("op") == "update" and d.get("element_id", "").startswith("permission_card")]
            _check(len(upd) == 1 and upd[0]["data"]["status"] == "approved", "审批决策后 permission_card 状态 approved")
            _check(any(d.get("op") == "set_silent" and d.get("silent") is True for d in _ops()), "审批终态翻转 silent=true 恢复安静")
            # markdown：不同中间文本独立元素；相邻前缀重叠（最终正文=中间文本展开）合并
            await agg._dispatch_event(_mock_adapter, {"kind": "markdown_update", "session_id": "sess", "turn_id": "t1", "text": "刚抓的页面已经有 8月12日 的新内容了。提取一下："})
            await agg._dispatch_event(_mock_adapter, {"kind": "markdown_update", "session_id": "sess", "turn_id": "t1", "text": "8月12日 的热点来了（"})
            await agg._dispatch_event(_mock_adapter, {"kind": "markdown", "session_id": "sess", "turn_id": "t1", "text": "8月12日 的热点来了（AIHOT 已更新）：\n\n**🔥 头条**..."})
            md_appends = [d for d in _ops() if d.get("op") == "append" and d["element"]["type"] == "markdown"]
            md_updates = [d for d in _ops() if d.get("op") == "update" and str(d.get("element_id", "")).startswith("markdown")]
            _check(len(md_appends) == 2, f"不同中间文本独立元素（实际 {len(md_appends)}）")
            _check(len(md_updates) == 1 and md_updates[-1]["data"]["text"].startswith("8月12日 的热点来了（AIHOT 已更新）"), "最终正文与相邻中间文本前缀合并（update 展开版）")
            # reasoning 增量（post_api_request 每轮触发）：对齐 opencode 多思考块。
            append_before = len([d for d in _ops() if d.get("op") == "append" and d["element"]["type"] == "reasoning"])
            await agg._dispatch_event(_mock_adapter, {"kind": "reasoning_delta", "session_id": "sess", "turn_id": "t1", "text": "第一轮思考"})
            reasoning_updates = [d for d in _ops() if d.get("op") == "update" and d.get("element_id", "").startswith("reasoning")]
            reasoning_appends = [d for d in _ops() if d.get("op") == "append" and d["element"]["type"] == "reasoning"]
            _check(len(reasoning_updates) == 1 and reasoning_updates[-1]["data"]["finished"] is False and reasoning_updates[-1]["data"]["text"] == "第一轮思考" and len(reasoning_appends) == append_before, "首块 delta update 空占位(无新 append)")
            # 第二轮思考：前块标终态 + append 新块（finished=false）
            await agg._dispatch_event(_mock_adapter, {"kind": "reasoning_delta", "session_id": "sess", "turn_id": "t1", "text": "第二轮思考"})
            reasoning_updates = [d for d in _ops() if d.get("op") == "update" and d.get("element_id", "").startswith("reasoning")]
            reasoning_appends = [d for d in _ops() if d.get("op") == "append" and d["element"]["type"] == "reasoning"]
            _check(len(reasoning_updates) == 2 and reasoning_updates[-1]["data"]["finished"] is True and reasoning_updates[-1]["data"]["text"] == "第一轮思考", "第二轮 delta 前块标终态")
            _check(len(reasoning_appends) == append_before + 1 and reasoning_appends[-1]["element"]["data"]["finished"] is False and reasoning_appends[-1]["element"]["data"]["text"] == "第二轮思考", "第二轮 delta append 新块(finished=false)")
            # reasoning 终态（post_llm_call 回合末）：update 最后一个未终态块为 finished=true
            await agg._dispatch_event(_mock_adapter, {"kind": "reasoning", "session_id": "sess", "turn_id": "t1", "text": "最终思考"})
            reasoning_updates = [d for d in _ops() if d.get("op") == "update" and d.get("element_id", "").startswith("reasoning")]
            _check(len(reasoning_updates) == 3 and reasoning_updates[-1]["data"]["finished"] is True and reasoning_updates[-1]["data"]["text"] == "最终思考", "终态 reasoning 覆盖最后思考块为 finished=true")
            # 正文归位：最终正文后 reorder，markdown 移到末尾（reasoning/工具卡后）
            await agg._dispatch_event(_mock_adapter, {"kind": "markdown", "session_id": "sess", "turn_id": "t1", "text": "总结"})
            reorder_ops = [d for d in _ops() if d.get("op") == "reorder"]
            _check(len(reorder_ops) >= 1, "最终正文后发 reorder 归位")
            if reorder_ops:
                order = reorder_ops[-1]["order"]
                mcount = sum(1 for eid in order if eid.startswith("markdown"))
                last = order[-1]
                _check(
                    last.startswith("markdown")
                    and all(
                        (eid.startswith("tool_card") or eid.startswith("reasoning") or eid.startswith("permission_card"))
                        for eid in order[: len(order) - mcount]
                    ),
                    f"reorder 后 markdown 全部在末尾（order={order}）",
                )
            # 收尾
            await agg._dispatch_event(_mock_adapter, {"kind": "finish", "session_id": "sess", "turn_id": "t1", "model": "gpt-4o"})
            _check(any(d.get("op") == "append" and d["element"]["type"] == "markdown" for d in _ops()), "正文 append markdown")
            _check(any(d.get("op") == "append" and d["element"]["type"] == "footer" for d in _ops()), "收尾 append footer")
            _check(any(d.get("op") == "set_state" and d["state"] == "done" for d in _ops()), "收尾 set_state done")
            _check(any(d.get("op") == "set_silent" and d["silent"] is False for d in _ops()), "收尾 set_silent false（计未读）")
            _check(_srv.deletes == [], "有内容回合不撤回")
            # 断卡（interrupt）：用户新消息 → 当前卡 finish(interrupt) + 复位，下回合开新卡
            await agg._dispatch_event(_mock_adapter, {"kind": "pre_llm_call", "session_id": "s9", "turn_id": "t9", "sender_id": "u"})
            await agg._dispatch_event(_mock_adapter, {"kind": "tool_start", "session_id": "s9", "turn_id": "t9", "tool_name": "bash", "args": {}})
            _patches_before_interrupt = len(_srv.patches)
            _deletes_before = len(_srv.deletes)
            await agg._dispatch_event(_mock_adapter, {"kind": "interrupt", "conv_id": "conv"})
            _ops_interrupt = _ops()[_patches_before_interrupt:]
            _check(any(d.get("op") == "update" and d.get("element_id", "").startswith("tool_card") and d.get("data", {}).get("status") == "error" and d["data"].get("name") == "bash" for d in _ops_interrupt), "interrupt 把 running 工具卡标 error（全量 data 含 name）")
            _check(any(d.get("op") == "append" and d["element"]["type"] == "footer" and d["element"]["data"].get("reason") == "interrupt" for d in _ops_interrupt), "interrupt finish 带 reason=interrupt footer")
            _check(len(_srv.deletes) == _deletes_before, "interrupt 有内容卡不撤回")
            cards_before = len(_srv.cards)
            await agg._dispatch_event(_mock_adapter, {"kind": "pre_llm_call", "session_id": "s9", "turn_id": "t10", "sender_id": "u"})
            _check(len(_srv.cards) > cards_before, "interrupt 复位后下回合新建卡")
            _check(_srv.cards[-1][1]["content"]["data"]["state"] == "generating", "新卡 state=generating")
            await agg._dispatch_event(_mock_adapter, {"kind": "markdown", "session_id": "s9", "turn_id": "t10", "text": "第二条回复"})
            _check(any(d.get("op") == "append" and d["element"]["type"] == "markdown" and d["element"]["data"]["text"] == "第二条回复" for d in _ops()), "新卡承载第二条回复")
            await agg._dispatch_event(_mock_adapter, {"kind": "finish", "session_id": "s9", "turn_id": "t10", "model": "gpt-4o"})
            # finish 收尾兜底：假思考占位被 remove、running 工具卡标 error
            await agg._dispatch_event(_mock_adapter, {"kind": "pre_llm_call", "session_id": "s3", "turn_id": "t3", "sender_id": "u"})
            await agg._dispatch_event(_mock_adapter, {"kind": "tool_start", "session_id": "s3", "turn_id": "t3", "tool_name": "browser_snapshot", "args": {}})
            _p_before = len(_srv.patches)
            await agg._dispatch_event(_mock_adapter, {"kind": "finish", "session_id": "s3", "turn_id": "t3", "model": "gpt-4o"})
            ops3 = _ops()
            _check(any(d.get("op") == "remove" and d.get("element_id", "").startswith("reasoning") for d in ops3), "finish 移除假思考占位")
            _check(any(d.get("op") == "update" and d.get("element_id", "").startswith("tool_card") and d.get("data", {}).get("status") == "error" for d in ops3), "finish 兜底 running 工具卡标 error")
            _check(len(_srv.patches) > _p_before, "finish 兜底发 PATCH")
            # 空卡清理：回合只有占位（无内容），finish 后 DELETE recall
            _srv.deletes.clear()
            await agg._dispatch_event(_mock_adapter, {"kind": "pre_llm_call", "session_id": "s4", "turn_id": "t4", "sender_id": "u"})
            await agg._dispatch_event(_mock_adapter, {"kind": "finish", "session_id": "s4", "turn_id": "t4", "model": "gpt-4o"})
            _check(len(_srv.deletes) == 1 and "scope=recall" in _srv.deletes[0], "空卡（仅占位）finish 后 DELETE recall 撤回")
            _check(any(d.get("op") == "remove" and d.get("element_id", "").startswith("reasoning") for d in _ops()), "空卡占位 reasoning 被 remove")
            # 分卡 + 跨卡元素定位：元素超 20 自动切卡；旧卡元素 update 走归属映射 PATCH 旧卡
            _srv.cards.clear(); _srv.patches.clear()
            await agg._dispatch_event(_mock_adapter, {"kind": "pre_llm_call", "session_id": "s5", "turn_id": "t5", "sender_id": "u"})
            for _i in range(21):  # 21 个 markdown 段(建卡占位 reasoning_1 + markdown_2..markdown_22)
                await agg._dispatch_event(_mock_adapter, {"kind": "markdown", "session_id": "s5", "turn_id": "t5", "text": f"段{_i}"})
            _check(len(_srv.cards) == 2, f"元素超 20 分卡(建 {len(_srv.cards)} 张卡,应为 2)")
            # 分卡 seal 前置收尾：旧卡空占位被 remove（settle 语义保持）
            _check(any(d.get("op") == "remove" and d.get("element_id", "").startswith("reasoning") for d in _ops()), "分卡 seal 前收尾旧卡空占位（remove）")
            _m5 = agg.get_session("s5")
            # 分卡后旧卡元素(reasoning_1 落 msg-1)update → PATCH 到旧卡 msg-1(而非新卡 msg-2)
            _pb = len(_srv.patches)
            await _m5.update_element("reasoning_1", {"text": "x", "finished": True})
            _cross = _srv.patches[_pb:]
            _cu = [(mid, p) for mid, p in _cross if p["content"]["data"].get("op") == "update"]
            _check(len(_cu) == 1 and _cu[0][0] == _m5.io.element_cards.get("reasoning_1") and _cu[0][1]["content"]["data"]["element_id"] == "reasoning_1", f"分卡后旧卡元素 update 定位归属卡(实际 {_cu[0][0] if _cu else '无'})")
            # 分卡后 reorder 只作用于当前卡元素(旧卡元素不参与,不 400)。
            # 新卡先 append 一个 tool_card,验证 reorder 后 markdown 归位且旧卡元素排除。
            await agg._dispatch_event(_mock_adapter, {"kind": "tool_start", "session_id": "s5", "turn_id": "t5", "tool_name": "browser_click", "args": {}})
            _pb = len(_srv.patches)
            await _m5.reorder_markdown_to_end()
            _ro = _srv.patches[_pb:]
            _ro_ops = [p for p in _ro if p[1]["content"]["data"].get("op") == "reorder"]
            if _ro_ops:
                _order = _ro_ops[-1][1]["content"]["data"]["order"]
                _check(
                    any(eid.startswith("tool_card") for eid in _order)
                    and _order[-1].startswith("markdown")
                    and "reasoning_1" not in _order,
                    f"分卡后 reorder 当前卡元素归位、旧卡元素排除(order={_order})",
                )
            else:
                _check(False, "分卡后 reorder 应只作用当前卡")
            agg.unregister_session("s5")
            # 审批映射兜底：回合结束后（session 已注销）审批决策仍 PATCH 历史消息。
            agg.remember_permission_card("sk-1", "conv", "msg-1", "permission_card_3")
            _patch_before = len(_srv.patches)
            await agg._dispatch_event(_mock_adapter, {"kind": "permission_decided", "conv_id": "conv", "session_key": "sk-1", "decision": "reject"})
            _check(len(_srv.patches) > _patch_before, "session 注销后审批决策仍发 PATCH（映射兜底）")
            _check(any(p[1]["content"]["data"].get("op") == "update" and p[1]["content"]["data"].get("element_id", "").startswith("permission_card") and p[1]["content"]["data"]["data"]["status"] == "denied" for p in _srv.patches), "映射兜底 PATCH 更新 permission_card 为 denied")
            # 审批终态后清理持久映射（防泄漏）
            _rec = agg.get_permission_card("sk-1")
            _check(_rec is None, "审批终态后持久映射被清理（drop_permission_card）")
            # reorder 短路：markdown 已在末尾时不再发 reorder PATCH
            await agg._dispatch_event(_mock_adapter, {"kind": "pre_llm_call", "session_id": "s6", "turn_id": "t6", "sender_id": "u"})
            await agg._dispatch_event(_mock_adapter, {"kind": "tool_start", "session_id": "s6", "turn_id": "t6", "tool_name": "bash", "args": {}})
            await agg._dispatch_event(_mock_adapter, {"kind": "markdown", "session_id": "s6", "turn_id": "t6", "text": "正文"})
            _p6 = len(_srv.patches)
            await agg._dispatch_event(_mock_adapter, {"kind": "markdown", "session_id": "s6", "turn_id": "t6", "text": "正文"})
            _ro6 = [p for p in _srv.patches[_p6:] if p[1]["content"]["data"].get("op") == "reorder"]
            _check(len(_ro6) == 0, "markdown 已在末尾时 reorder 短路（不发 PATCH）")
            agg.unregister_session("s6")
            # 降级自愈：连续 3 次增量 PATCH 失败 → SDK 全量替换（影子副本覆盖）+
            # 窗口内 append 改写幂等 update（防 server 双元素）
            await agg._dispatch_event(_mock_adapter, {"kind": "pre_llm_call", "session_id": "s7", "turn_id": "t7", "sender_id": "u"})
            await agg._dispatch_event(_mock_adapter, {"kind": "tool_start", "session_id": "s7", "turn_id": "t7", "tool_name": "bash", "args": {}})
            await agg._dispatch_event(_mock_adapter, {"kind": "tool_end", "session_id": "s7", "turn_id": "t7", "tool_name": "bash", "args": {}, "result": "ok", "status": "ok"})
            _heal_base = len(_srv.patches)
            _mock_adapter.fail_remaining = 3
            await agg._dispatch_event(_mock_adapter, {"kind": "markdown", "session_id": "s7", "turn_id": "t7", "text": "正文A"})
            await agg._dispatch_event(_mock_adapter, {"kind": "tool_start", "session_id": "s7", "turn_id": "t7", "tool_name": "grep", "args": {}})
            await agg._dispatch_event(_mock_adapter, {"kind": "tool_start", "session_id": "s7", "turn_id": "t7", "tool_name": "find", "args": {}})
            _check(_mock_adapter.fail_remaining == 0, "失败注入全部被消费（3 连败触发自愈）")
            _ops7 = _ops()[_heal_base:]
            _full = [d for d in _ops7 if "op" not in d and "elements" in d]
            _check(len(_full) == 1, "3 连败后 SDK 发全量替换（降级自愈）")
            # 全量替换必须是自愈窗口内 server 收到的第一个 PATCH（失败请求在 mock 层拦截）
            _check(
                bool(_ops7) and "op" not in _ops7[0] and "elements" in _ops7[0],
                "全量替换是自愈窗口内第一个 PATCH（顺序锁定）",
            )
            if _full:
                _felem = _full[0]["elements"]
                _check(
                    any(e.get("type") == "markdown" and e.get("data", {}).get("text") == "正文A" for e in _felem)
                    and _full[0].get("state") == "generating",
                    "全量替换含失败窗口内的元素（影子副本覆盖）",
                )
            # server append 无 upsert（直接追加），自愈全量已含新元素，再发 append 会
            # 同 element_id 双条 → APP 双渲染。窗口内禁止 append，改写幂等 update。
            _check(
                not any(d.get("op") == "append" for d in _ops7),
                "回归：自愈成功后窗口内无 append（防重复元素双渲染）",
            )
            _check(
                any(
                    d.get("op") == "update"
                    and str(d.get("element_id", "")).startswith("tool_card")
                    and d.get("data", {}).get("name") == "find"
                    for d in _ops7
                ),
                "回归：新元素 append 被改写为幂等 update 命中该元素",
            )
            # 自愈后恢复增量模式：后续 op 正常落地（find 工具终态 update 全量）
            _heal_after = len(_srv.patches)
            await agg._dispatch_event(_mock_adapter, {"kind": "tool_end", "session_id": "s7", "turn_id": "t7", "tool_name": "find", "args": {}, "result": "done", "status": "ok"})
            _ops7b = _ops()[_heal_after:]
            _check(
                any(d.get("op") == "update" and d.get("data", {}).get("name") == "find" and d["data"]["status"] == "completed" for d in _ops7b),
                "自愈后恢复增量模式（后续终态 update 正常）",
            )
            agg.unregister_session("s7")
        finally:
            agg._SESSIONS.clear()
            agg._SESSION_TURNS.clear()
            agg._SESSION_CONVS.clear()
            agg._PERMISSION_CARDS.clear()

    async def _run_rest_channel_tests():
        """REST 通道自检（io 边界，真 HTTP 服务）：keep-alive 连接复用 +
        401 刷新重试 + 超时 5s。经 _HermesAggregateIO 驱动 adapter._rest_sync。"""
        import http.server
        import threading as _th
        agg = _aggregate_card

        state = {"conns": 0, "patch_calls": 0}

        class _H(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"  # keep-alive

            def setup(self):
                state["conns"] += 1
                super().setup()

            def _send(self, code, obj):
                body = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self):
                self.rfile.read(int(self.headers.get("Content-Length", 0)))
                self._send(200, {"ok": True, "data": {"message_id": "m1"}})

            def do_PATCH(self):
                self.rfile.read(int(self.headers.get("Content-Length", 0)))
                state["patch_calls"] += 1
                # 恒 401「old」token：若重试未携带新 token，第二次仍 401 → ok:False，
                # 锁死「刷新后必须用新 token 重试」的实现（不留 flag 豁免第二次）。
                if self.headers.get("Authorization") == "Bearer old":
                    self._send(401, {"ok": False, "error": {"code": "unauthorized"}})
                    return
                self._send(200, {"ok": True})

            def log_message(self, *a):
                pass

        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _H)
        port = srv.server_address[1]
        _th.Thread(target=srv.serve_forever, daemon=True).start()

        tokens = iter(["new", "new", "new", "new", "new", "new", "new", "new"])
        refreshes = {"n": 0}
        # 可变 cell 作 token 源：模拟真实 adapter 的 refresh 写回 self._token、
        # getter 重读闭环。固定 lambda 会让弱实现（重试仍读旧值）也通过。
        tok = {"cur": "old"}

        def _refresh():
            refreshes["n"] += 1
            tok["cur"] = next(tokens)
            return tok["cur"]

        try:
            adapter = WanlingAdapter.__new__(WanlingAdapter)
            adapter.server_url = f"http://127.0.0.1:{port}"
            adapter._rest_conn = None
            adapter.aggregate_token = lambda: tok["cur"]  # type: ignore[method-assign]
            adapter.refresh_aggregate_token = _refresh  # type: ignore[method-assign]
            io = agg._HermesAggregateIO(adapter, "c")
            mid = await io.send_card({"msg_type": "aggregate_card", "data": {"state": "generating"}})
            _check(mid == "m1", "keep-alive POST 建卡成功（返回 message_id）")
            await io.patch(mid, {"op": "set_silent", "silent": False})
            _check(refreshes["n"] == 1, "401 后刷新 token 重试成功（恰好一次刷新）")
            await io.patch(mid, {"op": "set_state", "state": "done"})
            await io.patch(mid, {"op": "set_segment", "segment": "last"})
            _check(state["conns"] == 1, f"4 次请求仅 1 条 TCP 连接（实际 {state['conns']}）")
            adapter._rest_close()
        finally:
            srv.shutdown()

    async def _run_shutdown_tests():
        """关停泄漏测试：cancel 后 await 已取消任务，CancelledError 不得穿透 disconnect()。

        真实事故：disconnect() 里 except Exception 拦不住 CancelledError
        （Python 3.8+ 是 BaseException），异常穿透到 hermes 的有界等待，
        把整个 gateway stop 任务静默杀死 → 进程挂 210s 被 SIGKILL。
        """
        import threading as _th

        # ── 场景 1：disconnect() 内部 await 已取消任务，不得泄漏 CancelledError ──
        async def _scenario_disconnect_leak():
            adapter = WanlingAdapter.__new__(WanlingAdapter)
            adapter._stopping = False
            adapter._aggregate_stop = _th.Event()
            # 永不主动退出的消费者任务（模拟 run_event_consumer 阻塞在队列 get）
            async def _stuck_consumer():
                await _asyncio.sleep(3600)
            adapter._aggregate_consumer_task = _asyncio.create_task(_stuck_consumer())
            adapter._edit_meta = {}
            adapter._ws = None
            adapter._heartbeat_task = None
            adapter._recv_task = None
            adapter._rest_close = lambda: None  # type: ignore[method-assign]

            # _aggregate_card.unregister_adapter 需要的注册表不存在时容忍
            orig_unreg = getattr(_aggregate_card, "unregister_adapter", None)
            if orig_unreg is not None:
                _aggregate_card.unregister_adapter = lambda *a, **k: None  # type: ignore

            leak = None
            try:
                await _asyncio.wait_for(adapter.disconnect(), timeout=5)
            except BaseException as e:  # noqa: BLE001 — 测试就是要抓 BaseException
                leak = e
            finally:
                if orig_unreg is not None:
                    _aggregate_card.unregister_adapter = orig_unreg  # type: ignore
            _check(leak is None, f"disconnect() 不泄漏 CancelledError/异常（实际 {leak!r}）")

        await _scenario_disconnect_leak()

        # ── 场景 2：hermes 视角 — disconnect 任务被 await 时不得把取消传给调用方 ──
        async def _scenario_hermes_bounded_wait():
            adapter = WanlingAdapter.__new__(WanlingAdapter)
            adapter._stopping = False
            adapter._aggregate_stop = _th.Event()
            async def _stuck_consumer():
                await _asyncio.sleep(3600)
            adapter._aggregate_consumer_task = _asyncio.create_task(_stuck_consumer())
            adapter._edit_meta = {}
            adapter._ws = None
            adapter._heartbeat_task = None
            adapter._recv_task = None
            adapter._rest_close = lambda: None  # type: ignore[method-assign]
            orig_unreg = getattr(_aggregate_card, "unregister_adapter", None)
            if orig_unreg is not None:
                _aggregate_card.unregister_adapter = lambda *a, **k: None  # type: ignore

            # 复刻 hermes _await_adapter_cleanup_with_timeout 的结构：
            # 把 disconnect() 包成 task 并 await —— 若 disconnect 泄漏取消，
            # 这个 await 会抛 CancelledError，与线上死法一致。
            task = _asyncio.create_task(adapter.disconnect())
            try:
                await _asyncio.wait_for(_asyncio.shield(_asyncio.wait({task}, timeout=5)), timeout=8)
                _check(task.done() and not task.cancelled(),
                       "hermes 有界等待视角：disconnect 正常完成而非被取消")
            except BaseException as e:  # noqa: BLE001
                _check(False, f"hermes 有界等待视角：泄漏了 {type(e).__name__}")
            finally:
                if orig_unreg is not None:
                    _aggregate_card.unregister_adapter = orig_unreg  # type: ignore
                if not task.done():
                    task.cancel()

        await _scenario_hermes_bounded_wait()

    async def _main():
        await _run_tests()
        await _run_aggregate_tests()
        await _run_rest_channel_tests()
        await _run_shutdown_tests()
        print()
        if failures:
            print(f"== 自检失败：{len(failures)} 项 ==")
            for f in failures:
                print(f"  - {f}")
            raise SystemExit(1)
        print("== 自检全部通过 ==")

    _asyncio.run(_main())
