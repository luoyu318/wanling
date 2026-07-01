"""MCP Tool 处理器 — 8 个 tool 的实现。

每个函数签名为 (args: dict, bridge: Bridge) -> str (JSON 返回)。
阻塞式 tool (wait_reply / ask_confirmation) 内部循环轮询 store，对 MCP 客户端
来说就是一次普通的耗时调用。

对外语义统一用 user_id（AI 终端只关心"跟谁对话"），内部通过 store 反查 conv_id。
"""

from __future__ import annotations

import asyncio
import json
import os
import time
from typing import Any

from wanling_mcp.bridge import Bridge

DEFAULT_TIMEOUT_SEC = 300  # 5 分钟


def _resolve_user(args: dict[str, Any], bridge: Bridge) -> str:
    """从 args 中取 user_id，回退到 WANLING_USER_ID 环境变量。"""
    if "user_id" in args and args["user_id"]:
        return args["user_id"]
    uid = os.environ.get("WANLING_USER_ID", "")
    if uid:
        return uid
    raise RuntimeError(
        "无法确定目标 user：请提供 user_id 或设置 WANLING_USER_ID 环境变量"
    )


def _resolve_conv(user_id: str, bridge: Bridge) -> str:
    """按 user_id 从 store 反查 conv_id（一个 user 在同一 agent 下通常只有一个会话）。

    store 尚未缓存到该 user 的会话时返回空字符串（send_message 不需要 conv_id，
    wait_reply/ask_confirmation 等收到首条 MESSAGE_CREATE 后 store 才会有映射）。
    """
    return bridge.store.get_conv_id_by_user(user_id)


# ── 无阻塞 ──

async def list_conversations(args: dict[str, Any], bridge: Bridge) -> str:
    convs = bridge.store.list_conversations()
    return json.dumps(convs, ensure_ascii=False)


async def get_messages(args: dict[str, Any], bridge: Bridge) -> str:
    user_id = _resolve_user(args, bridge)
    conv_id = _resolve_conv(user_id, bridge)
    if not conv_id:
        return json.dumps([], ensure_ascii=False)
    msgs = bridge.store.get_messages(
        conv_id=conv_id,
        limit=args.get("limit", 50),
        before=args.get("before"),
    )
    # 只返回摘要（id, sender_type, content 摘要, created_at），避免内容过长
    summary = []
    for m in msgs:
        content = m.get("content", {})
        text = ""
        if isinstance(content, dict):
            text = content.get("data", {}).get("text", "")[:200]
        summary.append({
            "id": m.get("id"),
            "sender_type": m.get("sender_type", ""),
            "sender_id": m.get("sender_id", ""),
            "text_preview": text,
            "created_at": m.get("created_at", ""),
        })
    return json.dumps(summary, ensure_ascii=False)


async def send_message(args: dict[str, Any], bridge: Bridge) -> str:
    await bridge.ensure_connected()
    user_id = _resolve_user(args, bridge)
    await bridge.sdk.send_message(user_id=user_id, text=args["text"])
    return json.dumps({"ok": True})


async def upload_file(args: dict[str, Any], bridge: Bridge) -> str:
    result = bridge.sdk.upload_file(args["file_path"])
    return json.dumps(result)


# ── 非阻塞检查 ──

async def check_new(args: dict[str, Any], bridge: Bridge) -> str:
    user_id = args.get("user_id")
    if user_id:
        conv_id = _resolve_conv(user_id, bridge)
        if not conv_id:
            return json.dumps({}, ensure_ascii=False, default=str)
        msgs = bridge.store.pop_all_unread(conv_id)
        return json.dumps({user_id: msgs}, ensure_ascii=False, default=str)
    # 全部会话（按 user_id 分组）
    result = bridge.store.pop_all_unread_grouped_by_user()
    return json.dumps(result, ensure_ascii=False, default=str)


# ── 阻塞式交互 ──

async def wait_reply(args: dict[str, Any], bridge: Bridge) -> str:
    """发消息后阻塞轮询 store 等待用户回复。"""
    await bridge.ensure_connected()

    user_id = _resolve_user(args, bridge)
    text = args["text"]
    timeout_sec = args.get("timeout_sec", DEFAULT_TIMEOUT_SEC)

    await bridge.sdk.send_message(user_id=user_id, text=text)

    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        conv_id = _resolve_conv(user_id, bridge)
        reply = bridge.store.pop_unread(conv_id) if conv_id else None
        if reply:
            content = reply.get("content", {})
            reply_text = ""
            if isinstance(content, dict):
                reply_text = content.get("data", {}).get("text", "")
            return json.dumps({
                "reply": reply_text,
                "user_id": user_id,
                "timed_out": False,
            }, ensure_ascii=False)
        await asyncio.sleep(3)

    return json.dumps({"reply": None, "user_id": user_id, "timed_out": True},
                      ensure_ascii=False)


async def ask_confirmation(args: dict[str, Any], bridge: Bridge) -> str:
    """发二选一确认，阻塞等回复并解析是/否。"""
    await bridge.ensure_connected()

    user_id = _resolve_user(args, bridge)
    question = args["question"]
    timeout_sec = args.get("timeout_sec", DEFAULT_TIMEOUT_SEC)

    text = f"🤖 需要你确认:\n{question}\n\n请回复 是/否"
    await bridge.sdk.send_message(user_id=user_id, text=text)

    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        conv_id = _resolve_conv(user_id, bridge)
        reply = bridge.store.pop_unread(conv_id) if conv_id else None
        if reply:
            content = reply.get("content", {})
            reply_text = ""
            if isinstance(content, dict):
                reply_text = content.get("data", {}).get("text", "")
            confirmed = any(
                reply_text.strip().startswith(w)
                for w in ("是", "y", "Y", "ok", "确认", "yes")
            )
            return json.dumps({
                "reply": reply_text,
                "confirmed": confirmed,
                "user_id": user_id,
                "timed_out": False,
            }, ensure_ascii=False)
        await asyncio.sleep(3)

    return json.dumps({"reply": None, "confirmed": False,
                       "user_id": user_id, "timed_out": True}, ensure_ascii=False)


async def report_progress(args: dict[str, Any], bridge: Bridge) -> str:
    """语义糖：发进度消息，不等待回复。"""
    await bridge.ensure_connected()
    user_id = _resolve_user(args, bridge)
    await bridge.sdk.send_message(user_id=user_id, text=args["text"])
    return json.dumps({"ok": True})
