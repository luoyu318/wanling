"""Approvals 对称测试(与 TS approvals.test.ts 用例一一对应)。"""

import asyncio

import pytest

from wanling_sdk.approvals import Approvals


def make_approvals():
    handlers: dict[str, list] = {}

    async def create(conv_id, body):
        return {"approval_id": "ap1", "state": "pending"}

    async def fetch(approval_id):
        raise AssertionError("not called")

    def on_event(name, cb):
        handlers.setdefault(name, []).append(cb)

    approvals = Approvals(create, fetch, on_event)

    def emit(name, payload):
        for cb in handlers.get(name, []):
            cb(payload)

    return approvals, emit


@pytest.mark.asyncio
async def test_decided_event_settles_approved_with_answers():
    approvals, emit = make_approvals()
    task = asyncio.ensure_future(
        approvals.ask(
            "c1",
            {
                "card_type": "question",
                "title": "t",
                "session_key": "s",
                "options": [{"id": "a", "label": "A"}],
                "multi_select": True,
            },
        )
    )
    # 等 createApproval mock 完成、pending 注册后再 emit(模拟真实时序:决策晚于建卡)
    await asyncio.sleep(0)
    emit("approval.decided", {"approval_id": "ap1", "decision": "answer", "answers": ["a"], "decided_by": "u1"})
    assert await task == {"state": "approved", "decision": "answer", "answers": ["a"], "decided_by": "u1"}


@pytest.mark.asyncio
async def test_expired_event_settles_expired():
    approvals, emit = make_approvals()
    task = asyncio.ensure_future(
        approvals.ask("c1", {"card_type": "tool", "title": "t", "session_key": "s"})
    )
    await asyncio.sleep(0)
    emit("approval.expired", {"approval_id": "ap1"})
    assert await task == {"state": "expired"}


@pytest.mark.asyncio
async def test_auto_approved_short_circuits():
    async def create(conv_id, body):
        return {"approval_id": "x", "state": "approved", "auto_approved": True}

    async def fetch(approval_id):
        raise AssertionError("not called")

    approvals = Approvals(create, fetch, lambda name, cb: None)
    assert await approvals.ask("c1", {"card_type": "command", "title": "t", "session_key": "s"}) == {
        "state": "approved",
        "decision": "allow_always",
    }


@pytest.mark.asyncio
async def test_timeout_fallback_expired(monkeypatch):
    # 压缩定时器延迟(timeoutSec=1 → 真实 6s 太慢),只验证超时兜底语义
    loop = asyncio.get_running_loop()
    orig_call_later = loop.call_later
    monkeypatch.setattr(loop, "call_later", lambda delay, cb, *a: orig_call_later(0.01, cb, *a))
    approvals, emit = make_approvals()
    task = asyncio.ensure_future(
        approvals.ask("c1", {"card_type": "tool", "title": "t", "session_key": "s", "timeout_sec": 1})
    )
    await asyncio.sleep(0)
    assert await task == {"state": "expired"}
    # 超时兜底后 pending 已清:迟到 decided 事件不二次决议、不报错(无泄漏)
    emit("approval.decided", {"approval_id": "ap1", "decision": "approve"})
