"""万灵协议常量：OpCode / 消息类型 / 事件类型 / 审批相关枚举。"""

from enum import StrEnum


# ── WebSocket OpCode（对齐 server model/opcodes.go）──

class OpCode:
    DISPATCH       = 0
    HEARTBEAT      = 1
    IDENTIFY       = 2
    SET_ACTIVE_CONV = 3
    RESUME         = 6
    RECONNECT      = 7
    HELLO          = 10
    HEARTBEAT_ACK  = 11


# ── Dispatch 事件类型 ──

class EventType:
    MESSAGE_CREATE   = "MESSAGE_CREATE"
    MESSAGE_UPDATE   = "MESSAGE_UPDATE"
    MESSAGE_DELETE   = "MESSAGE_DELETE"
    AGENT_ONLINE     = "AGENT_ONLINE"
    AGENT_OFFLINE    = "AGENT_OFFLINE"
    TYPING_START     = "TYPING_START"
    APPROVAL_DECIDED = "APPROVAL_DECIDED"
    APPROVAL_EXPIRED = "APPROVAL_EXPIRED"


# ── 消息内容类型 ──

class MsgType(StrEnum):
    TEXT     = "text"
    MARKDOWN = "markdown"
    IMAGE    = "image"
    FILE     = "file"
    MIXED    = "mixed"
    CARD     = "card"


# ── 审批 ──

class CardType(StrEnum):
    COMMAND       = "command"
    TOOL          = "tool"
    FILE          = "file"
    SLASH_CONFIRM = "slash_confirm"


class ApprovalState(StrEnum):
    PENDING  = "pending"
    APPROVED = "approved"
    DENIED   = "denied"
    EXPIRED  = "expired"

    def is_terminal(self) -> bool:
        return self in (ApprovalState.APPROVED, ApprovalState.DENIED, ApprovalState.EXPIRED)
