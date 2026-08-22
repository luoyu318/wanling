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


class ApprovalOption(TypedDict):
    """question 选项。"""

    id: str
    label: str


class _AskOptionsRequired(TypedDict):
    card_type: str  # command/tool/file/slash_confirm/question
    title: str
    session_key: str


class AskOptions(_AskOptionsRequired, total=False):
    """approvals.ask 入参(command/tool/file/slash_confirm/question 通用)。

    键名与 wire 字段一致(snake_case)。
    """

    preview: str
    tool_name: str
    options: list[ApprovalOption]
    multi_select: bool
    allow_pattern: str  # command 白名单 glob(* % 差异由 server 转换,这里传 glob)
    confirm_id: str  # slash_confirm 专用
    timeout_sec: int


class AskResult(TypedDict, total=False):
    """approvals.ask 结果(state 必有,其余按键是否存在)。"""

    state: str  # "approved" | "denied" | "expired"
    decision: str
    answers: list[str]
    decided_by: str
    reason: str


class AggregateCardOptions(TypedDict, total=False):
    """聚合卡选项。"""

    degraded_self_heal: bool  # PATCH 连续失败 3 次后降级全量替换自愈(默认开)
    recall_empty: bool  # finish 时无实际内容元素则撤回删卡(默认关;需 io.recall 通道)


class AggregateFooter(TypedDict, total=False):
    """footer 元素入参:duration_ms 映射协议字段 duration(毫秒);其余字段透传。"""

    tokens: int
    duration_ms: int
    model: str


class StreamAggregateRef(TypedDict):
    """聚合模式定位(卡内流式元素)。"""

    message_id: str
    element_id: str


class StreamSessionOptions(TypedDict, total=False):
    """流式会话选项。"""

    aggregate: StreamAggregateRef
    throttle_ms: int  # 节流间隔,默认 300ms(对齐 opencode 实测)
    tail_ms: int  # 尾部兜底静默窗口,默认 500ms(与节流间隔取小者为兜底定时器延迟)
    msg_type: str  # 流式帧 msg_type,默认 "text"(APP 仅放行 reasoning/markdown/text)


class EnsureConversationOptions(TypedDict, total=False):
    """session_mapping.ensure_conversation 建会话入参。"""

    title: str
    owner_user_id: str
    directory: str
