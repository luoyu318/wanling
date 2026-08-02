"""消息 payload 类型(TypedDict,与 TS types.ts 对齐)。"""

from typing import TypedDict


class WSMessage(TypedDict, total=False):
    op: int
    d: dict
    t: str
    s: int


class HelloPayload(TypedDict, total=False):
    heartbeat_interval: int


class MessageContent(TypedDict, total=False):
    msg_type: str
    data: dict
    silent: bool
    parent_msg_id: str
    root_msg_id: str


class MessageCreatePayload(TypedDict, total=False):
    id: str
    conversation_id: str
    sender_type: str
    sender_id: str
    sender_name: str
    sender_avatar_url: str
    conversation_type: str
    conversation_title: str
    content: MessageContent
    created_at: str


class OutboundMessage(TypedDict, total=False):
    conversation_id: str
    content: MessageContent
