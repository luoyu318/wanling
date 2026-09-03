"""Wanling 聚合卡核心模块（hermes-plugin 聚合模式，SDK 版）。

聚合卡协议见 docs/ai-handbook/aggregate-card.md：一次问答一条消息，
elements[] 按时序承载全部步骤。本模块把 hermes 的工具事件 / 回合收尾
映射为聚合卡 elements，经 Python SDK 的 AggregateCard（串行队列 / 自动
分卡 / 失败降级自愈 / sealed 迟到 update 零流量）发到 wanling server。

数据流：
  hermes hook（同步 worker 线程）→ emit_event() 分发到活跃 adapter
  → adapter 实例的线程安全队列 → adapter 异步消费者 task
  → AggregateSession（hermes 回合语义 / 影子副本 / reorder / settle）
  → SDK AggregateCard（状态机）→ _HermesAggregateIO（REST io 适配，
    复用 adapter 的 keep-alive REST 通道，含 401 刷新重试）

完全走 hermes 官方插件 hook 机制（raft 先例），不修改 hermes 主程序。

adapter 需实现：
  enqueue_aggregate_event(event: dict)  —— 线程安全入队
  lookup_conv_by_user(user_id: str)    —— user_id → conv_id（入站记录）
  _rest(method, path, body)            —— REST 通道（keep-alive + 401 刷新）
  last_user_msg_id(conv_id)            —— 建卡引用锚点（可选）
"""

import asyncio
import logging
import os
import threading
import time
import weakref
from typing import Any, Dict, List, Optional

from wanling_sdk.aggregate_card import MAX_ELEMENTS, AggregateCard

logger = logging.getLogger(__name__)

# REST 单请求超时：缩短队头阻塞窗口（adapter 流式编辑 REST 通道共用）。
REST_TIMEOUT_S = 5.0

# 开关：false 回退旧逐条发送（协议不变，仅不发聚合卡）。
def _aggregate_enabled() -> bool:
    return os.getenv("WANLING_AGGREGATE_CARD_ENABLED", "true").strip().lower() in {
        "1", "true", "yes",
    }


# ── 活跃 adapter 注册表（hook 侧分发目标，raft 先例） ────────────────
_ACTIVE_ADAPTERS: "weakref.WeakSet[Any]" = weakref.WeakSet()
_ACTIVE_ADAPTERS_LOCK = threading.Lock()


def register_adapter(adapter: Any) -> None:
    with _ACTIVE_ADAPTERS_LOCK:
        _ACTIVE_ADAPTERS.add(adapter)


def unregister_adapter(adapter: Any) -> None:
    with _ACTIVE_ADAPTERS_LOCK:
        _ACTIVE_ADAPTERS.discard(adapter)


def emit_event(event: Dict[str, Any]) -> None:
    """hook 侧分发一个聚合卡事件到所有活跃 adapter（线程安全）。

    各 adapter 自己按 sender_id / session 决定是否消费。
    """
    with _ACTIVE_ADAPTERS_LOCK:
        adapters = list(_ACTIVE_ADAPTERS)
    for adapter in adapters:
        try:
            adapter.enqueue_aggregate_event(event)
        except Exception:
            logger.debug("Wanling aggregate emit failed", exc_info=True)


# ── REST io 适配器（SDK AggregateCard 构造注入，对齐 client.aggregate 工厂） ──

class _HermesAggregateIO:
    """SDK AggregateCard 的 io 实现：走 adapter 的 keep-alive REST 通道。

    io 协议（均为 async，失败必须 raise —— SDK 靠异常计连续失败数触发
    降级全量替换自愈）：
    - send_card(data) -> str            建卡，返回消息 id
    - patch(message_id, op)             聚合卡增量 PATCH
    - update_content(message_id, content) 全量替换（SDK 降级自愈用）
    - recall(message_id)                撤回删卡（空卡清理用）

    附带捕获（hermes 侧需要卡消息 id / 元素归属，无法从 SDK 公开 API 拿）：
    - card_msg_id   最近一次建卡的 message_id（set_silent / 空卡撤回定位）
    - card_count    建卡次数（wrapper 检测 SDK 自动分卡 → 清影子副本）
    - element_cards element_id → 卡 message_id（append 拦截；settle remove /
      审批 set_silent 需按归属卡定位，对齐旧 aggregateElementCardIds）
    - quote_message_id 建卡引用锚点（send_card / update_content 注入 data.quote）
    """

    def __init__(self, adapter: Any, conv_id: str) -> None:
        self._adapter = adapter
        self._conv_id = conv_id
        self.card_msg_id: str = ""
        self.card_count: int = 0
        self.element_cards: Dict[str, str] = {}
        self.quote_message_id: Optional[str] = None

    def _raise(self, what: str, msg_id: str = "") -> None:
        raise RuntimeError(f"Wanling aggregate {what} failed conv={self._conv_id} msg={msg_id}")

    async def send_card(self, data: Dict[str, Any]) -> str:
        # SDK 传入 {msg_type, data} 包裹（对齐 SDK _RestAggregateIO：拆开分别传）
        card_data = dict(data.get("data") or {})
        # 引用锚点：建卡带 data.quote（server PersistAndDispatch 富化 sender/preview）
        if self.quote_message_id:
            card_data["quote"] = {"message_id": self.quote_message_id}
        resp = await self._adapter._rest(
            "POST",
            f"/api/conversations/{self._conv_id}/messages",
            {"content": {"msg_type": data.get("msg_type", "aggregate_card"), "data": card_data, "silent": True}},
        )
        msg_id = ""
        if isinstance(resp, dict) and resp.get("ok"):
            msg_id = str((resp.get("data") or {}).get("message_id") or "")
        if not msg_id:
            self._raise("create")
        self.card_msg_id = msg_id
        self.card_count += 1
        return msg_id

    async def patch(self, message_id: str, op: Dict[str, Any]) -> None:
        if not message_id:
            self._raise("patch(empty message_id)")
        resp = await self._adapter._rest(
            "PATCH",
            f"/api/messages/{message_id}",
            {"content": {"msg_type": "aggregate_card", "data": op}},
        )
        if not isinstance(resp, dict) or not resp.get("ok"):
            self._raise("PATCH", message_id)
        # 拦截 append 记录元素归属卡：分卡后旧卡元素 remove/set_silent 仍定位旧卡
        if op.get("op") == "append":
            element = op.get("element") or {}
            eid = element.get("element_id")
            if eid:
                self.element_cards[eid] = message_id

    async def update_content(self, message_id: str, content: Dict[str, Any]) -> None:
        content = dict(content)
        data = dict(content.get("data") or {})
        # server 全量替换不保留已富化 quote，重建原始引用（自愈路径触达，可接受退化）
        if self.quote_message_id:
            data["quote"] = {"message_id": self.quote_message_id}
        content["data"] = data
        resp = await self._adapter._rest(
            "PATCH", f"/api/messages/{message_id}", {"content": content}
        )
        if not isinstance(resp, dict) or not resp.get("ok"):
            self._raise("full-replace", message_id)

    async def recall(self, message_id: str) -> None:
        resp = await self._adapter._rest(
            "DELETE", f"/api/messages/{message_id}?scope=recall", None
        )
        if not isinstance(resp, dict) or not resp.get("ok"):
            self._raise("recall", message_id)


