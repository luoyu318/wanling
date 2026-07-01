"""本地消息缓存 —— WS dispatch 事件流入，MCP tool 读取。

agent 端没有 list_conversations / get_messages 的 HTTP 接口，
这两个能力由本模块通过 WS 事件累积提供。
"""

from __future__ import annotations

import time
from collections import defaultdict
from typing import Any

from wanling.models import ConvMeta


class MessageStore:
    """内存消息缓存。WS 事件实时写入，MCP tool 查询读取。

    限制：进程内内存，重启丢失。后续可换 SQLite 持久化。
    """

    def __init__(self):
        self._convs: dict[str, ConvMeta] = {}
        self._messages: dict[str, list[dict[str, Any]]] = defaultdict(list)
        self._unread: dict[str, list[dict[str, Any]]] = defaultdict(list)

    # ── 写入（WS 回调）──

    def on_dispatch(self, event_type: str, payload: dict[str, Any]) -> None:
        match event_type:
            case "MESSAGE_CREATE":
                cid = payload.get("conversation_id", "")
                uid = payload.get("user_id", payload.get("sender_id", ""))
                if cid:
                    self._convs[cid] = ConvMeta(
                        conv_id=cid,
                        user_id=uid,
                        last_message_at=payload.get("created_at", ""),
                    )
                    self._messages[cid].append(payload)
                    # agent 发的消息不进 unread（只缓存 user 发过来的）
                    if payload.get("sender_type") == "user":
                        self._unread[cid].append(payload)

    # ── 读取（MCP tool）──

    def list_conversations(self) -> list[dict[str, Any]]:
        convs = sorted(
            self._convs.values(),
            key=lambda c: c.last_message_at,
            reverse=True,
        )
        return [
            {
                "conv_id": c.conv_id,
                "user_id": c.user_id,
                "user_name": c.user_name or c.user_id,
                "last_message_at": c.last_message_at,
            }
            for c in convs
        ]

    def get_messages(self, conv_id: str, limit: int = 50,
                     before: str | None = None) -> list[dict[str, Any]]:
        msgs = self._messages.get(conv_id, [])
        if before:
            msgs = [m for m in msgs if m.get("created_at", "") < before]
        return msgs[-limit:]

    def pop_unread(self, conv_id: str) -> dict[str, Any] | None:
        """取出指定会话最早一条未读，没有则返回 None。"""
        queue = self._unread.get(conv_id)
        if queue:
            return queue.pop(0)
        return None

    def pop_all_unread(self, conv_id: str) -> list[dict[str, Any]]:
        """取出指定会话全部未读。"""
        return self._unread.pop(conv_id, [])

    def get_user_id(self, conv_id: str) -> str:
        """查会话对应的 user_id。"""
        meta = self._convs.get(conv_id)
        return meta.user_id if meta else ""
