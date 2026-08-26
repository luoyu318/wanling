"""外部 session ↔ conversation 持久映射(与 TS session_mapping.ts 对称)。

dsh 模式 — tmp+rename 原子写、双 Map 索引(by_session/by_conversation 双向查)、
损坏文件备份后重置、miss 时经注入的 create_conversation 建会话(幂等)。
"""

from __future__ import annotations

import json
import os
import shutil
import time
from collections.abc import Awaitable, Callable
from datetime import datetime, timezone
from typing import Any

# 落盘条目:{conversationId, sessionId, createdAt}(与 TS 写盘格式一致,跨语言可互读)
MappingEntry = dict[str, str]

CreateConversationFn = Callable[[str, dict[str, Any]], Awaitable[str | None]]


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


class SessionMapping:
    def __init__(self, path: str, create_conversation: CreateConversationFn) -> None:
        self._by_conv: dict[str, MappingEntry] = {}
        self._by_sess: dict[str, MappingEntry] = {}
        self._path = path
        self._create_conversation = create_conversation
        self._loaded = False

    def load(self) -> None:
        """懒加载:首次查询/写操作前读盘;损坏(JSON 解析失败)备份原文件后
        重置为空索引(fail soft:映射文件不是真相源,会话可在 server 侧重建)。"""
        if self._loaded:
            return
        self._loaded = True
        if not os.path.exists(self._path):
            return
        try:
            with open(self._path, encoding="utf-8") as f:
                raw = json.load(f)
            for conv_id, entry in (raw.get("mappings") or {}).items():
                full = {**entry, "conversationId": conv_id}
                self._by_conv[conv_id] = full
                self._by_sess[full["sessionId"]] = full
        except Exception:  # noqa: BLE001 - 损坏/字段缺失统一按 fail soft 处理
            # 损坏备份(带时间戳后缀),索引保持空
            shutil.copy2(self._path, f"{self._path}.corrupt.{int(time.time() * 1000)}")

    def by_session(self, session_id: str) -> str | None:
        self.load()
        entry = self._by_sess.get(session_id)
        return entry["conversationId"] if entry is not None else None

    def by_conversation(self, conv_id: str) -> str | None:
        self.load()
        entry = self._by_conv.get(conv_id)
        return entry["sessionId"] if entry is not None else None

    async def ensure_conversation(self, session_id: str, opts: dict[str, Any]) -> str | None:
        """查映射,miss 时建会话并落盘(已知 session 幂等直接返回;并发防重由
        create_conversation 实现方保证)。create_conversation 返回 None 视为放弃。"""
        self.load()
        known = self._by_sess.get(session_id)
        if known is not None:
            return known["conversationId"]
        conv_id = await self._create_conversation(session_id, opts)
        if conv_id is None:
            return None
        entry = {"conversationId": conv_id, "sessionId": session_id, "createdAt": _utc_now_iso()}
        self._by_conv[conv_id] = entry
        self._by_sess[session_id] = entry
        self._save()
        return conv_id

    def remove(self, session_id: str) -> None:
        self.load()
        entry = self._by_sess.get(session_id)
        if entry is None:
            return
        del self._by_sess[session_id]
        del self._by_conv[entry["conversationId"]]
        self._save()

    def _save(self) -> None:
        """原子写:先写 tmp 再 rename,读方不会看到半截 JSON。"""
        mappings = {
            conv_id: {"sessionId": e["sessionId"], "createdAt": e["createdAt"]}
            for conv_id, e in self._by_conv.items()
        }
        os.makedirs(os.path.dirname(self._path) or ".", exist_ok=True)
        tmp = f"{self._path}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"version": 1, "mappings": mappings}, f, ensure_ascii=False, indent=2)
        os.replace(tmp, self._path)