# ── 回合会话（一个问答回合一张聚合卡；状态机在 SDK，语义映射在此） ──

class AggregateSession:
    """一个 hermes 会话（session_id）对应的聚合卡发送端。

    生命周期 = 一个问答回合：首个 pre_llm_call 经 SDK 幂等建卡 + append
    reasoning 占位，回合中工具/思考/正文事件实时 append/update 元素，
    回合结束 finish() 追加 footer + 翻转 state done + silent false（计未读）。

    与旧自管 AggregateCardManager 的分工：
    - SDK AggregateCard：REST 建卡/串行 PATCH 队列/20 元素自动分卡/
      连续失败降级全量替换自愈/sealed 迟到 update 零流量。
    - 本类（影子副本 = 意图即真相，wire 失败不回滚）：hermes 事件语义
      （工具终态全量 data、reasoning 多块状态机、markdown 前缀合并、
      reorder 归位、settle 收尾、空卡撤回、审批元素路由）。

    元素 data 契约：server update 是整体替换；SDK 对当前卡元素会与镜像
    合并，但分卡后旧卡元素要求调用方传全量 —— 本类所有终态 update
    （tool_end / interrupt 标错 / settle）一律从影子副本构造全量 data。
    """

    def __init__(self, session_id: str, conv_id: str, adapter: Any) -> None:
        self.session_id = session_id
        self.conv_id = conv_id
        self.io = _HermesAggregateIO(adapter, conv_id)
        # degraded 自愈（SDK 默认开，显式声明）+ 空卡撤回开启
        self._card = AggregateCard(
            conv_id, self.io, {"degraded_self_heal": True, "recall_empty": True}
        )
        self._seq = 0
        # 影子副本：当前卡元素（type/element_id/data）。SDK 自动分卡时清空
        # （旧卡元素顺序定格，settle/匹配只看当前卡，对齐旧实现语义）。
        self._elements: List[Dict[str, Any]] = []
        self._finalized = False
        # 已收尾卡的 message_id（回合收尾锚）：interrupt reset 清影子但不清此锚，
        # 新回合 is_new 的补收尾路径据此跳过空卡判断，防误撤有内容的旧卡
        # （对齐旧实现 reset 置 _card_msg_id=None 的防误判语义）。
        self._finished_card = ""

    def next_element_id(self, type_: str) -> str:
        self._seq += 1
        return f"{type_}_{self._seq}"

    # ── 元素操作 ─────────────────────────────────────────────────────

    async def append_element(
        self,
        type_: str,
        data: Dict[str, Any],
        *,
        element_id: Optional[str] = None,
    ) -> None:
        """增量 append 元素；同 element_id 已在当前卡 → SDK 自动改发 update。"""
        if self._finalized:
            return
        eid = element_id or self.next_element_id(type_)
        existed = any(e.get("element_id") == eid for e in self._elements)
        # 分卡前置收尾：当前卡满且本元素是新元素 → 先收尾旧卡未终态元素
        # （SDK seal 只 set_state/set_segment 不做 settle，此处对齐旧实现：
        # 空占位删除 / 未终态思考标 finished / running 工具标 error）。
        if not existed and len(self._elements) >= MAX_ELEMENTS:
            await self._settle_unfinished_elements()
        cards_before = self.io.card_count
        try:
            await self._card.append(type_, {**data, "element_id": eid})
        except Exception:
            # wire 失败不回滚影子（意图即真相，对齐旧实现；SDK 镜像同理
            # 已在 patch 前落地，降级全量替换按影子推）
            logger.warning(
                "Wanling aggregate append %s failed conv=%s", eid, self.conv_id
            )
        if self.io.card_count != cards_before:
            # SDK 已分卡开新卡：清影子副本（旧卡元素顺序定格）
            self._elements = []
        element = {"type": type_, "element_id": eid, "data": dict(data)}
        if any(e.get("element_id") == eid for e in self._elements):
            self._elements = [
                element if e.get("element_id") == eid else e for e in self._elements
            ]
        else:
            self._elements.append(element)

    async def update_element(self, element_id: str, data: Dict[str, Any]) -> bool:
        """按 element_id 更新元素 data（当前卡 SDK 与镜像合并发全量；分卡后
        旧卡元素经 SDK 归属映射直 PATCH 旧卡，data 须全量 —— 调用方保证）。

        返回 True 表示 PATCH 落地；finalized 早退或 PATCH 失败返回 False。
        影子副本无条件更新（意图即真相，对齐旧实现）。
        """
        if self._finalized:
            return False
        try:
            await self._card.update(element_id, data)
        except Exception:
            logger.warning(
                "Wanling aggregate update %s failed conv=%s", element_id, self.conv_id
            )
            return False
        self._elements = [
            {**e, "data": {**e.get("data", {}), **data}}
            if e.get("element_id") == element_id else e
            for e in self._elements
        ]
        return True

    async def append_or_merge_markdown(self, text: str, *, final: bool = False) -> None:
        """追加 markdown 元素；相邻前缀重叠则合并（防重复），否则独立元素。

        hermes 的 send() 收到中间文本（执行中输出），post_llm_call 收到最终正文。
        两者可能开头重叠（LLM 把同一句先说一遍再展开）。处理：
        - 新文本 startswith 最后一条 markdown → 同 element_id 重发（当前卡内
          SDK 自动转 update 原位替换；分卡后旧卡元素不在镜像 → 落新卡 append）
        - 最后一条 markdown startswith 新文本 → 忽略（已更长）
        - 否则 → append 独立元素
        """
        if self._finalized or not text or not text.strip():
            return
        text = text.strip()
        last_id = ""
        last_text = ""
        for e in reversed(self._elements):
            if e.get("type") == "markdown":
                last_id = e.get("element_id", "")
                last_text = str(e.get("data", {}).get("text") or "").strip()
                break
        if last_id and last_text:
            if text.startswith(last_text) and text != last_text:
                await self.append_element("markdown", {"text": text}, element_id=last_id)
                return
            if last_text.startswith(text):
                return  # 最后元素已更长（更完整的快照），忽略
        await self.append_element("markdown", {"text": text})

    async def reorder_markdown_to_end(self) -> None:
        """reorder：把正文（markdown）元素移到末尾（reasoning/工具卡之后、footer 前）。

        仅作用于当前卡元素（分卡后旧卡已 seal，元素顺序定格）。
        直发 io.patch（SDK 无 reorder 公开 API；消费者单 task 串行，顺序安全）。
        """
        if self._finalized or not self._elements:
            return
        markdown_ids = [
            e.get("element_id", "") for e in self._elements if e.get("type") == "markdown"
        ]
        if not markdown_ids:
            return
        ordered = [
            e.get("element_id", "") for e in self._elements if e.get("type") != "markdown"
        ]
        ordered.extend(markdown_ids)
        current_order = [e.get("element_id", "") for e in self._elements]
        if ordered == current_order:
            return  # markdown 已在末尾，无需 reorder
        try:
            await self.io.patch(self.io.card_msg_id, {"op": "reorder", "order": ordered})
        except Exception:
            logger.warning("Wanling aggregate reorder failed conv=%s", self.conv_id)
        self._reorder_shadow(ordered)

    async def reorder_reasoning_before_markdown(self, reasoning_id: str) -> None:
        """reorder：把 reasoning 元素移到所有 markdown 元素之前（工具卡之后）。

        hermes 中间文本（send 触发）先于 reasoning 进卡，导致 markdown 在
        reasoning 前；回合末 append reasoning 后，重排为
        [工具卡..., reasoning, markdown...]。仅作用于当前卡元素。
        """
        if self._finalized or not self._elements:
            return
        if reasoning_id not in {e.get("element_id") for e in self._elements}:
            return
        non_markdown: List[str] = []
        markdown_ids: List[str] = []
        for e in self._elements:
            eid = e.get("element_id", "")
            if eid == reasoning_id:
                continue
            if e.get("type") == "markdown":
                markdown_ids.append(eid)
            else:
                non_markdown.append(eid)
        ordered = non_markdown + [reasoning_id] + markdown_ids
        try:
            await self.io.patch(self.io.card_msg_id, {"op": "reorder", "order": ordered})
        except Exception:
            logger.warning("Wanling aggregate reorder failed conv=%s", self.conv_id)
        self._reorder_shadow(ordered)

    def _reorder_shadow(self, ordered: List[str]) -> None:
        """意图即真相：无论 PATCH 成败都同步重排影子副本。"""
        rank = {eid: i for i, eid in enumerate(ordered)}
        self._elements.sort(
            key=lambda e: rank.get(e.get("element_id", ""), len(rank))
        )

    # ── 收尾 ─────────────────────────────────────────────────────────

    async def _settle_unfinished_elements(self) -> None:
        """收尾未终态元素（对齐旧实现的中断 flush 终态语义）：

        - 空文本 reasoning 占位（未被任何思考 update）→ 删除，避免卡显示「思考中」空块
        - 非空文本但仍 finished=false 的思考块 → 标 finished=true 保留内容
        - running 工具卡（tool_end 未到，被中断/异常）→ 标 error，避免永久 pending
        按元素归属卡操作（分卡场景 settle 在 seal 前调用，元素仍在当前卡）。
        """
        for e in list(self._elements):
            if e.get("type") == "reasoning" and e.get("data", {}).get("finished") is False:
                rid = e.get("element_id", "")
                if not str(e.get("data", {}).get("text") or "").strip():
                    owner = self.io.element_cards.get(rid) or self.io.card_msg_id
                    try:
                        await self.io.patch(owner, {"op": "remove", "element_id": rid})
                    except Exception:
                        logger.warning(
                            "Wanling aggregate remove placeholder failed conv=%s", self.conv_id
                        )
                    self._elements = [
                        x for x in self._elements if x.get("element_id") != rid
                    ]
                else:
                    await self.update_element(rid, {**e.get("data", {}), "finished": True})
            elif e.get("type") == "tool_card" and e.get("data", {}).get("status") == "running":
                eid = e.get("element_id", "")
                await self.update_element(
                    eid, {**e.get("data", {}), "status": "error", "error": "interrupted"}
                )

    async def finish(
        self,
        *,
        reason: str = "stop",
        stopped: bool = False,
        model: Optional[str] = None,
        mode: Optional[str] = None,
        tokens: Optional[Dict[str, Any]] = None,
        duration: Optional[float] = None,
    ) -> None:
        """回合结束收尾：settle → SDK finish（footer + state done + silent false
        计未读）→ 空卡撤回。

        空卡清理：卡里没有实际内容元素（settle 后仅剩 footer）时撤回该消息
        （scope=recall，全员不可见），避免用户看到空卡。典型场景：interrupt
        断卡后新回合被立即打断，只建卡没内容。wire 顺序对齐旧实现
        （footer → done → silent → recall）；「从未 append 成功」的更早空卡
        由 SDK recall_empty 选项在建卡零元素时直接撤回。
        """
        if self._finalized:
            return
        self._finalized = True
        # 本回合已收尾（interrupt reset 后新回合 is_new 的补收尾路径）：SDK
        # sealed 幂等无 wire，直接跳过，防影子已清导致空卡误撤有内容的旧卡。
        if self.io.card_msg_id and self._finished_card == self.io.card_msg_id:
            return
        await self._settle_unfinished_elements()
        footer: Dict[str, Any] = {"reason": reason, "finished": True}
        if stopped:
            footer["stopped"] = True
        if model:
            footer["model"] = model
        if mode:
            footer["mode"] = mode
        if tokens:
            footer["tokens"] = tokens
        if duration:
            footer["duration"] = duration
        try:
            await self._card.finish(footer)
        except Exception:
            # footer 序列中断（SDK 语义：PATCH 失败即中断，不吞错续发后续 op），
            # 空卡判断照常执行
            logger.warning("Wanling aggregate finish failed conv=%s", self.conv_id)
        if self.io.card_msg_id and not any(
            e.get("type") != "footer" for e in self._elements
        ):
            try:
                await self.io.recall(self.io.card_msg_id)
                logger.debug(
                    "Wanling aggregate: 空卡已撤回 conv=%s msg=%s",
                    self.conv_id, self.io.card_msg_id,
                )
            except Exception:
                logger.warning(
                    "Wanling aggregate 空卡撤回失败 conv=%s msg=%s",
                    self.conv_id, self.io.card_msg_id,
                )
        if self.io.card_msg_id:
            self._finished_card = self.io.card_msg_id

    def reset_for_new_card(self) -> None:
        """断卡（interrupt）后重置：保留 session 复用，下回合开新卡。

        SDK AggregateCard sealed 后下一次 append 自动 reset_round 开新卡
        （segment 归零 = first），影子副本清空；element_id 序号保留防复用。
        """
        self._finalized = False
        self._elements = []


