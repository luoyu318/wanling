"""数据模型 —— 镜像 server internal/model/*.go 的 JSON 结构。"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any


@dataclass
class User:
    """用户摘要（只读，find_or_create_conv 返回对端 user 信息）。"""
    id: str
    username: str
    nickname: str | None = None
    bio: str | None = None
    avatar_url: str = ""


@dataclass
class AgentSummary:
    """Agent 摘要（不含 secret_key）。"""
    id: str
    name: str
    avatar_url: str = ""
    bio: str | None = None
    status: str = "offline"


@dataclass
class Message:
    """单条消息。content 为 JSON 字符串。"""
    id: str
    conversation_id: str
    sender_type: str   # "user" | "agent"
    sender_id: str
    content: dict[str, Any]  # {"msg_type": "...", "data": {...}}
    created_at: str


@dataclass
class Approval:
    """审批记录。"""
    id: str
    message_id: str
    conversation_id: str
    agent_id: str
    user_id: str
    card_type: str
    state: str
    actions: list[dict[str, str]]
    expires_at: str
    session_key: str
    decided_action: str | None = None
    decided_by: str | None = None
    decided_reason: str | None = None
    decided_at: str | None = None
    allow_pattern: str | None = None
    confirm_id: str | None = None


@dataclass
class ConvMeta:
    """本地缓存的会话元数据。"""
    conv_id: str
    user_id: str = ""
    user_name: str = ""
    last_message_at: str = ""
    messages: list[dict[str, Any]] = field(default_factory=list)
