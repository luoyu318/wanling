"""审批/提问高层封装(与 TS approvals.ts 对称的 asyncio 版)。

createApproval REST 建卡 → 监听 APPROVAL_DECIDED/EXPIRED(按 approval_id
匹配)→ Future 决议。超时本地兜底(防事件丢失),断线重连后主动 GET 兜底一次。
"""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from typing import Any

from .types import AskOptions

# 依赖构造注入(不 import client),保持可测 —— 与 TS 同构
CreateApprovalFn = Callable[[str, dict[str, Any]], Awaitable[dict[str, Any]]]
FetchApprovalFn = Callable[[str], Awaitable[dict[str, Any]]]
OnEventFn = Callable[[str, Callable[[dict[str, Any]], None]], None]
LogFn = Callable[[str], None]


class _PendingAsk:
    """未决 ask:决议 Future + 超时兜底定时器。"""

    def __init__(self, future: asyncio.Future, timer: asyncio.TimerHandle) -> None:
        self.future = future
        self.timer = timer


class Approvals:
    def __init__(
        self,
        create: CreateApprovalFn,
        fetch_approval: FetchApprovalFn,
        on_event: OnEventFn,
        log: LogFn | None = None,
    ) -> None:
        self._create = create
        self._fetch_approval = fetch_approval
        self._log = log or (lambda msg: None)
        self._pending: dict[str, _PendingAsk] = {}
        on_event("approval.decided", self._on_decided)
        on_event("approval.expired", self._on_expired)

    def _on_decided(self, p: dict[str, Any]) -> None:
        decision = str(p.get("decision") or "")
        # deny/reject/cancel 统一映射 denied,其余(approve/answer/...)按 approved
        state = "denied" if decision in ("deny", "reject", "cancel") else "approved"
        result: dict[str, Any] = {"state": state, "decision": decision}
        if isinstance(p.get("answers"), list):
            result["answers"] = [str(a) for a in p["answers"]]
        if p.get("decided_by") is not None:
            result["decided_by"] = str(p["decided_by"])
        if p.get("reason") is not None:
            result["reason"] = str(p["reason"])
        self._settle(str(p.get("approval_id") or ""), result)

    def _on_expired(self, p: dict[str, Any]) -> None:
        self._settle(str(p.get("approval_id") or ""), {"state": "expired"})

    async def ask(self, conv_id: str, opts: AskOptions) -> dict[str, Any]:
        """发卡并等待决策。auto_approved 命中白名单时立即返回 approved。"""
        body: dict[str, Any] = {
            "card_type": opts["card_type"],
            "title": opts["title"],
            "session_key": opts["session_key"],
        }
        for key in ("preview", "tool_name", "options", "multi_select", "allow_pattern", "confirm_id", "timeout_sec"):
            if opts.get(key) is not None:
                body[key] = opts[key]
        created = await self._create(conv_id, body)
        if created.get("auto_approved") is True or created.get("state") == "approved":
            return {"state": "approved", "decision": "allow_always"}
        approval_id = created.get("approval_id") or ""
        if approval_id == "":
            raise RuntimeError("createApproval 未返回 approval_id")

        loop = asyncio.get_running_loop()
        fut: asyncio.Future = loop.create_future()
        timeout_ms = opts.get("timeout_sec", 300) * 1000 + 5000  # server 超时 + 5s 事件余量

        def _on_timeout() -> None:
            self._pending.pop(approval_id, None)
            self._log(f"ask 超时兜底 approval={approval_id}")
            if not fut.done():
                fut.set_result({"state": "expired"})

        timer = loop.call_later(timeout_ms / 1000, _on_timeout)
        self._pending[approval_id] = _PendingAsk(future=fut, timer=timer)
        return await fut

    async def resync(self) -> None:
        """断线重连后调用:对未决项逐个 REST 兜底查询。"""
        for approval_id, p in list(self._pending.items()):
            try:
                a = await self._fetch_approval(approval_id)
            except Exception:  # noqa: S112, BLE001 - 单项查询失败下轮再试
                continue
            state = a.get("state")
            if state is None or state == "pending":
                continue
            p.timer.cancel()
            del self._pending[approval_id]
            if p.future.done():
                continue
            if state == "expired":
                p.future.set_result({"state": "expired"})
                continue
            result: dict[str, Any] = {
                "state": "denied" if state == "denied" else "approved",
                "decision": a.get("decided_action") or "",
            }
            if a.get("decided_answers") is not None:
                result["answers"] = a["decided_answers"]
            p.future.set_result(result)

    def _settle(self, approval_id: str, result: dict[str, Any]) -> None:
        p = self._pending.get(approval_id)
        if p is None:
            return
        p.timer.cancel()
        del self._pending[approval_id]
        if not p.future.done():
            p.future.set_result(result)