# ── 会话上下文注册表（session_id → session） ────────────────────────
#
# hermes hook（同步 worker 线程）只拿到 session_id / sender_id，需要反查
# conv_id 并找到对应 session。adapter 消费者在收到首个回合事件时创建
# session（用 adapter.lookup_conv_by_user 拿 conv_id），注册进本表；
# 回合结束 finish() 后注销（下个回合重建新卡）。

_SESSIONS: Dict[str, AggregateSession] = {}
_SESSIONS_LOCK = threading.Lock()
# session_id → 最近 turn_id（用于跨回合区分：新 turn 首事件重建 session）。
_SESSION_TURNS: Dict[str, str] = {}
_SESSION_TURNS_LOCK = threading.Lock()

# session_id → sender_id（pre_llm_call 注册；tool hooks 无 sender_id 字段，
# 用此记忆在事件里补带，供消费者首事件兜底建 session）。
_SESSION_SENDERS: Dict[str, str] = {}
_SESSION_SENDERS_LOCK = threading.Lock()
# session_id → conv_id 持久记忆（跨回合保留）。session 回合结束注销后，
# 新回合（含无 sender_id 的系统后台回合）仍能恢复 conv_id 建卡。
_SESSION_CONVS: Dict[str, str] = {}
_SESSION_CONVS_LOCK = threading.Lock()


def remember_session_conv(session_id: str, conv_id: str) -> None:
    if not session_id or not conv_id:
        return
    with _SESSION_CONVS_LOCK:
        _SESSION_CONVS[session_id] = conv_id


def forget_session_conv(session_id: str) -> None:
    with _SESSION_CONVS_LOCK:
        _SESSION_CONVS.pop(session_id, None)


def get_session_conv(session_id: str) -> str:
    with _SESSION_CONVS_LOCK:
        return _SESSION_CONVS.get(session_id, "")


def remember_session_sender(session_id: str, sender_id: str) -> None:
    if not session_id or not sender_id:
        return
    with _SESSION_SENDERS_LOCK:
        _SESSION_SENDERS[session_id] = sender_id


def forget_session_sender(session_id: str) -> None:
    with _SESSION_SENDERS_LOCK:
        _SESSION_SENDERS.pop(session_id, None)


def get_session_sender(session_id: str) -> str:
    with _SESSION_SENDERS_LOCK:
        return _SESSION_SENDERS.get(session_id, "")


def get_active_by_conv(conv_id: str) -> Optional[AggregateSession]:
    """按 conv_id 找「聚合卡激活中」的 session（未 finish）。

    adapter.send() 用它判断中间文本是否应并入聚合卡（而非发独立气泡）。
    """
    if not conv_id:
        return None
    with _SESSIONS_LOCK:
        for m in _SESSIONS.values():
            if m.conv_id == conv_id and not m._finalized:
                return m
    return None

# conv_id → 聚合卡已接管正文（hook 同步标记，adapter.send() 抑制独立正文气泡防双发）。
# post_llm_call hook 必然先于 gateway 调 adapter.send()（finalize_turn 在 agent
# run 内同步执行），所以该标记可靠；adapter.send() 命中后清除。
_CONV_TEXT_TAKEN: Dict[str, bool] = {}
_CONV_TEXT_TAKEN_LOCK = threading.Lock()
# conv_id → 最近一次接管正文的时刻（monotonic 墙钟 time.time()）。
# 供 card_mode_recent 判断媒体吸收窗口，见 mark_conv_text_taken 处注释。
_CARD_MODE_AT: Dict[str, float] = {}

# 审批卡持久映射：session_key(oc_request_id) → {conv_id, msg_id, element_id}。
# 回合结束后 session 可能已注销（审批决策晚于回合收尾），permission_decided
# 需脱离活跃 session 直接 PATCH 该消息更新元素。
_PERMISSION_CARDS: Dict[str, Dict[str, str]] = {}
_PERMISSION_CARDS_LOCK = threading.Lock()


def remember_permission_card(session_key: str, conv_id: str, msg_id: str, element_id: str) -> None:
    if not session_key or not msg_id:
        return
    with _PERMISSION_CARDS_LOCK:
        _PERMISSION_CARDS[session_key] = {
            "conv_id": conv_id, "msg_id": msg_id, "element_id": element_id,
        }


def get_permission_card(session_key: str) -> Optional[Dict[str, str]]:
    with _PERMISSION_CARDS_LOCK:
        return _PERMISSION_CARDS.get(session_key)


def drop_permission_card(session_key: str) -> None:
    with _PERMISSION_CARDS_LOCK:
        _PERMISSION_CARDS.pop(session_key, None)


def mark_conv_text_taken(conv_id: str) -> None:
    if not conv_id:
        return
    with _CONV_TEXT_TAKEN_LOCK:
        _CONV_TEXT_TAKEN[conv_id] = True
        # 记录接管时刻（供 card_mode_recent 判断媒体吸收窗口）：上游
        # extract_images → 平台媒体接口的调用可能晚于卡 finish,仅靠活跃卡
        # 判断会漏吸收。容量上限防长连泄漏（超限淘汰最旧一条）。
        _CARD_MODE_AT[conv_id] = time.time()
        if len(_CARD_MODE_AT) > 256:
            oldest = min(_CARD_MODE_AT, key=lambda k: _CARD_MODE_AT[k])
            _CARD_MODE_AT.pop(oldest, None)


def card_mode_recent(conv_id: str, window: float = 60.0) -> bool:
    """该 conv 是否处于/刚处于聚合卡模式（adapter 媒体接口吸收独立气泡的依据）。

    活跃卡未收尾 → True；卡已收尾但 hook 最近（window 秒内）标记过接管正文
    → True（覆盖卡 finish 与上游媒体调用之间的竞序窗口）。
    """
    if not conv_id:
        return False
    if get_active_by_conv(conv_id) is not None:
        return True
    with _CONV_TEXT_TAKEN_LOCK:
        ts = _CARD_MODE_AT.get(conv_id, 0.0)
    return ts > 0 and (time.time() - ts) < window


def take_conv_text(conv_id: str) -> bool:
    """adapter.send() 调用：命中则抑制正文并清除标记（一次性）。"""
    if not conv_id:
        return False
    with _CONV_TEXT_TAKEN_LOCK:
        if _CONV_TEXT_TAKEN.pop(conv_id, False):
            return True
    return False


def register_session(session: AggregateSession) -> None:
    with _SESSIONS_LOCK:
        _SESSIONS[session.session_id] = session


def get_session(session_id: str) -> Optional[AggregateSession]:
    with _SESSIONS_LOCK:
        return _SESSIONS.get(session_id)


def unregister_session(session_id: str) -> None:
    with _SESSIONS_LOCK:
        _SESSIONS.pop(session_id, None)


def _is_new_turn(session_id: str, turn_id: str) -> bool:
    """判断是否新回合：turn_id 变化即视为新回合（重新建卡）。"""
    if not turn_id:
        return False
    with _SESSION_TURNS_LOCK:
        prev = _SESSION_TURNS.get(session_id)
        _SESSION_TURNS[session_id] = turn_id
        return prev is not None and prev != turn_id


# ── 事件消费者（adapter 事件循环内运行）────────────────────────────

async def run_event_consumer(adapter: Any, stop_event: Optional[threading.Event] = None) -> None:
    """adapter 事件循环内消费自己的事件队列，路由到 session。

    adapter 需提供：
      aggregate_events —— 线程安全 queue.Queue
    """
    import queue as _queue

    q = getattr(adapter, "aggregate_events", None)
    if q is None:
        return
    while True:
        try:
            event = await asyncio.to_thread(q.get, True, 0.2)
        except _queue.Empty:
            if stop_event is not None and stop_event.is_set():
                return
            continue
        except Exception:
            return
        try:
            await _dispatch_event(adapter, event)
        except Exception as e:
            logger.debug("Wanling aggregate event dispatch failed: %s", e)


def _permission_status(decision: str) -> str:
    return "approved" if decision in ("allow_once", "allow_always", "once", "always") else "denied"


async def _dispatch_event(adapter: Any, event: Dict[str, Any]) -> None:
    if not _aggregate_enabled():
        return
    kind = event.get("kind")

    # 聚合卡模式图片改写（双模式区分的核心）：本地图/远程图统一替换为
    # /api/files/ markdown，图文一体进卡元素；气泡模式的独立 image 气泡路径
    # 在 adapter.send()，两者互不干扰。改写放 consumer 侧（asyncio task）——
    # 上传耗时只拖慢本卡 PATCH，不阻塞 WS 心跳与 agent worker 线程。
    # 改写内部失败降级保留原文；此处兜底防改写器抛异常拖垮事件分发。
    if kind in ("markdown", "markdown_update"):
        text = event.get("text") or ""
        rewriter = getattr(adapter, "_rewrite_images_for_card", None)
        if rewriter is not None and text:
            try:
                event = {**event, "text": await rewriter(text)}
            except Exception:
                logger.warning("Wanling aggregate 图片改写失败,保留原文", exc_info=True)

    # 断卡（interrupt）：Agent 执行中用户发新消息 → 结束当前聚合卡段落。
    # 按 conv_id 定位活跃 session，running 工具标 error 后 finish(interrupt)
    # 收尾当前卡，重置 session（下个回合 pre_llm_call 开新卡）。
    if kind == "interrupt":
        conv_id = event.get("conv_id") or ""
        session = get_active_by_conv(conv_id) if conv_id else None
        if session is None:
            return
        if not session._finalized:
            # 收尾前：把 running 工具卡标 error（interrupt 打断工具执行，tool_end 不到）。
            # 全量 data 从影子副本构造（旧卡元素 update 是整体替换，不能只传 status）。
            for e in list(session._elements):
                if (
                    e.get("type") == "tool_card"
                    and e.get("data", {}).get("status") == "running"
                ):
                    await session.update_element(
                        e.get("element_id", ""),
                        {
                            **e.get("data", {}),
                            "status": "error",
                            "error": "interrupted",
                        },
                    )
            await session.finish(reason="interrupt", stopped=False)
        # 重置卡状态：下个回合开新卡（SDK sealed 后 append 自动重开）
        session.reset_for_new_card()
        return

    # 审批卡特殊路由：permission_card / permission_decided 的 session_id 字段是
    # hermes session_key（send_exec_approval 无 hermes session_id），不能走
    # session 路由。改为按 conv_id 定位活跃 session（聚合卡激活期间审批嵌入）。
    if kind in ("permission_card", "permission_decided"):
        conv_id = event.get("conv_id") or ""
        session = get_active_by_conv(conv_id) if conv_id else None
        # permission_decided 在回合结束后（session 已注销）仍需处理：走持久映射。
        if kind == "permission_decided" and session is None:
            oc_request_id = event.get("session_key") or ""
            decision = event.get("decision") or ""
            if not oc_request_id:
                return
            record = get_permission_card(oc_request_id)
            if not record or not record.get("msg_id"):
                logger.info(
                    "Wanling: permission_decided 无定位映射（已清理的重复决策或未知 session）%s",
                    oc_request_id,
                )
                return
            status = _permission_status(decision)
            content = {
                "msg_type": "aggregate_card",
                "data": {
                    "op": "update",
                    "element_id": record["element_id"],
                    "data": {"oc_request_id": oc_request_id, "status": status, "result": decision},
                },
            }
            # 直接经 adapter REST PATCH 历史消息。两 PATCH 均落地才清理持久映射
            # （防泄漏）；失败保留映射，重复决策可重试恢复，避免审批卡永停 pending。
            resp_update = await adapter._rest(
                "PATCH", f"/api/messages/{record['msg_id']}", {"content": content}
            )
            resp_silent = await adapter._rest(
                "PATCH",
                f"/api/messages/{record['msg_id']}",
                {"content": {
                    "msg_type": "aggregate_card",
                    "data": {"op": "set_silent", "silent": True},
                }},
            )
            if (
                isinstance(resp_update, dict) and resp_update.get("ok")
                and isinstance(resp_silent, dict) and resp_silent.get("ok")
            ):
                drop_permission_card(oc_request_id)
            return
        if session is None:
            return
        if kind == "permission_card":
            eid = session.next_element_id("permission_card")
            await session.append_element(
                "permission_card",
                {
                    "oc_request_id": event.get("session_key") or "",
                    "action": event.get("action") or "",
                    "resources": event.get("resources") or [],
                    "status": "pending",
                    "title": event.get("title") or "",
                },
                element_id=eid,
            )
            # pending 审批元素出现 → 翻转整卡 silent=false 响铃（需用户介入）。
            # 对齐 opencode：aggregate 模式下审批卡同样翻转（用户要被提醒才处理）。
            try:
                await session.io.patch(
                    session.io.card_msg_id, {"op": "set_silent", "silent": False}
                )
            except Exception:
                logger.warning(
                    "Wanling aggregate 审批 set_silent 失败 conv=%s", conv_id
                )
            # 记录持久映射（回合结束后 session 可能注销，决策时仍能定位 PATCH）
            sk = event.get("session_key") or ""
            if sk:
                remember_permission_card(sk, conv_id, session.io.card_msg_id or "", eid)
        else:
            oc_request_id = event.get("session_key") or ""
            decision = event.get("decision") or ""
            if not oc_request_id:
                return
            status = _permission_status(decision)
            patch_data = {"oc_request_id": oc_request_id, "status": status, "result": decision}
            # 优先活跃 session（回合中审批）：按元素定位 update
            eid = ""
            for e in reversed(session._elements):
                if (
                    e.get("type") == "permission_card"
                    and e.get("data", {}).get("oc_request_id") == oc_request_id
                    and e.get("data", {}).get("status") == "pending"
                ):
                    eid = e.get("element_id", "")
                    break
            if eid:
                # update 与 set_silent 均落地才 drop 映射；任一失败保留映射，
                # 让重复决策能重走整条路径恢复 silent（否则审批卡永停 pending）。
                if await session.update_element(eid, patch_data):
                    # 审批解决 → 翻转 silent=true 恢复安静（对齐 opencode：终态后不打扰）。
                    owner = session.io.element_cards.get(eid) or session.io.card_msg_id
                    try:
                        await session.io.patch(owner, {"op": "set_silent", "silent": True})
                    except Exception:
                        logger.warning(
                            "Wanling aggregate 审批恢复 silent 失败 conv=%s", conv_id
                        )
                    else:
                        # 审批终态落地 → 清理持久映射（防泄漏）
                        drop_permission_card(oc_request_id)
            else:
                # 回合结束后 session 已注销：用持久映射直接 PATCH 该消息。
                # update 与 set_silent 均落地才 drop 映射；任一失败保留映射
                # 供重复决策重试恢复。
                record = get_permission_card(oc_request_id)
                if record and record.get("msg_id"):
                    resp_update = await adapter._rest(
                        "PATCH",
                        f"/api/messages/{record['msg_id']}",
                        {"content": {
                            "msg_type": "aggregate_card",
                            "data": {
                                "op": "update",
                                "element_id": record["element_id"],
                                "data": patch_data,
                            },
                        }},
                    )
                    # 审批解决 → silent=true 恢复安静（不再响铃/未读）
                    resp_silent = await adapter._rest(
                        "PATCH",
                        f"/api/messages/{record['msg_id']}",
                        {"content": {
                            "msg_type": "aggregate_card",
                            "data": {"op": "set_silent", "silent": True},
                        }},
                    )
                    if (
                        isinstance(resp_update, dict) and resp_update.get("ok")
                        and isinstance(resp_silent, dict) and resp_silent.get("ok")
                    ):
                        # 审批终态落地 → 清理持久映射（防泄漏）
                        drop_permission_card(oc_request_id)
                else:
                    logger.info(
                        "Wanling: permission_decided 无定位映射（已清理的重复决策或未知 session）%s",
                        oc_request_id,
                    )
        return

    session_id = event.get("session_id") or ""
    if not session_id:
        return
    turn_id = event.get("turn_id") or ""

    # 新回合：注销旧 session（上回合已 finish 或异常残留），下个事件重建新卡。
    reused_conv_id = ""
    is_new = _is_new_turn(session_id, turn_id)
    if is_new:
        old = get_session(session_id)
        if old is not None:
            reused_conv_id = old.conv_id  # 同 session 的 conv_id 恒定，重建沿用
            if not old._finalized:
                # 上回合未正常收尾（异常中断）→ 补收尾防卡 generating。
                try:
                    await old.finish(reason="interrupt", stopped=False)
                except Exception:
                    pass
        unregister_session(session_id)
        logger.debug(
            "Wanling aggregate: 新回合 session=%s turn=%r reused_conv=%s",
            session_id, turn_id, bool(reused_conv_id),
        )

    session = get_session(session_id)
    if session is None:
        # 首事件：拿 conv_id 建 session。优先级：持久记忆 > 新回合复用 > sender 反查。
        conv_id = (
            get_session_conv(session_id)
            or reused_conv_id
            or event.get("conv_id")
            or ""
        )
        if not conv_id:
            sender_id = event.get("sender_id") or event.get("sender_conv_id") or ""
            lookup = getattr(adapter, "lookup_conv_by_user", None)
            if lookup is None or not sender_id:
                return
            conv_id = lookup(sender_id)
        if not conv_id:
            return
        session = AggregateSession(session_id, conv_id, adapter)
        remember_session_conv(session_id, conv_id)
        register_session(session)

    if kind == "pre_llm_call":
        # 回合开始（LLM 首次调用）：首个 append 经 SDK 幂等建卡。后续工具循环
        # 的多次 pre_llm_call 复用同一卡（SDK ensure 幂等）。
        # 引用锚点：建卡前从 adapter 取最近用户消息 id（io send_card 注入 data.quote）。
        if not session.io.quote_message_id:
            getter = getattr(adapter, "last_user_msg_id", None)
            if getter is not None:
                session.io.quote_message_id = getter(session.conv_id) or None
        # 首次建卡：append reasoning 占位（finished=false，APP 显示「正在思考...」），
        # 避免建卡瞬间空卡突兀。真实 reasoning（回合末）update 该元素为终态。
        if not session._elements:
            placeholder_id = session.next_element_id("reasoning")
            await session.append_element(
                "reasoning",
                {"text": "", "finished": False},
                element_id=placeholder_id,
            )
    elif kind == "tool_start":
        name = event.get("tool_name") or "tool"
        args = event.get("args")
        if not isinstance(args, dict):
            args = {"value": str(args)}
        eid = session.next_element_id("tool_card")
        await session.append_element(
            "tool_card",
            {"name": name, "input": args, "status": "running"},
            element_id=eid,
        )
    elif kind == "tool_end":
        # 定位对应 tool_card：同一回合工具串行，取最后 append 的、匹配工具名
        # 且仍 running 的 tool_card 元素（hermes pre/post 成对，无并发交叠）。
        name = event.get("tool_name") or ""
        eid = ""
        for e in reversed(session._elements):
            if (
                e.get("type") == "tool_card"
                and e.get("data", {}).get("name") == name
                and e.get("data", {}).get("status") == "running"
            ):
                eid = e.get("element_id", "")
                break
        if not eid:
            return
        # 全量 data（设防点：旧卡元素 update 是整体替换，缺 name/input 会丢字段）
        data: Dict[str, Any] = {
            "name": name or "",
            "input": event.get("args") or {},
            # 对齐 opencode 协议终态值:completed(APP renderer 只认 completed/error,
            # done 会落到 default 走 running 卡 → 显示「进行中」)。
            "status": "error" if event.get("error_type") or event.get("status") == "error" else "completed",
        }
        result = event.get("result")
        if result is not None and result != "":
            if isinstance(result, str):
                data["output"] = result
            else:
                data["output"] = _json_dumps(result)
        if event.get("error_message"):
            data["error"] = str(event["error_message"])
        if event.get("duration_ms"):
            data["duration"] = float(event["duration_ms"]) / 1000.0
        await session.update_element(eid, data)
    elif kind == "reasoning":
        # 终态思考（post_llm_call 回合末）：把最后一个未终态思考块（当前思考）
        # 标为 finished=true；无未终态块则 append 新终态元素。
        text = event.get("text") or ""
        if text.strip():
            target_id = ""
            for e in reversed(session._elements):
                if (
                    e.get("type") == "reasoning"
                    and e.get("data", {}).get("finished") is False
                ):
                    target_id = e.get("element_id", "")
                    break
            if target_id:
                await session.update_element(
                    target_id, {"text": text, "finished": True}
                )
            else:
                eid = session.next_element_id("reasoning")
                await session.append_element(
                    "reasoning", {"text": text, "finished": True}, element_id=eid,
                )
                # 思考应在正文之前：reasoning 后 reorder，把 reasoning 移到所有
                # markdown 元素之前（工具卡之后）。hermes 中间文本先进卡导致
                # markdown 在 reasoning 前，reorder 纠正时序。
                await session.reorder_reasoning_before_markdown(eid)
    elif kind == "reasoning_delta":
        # 段落级实时思考（post_api_request 每轮 LLM 调用后触发）：对齐 opencode，
        # 每轮思考独立 reasoning 元素（多块渲染）。状态机：
        # - 最后一个 reasoning 是空文本占位（建卡）→ update 为当前思考（首块）
        # - 最后一个 reasoning 已有内容（前一块思考）→ 先标 finished=true 结束前块，
        #   再 append 新块（finished=false，当前思考中）
        # - 最后一个 reasoning 已终态 / 不存在 → append 新块
        text = event.get("text") or ""
        if not text.strip():
            return
        last_id, last_text, last_finished = "", "", False
        for e in reversed(session._elements):
            if e.get("type") == "reasoning":
                last_id = e.get("element_id", "")
                last_text = str(e.get("data", {}).get("text") or "").strip()
                last_finished = bool(e.get("data", {}).get("finished"))
                break
        if last_id and not last_finished:
            if not last_text:
                # 建卡占位（空文本）：首块，update 为当前思考（保持 finished=false）
                await session.update_element(last_id, {"text": text, "finished": False})
                return
            # 前一块已有内容：新思考到达 = 前块结束，标终态
            await session.update_element(
                last_id, {"text": last_text, "finished": True}
            )
        eid = session.next_element_id("reasoning")
        await session.append_element(
            "reasoning", {"text": text, "finished": False}, element_id=eid,
        )
        await session.reorder_reasoning_before_markdown(eid)
    elif kind == "markdown":
        # 最终正文（post_llm_call）：累积到单一正文元素（覆盖中间快照），
        # 随后 reorder 把正文移到末尾（reasoning 后、footer 前）。
        text = event.get("text") or ""
        await session.append_or_merge_markdown(text)
        await session.reorder_markdown_to_end()
    elif kind == "markdown_update":
        # 中间文本（send 触发）：累积到单一正文元素（流式 build，位置暂不定）。
        text = event.get("text") or ""
        await session.append_or_merge_markdown(text)
    elif kind == "finish":
        await session.finish(
            reason=event.get("reason", "stop"),
            stopped=bool(event.get("stopped")),
            model=event.get("model"),
            mode=event.get("mode"),
            tokens=event.get("tokens"),
            duration=event.get("duration"),
        )
        unregister_session(session_id)
        forget_session_sender(session_id)


def _json_dumps(value: Any) -> str:
    import json

    return json.dumps(value, ensure_ascii=False, default=str)
