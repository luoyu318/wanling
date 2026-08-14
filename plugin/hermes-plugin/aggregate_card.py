"""Wanling 聚合卡核心模块（hermes-plugin 聚合模式）。

聚合卡协议见 docs/ai-handbook/aggregate-card.md：一次问答一条消息，
elements[] 按时序承载全部步骤。本模块把 hermes 的工具事件 / 回合收尾
映射为聚合卡 elements，经 REST 建卡 + 增量 PATCH 发送到 wanling server。

数据流：
  hermes hook（同步 worker 线程）→ emit_event() 分发到活跃 adapter
  → adapter 实例的线程安全队列 → adapter 异步消费者 task
  → AggregateCardManager 串行 REST 建卡/PATCH

完全走 hermes 官方插件 hook 机制（raft 先例），不修改 hermes 主程序。

adapter 需实现：
  enqueue_aggregate_event(event: dict)  —— 线程安全入队
  lookup_conv_by_user(user_id: str)    —— user_id → conv_id（入站记录）
  aggregate_token()                    —— 最新 agent JWT
"""

import asyncio
import json
import logging
import os
import threading
import urllib.request
import weakref
from typing import Any, Callable, Dict, List, Optional

logger = logging.getLogger(__name__)

# 单张聚合卡元素上限（对齐 opencode-plugin MAX_AGGREGATE_ELEMENTS_PER_CARD）。
MAX_AGGREGATE_ELEMENTS_PER_CARD = 20

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


# ── 会话上下文（一个问答回合一张聚合卡） ────────────────────────────

class AggregateCardManager:
    """一个 hermes 会话（session_id）对应的聚合卡发送端。

    生命周期 = 一个问答回合：首个 pre_llm_call 建卡（幂等），回合中
    工具事件实时 append/update 元素，回合结束 finish() 追加 footer +
    翻转 state done + silent false（计未读）。分卡：元素达上限时旧卡
    set_state done + set_segment middle，新卡承接后续元素。
    """

    def __init__(
        self,
        session_id: str,
        conv_id: str,
        server_url: str,
        token_getter: Callable[[], str],
    ):
        self.session_id = session_id
        self.conv_id = conv_id
        self.server_url = server_url.rstrip("/")
        self.token_getter = token_getter
        self._seq = 0
        self._card_msg_id: Optional[str] = None
        self._elements: List[Dict[str, Any]] = []
        self._segment_index = 0
        self._inflight: Optional[asyncio.Future] = None
        self._finalized = False
        # 建卡引用锚点：触发本次回复的用户消息 id（建卡 POST 带 data.quote）。
        self.quote_message_id: Optional[str] = None
        # 正文元素 id：hermes 的 send() 收到同一段正文的递增累积快照，
        # 中间文本与最终正文都 update 到同一 markdown 元素（流式 build），
        # 避免「多条独立段 + 重复」。
        self._markdown_id: Optional[str] = None
        # 元素归属卡：element_id → 所在聚合卡 message_id。分卡后旧卡元素
        # update/reorder 仍能定位到正确消息（对齐 opencode aggregateElementCardIds），
        # 否则旧卡元素操作会误打当前新卡 → server 400「元素不存在」。
        self._element_card_ids: Dict[str, str] = {}

    # ── REST 通道（agent JWT 鉴权，对齐 opencode-plugin client） ────

    def _rest_sync(self, method: str, path: str, body: Optional[dict]) -> Optional[Dict[str, Any]]:
        token = self.token_getter()
        req = urllib.request.Request(
            f"{self.server_url}{path}",
            data=json.dumps(body).encode() if body is not None else None,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Bearer {token}" if token else "",
            },
            method=method,
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                raw = resp.read()
                if not raw:
                    return {"ok": True}  # 204 等空响应（如 DELETE recall）
                payload = json.loads(raw)
        except urllib.error.HTTPError as e:
            try:
                payload = json.loads(e.read())
            except Exception:
                payload = {"ok": False}
        except Exception as e:
            logger.error("Wanling aggregate REST %s %s failed — %s", method, path, e)
            return None
        return payload

    async def _rest(self, method: str, path: str, body: Optional[dict]) -> Optional[Dict[str, Any]]:
        return await asyncio.to_thread(self._rest_sync, method, path, body)

    # ── 建卡 ─────────────────────────────────────────────────────────

    async def ensure_card(self) -> Optional[str]:
        """建聚合卡（幂等，已建复用）。返回 server 分配的 message_id。"""
        if self._card_msg_id:
            return self._card_msg_id
        if self._inflight is not None:
            try:
                return await self._inflight
            except Exception:
                pass
        fut = asyncio.ensure_future(self._create_card())
        self._inflight = fut
        try:
            return await fut
        finally:
            if self._inflight is fut:
                self._inflight = None

    async def _create_card(self) -> Optional[str]:
        data: Dict[str, Any] = {
            "schema_ver": 1,
            "state": "generating",
            "elements": [],
        }
        if self._segment_index > 0:
            data["segment"] = "last"
        # 引用锚点：建卡带 data.quote（server PersistAndDispatch 富化 sender/preview）
        if self.quote_message_id:
            data["quote"] = {"message_id": self.quote_message_id}
        content = {"msg_type": "aggregate_card", "data": data, "silent": True}
        resp = await self._rest(
            "POST", f"/api/conversations/{self.conv_id}/messages",
            {"content": content},
        )
        if not isinstance(resp, dict) or not resp.get("ok"):
            logger.warning("Wanling aggregate create failed conv=%s", self.conv_id)
            return None
        msg_id = (resp.get("data") or {}).get("message_id")
        if not msg_id:
            logger.warning("Wanling aggregate create: 响应缺 message_id conv=%s", self.conv_id)
            return None
        self._card_msg_id = msg_id
        return msg_id

    # ── 元素操作 ─────────────────────────────────────────────────────

    def next_element_id(self, type_: str) -> str:
        self._seq += 1
        return f"{type_}_{self._seq}"

    async def _seal_intermediate_card(self) -> None:
        """分卡：旧卡 set_state done + set_segment middle（不翻 silent、不写 footer）。

        清空本卡元素累计（含 _markdown_id），保留 _element_card_ids 归属映射
        （旧卡元素 update/reorder 仍定位旧卡），让后续 ensure_card 重开新卡。
        对齐 opencode _sealIntermediateCard：不清累计会导致每次 append 再触发分卡。
        清空前先 _settle_unfinished_elements 收尾旧卡未终态元素（否则脱离 finish 盲区）。
        """
        if not self._card_msg_id:
            return
        await self._settle_unfinished_elements()
        await self._patch({"op": "set_state", "state": "done"})
        await self._patch({"op": "set_segment", "segment": "middle"})
        self._elements = []
        self._markdown_id = None

    async def _settle_unfinished_elements(self) -> None:
        """收尾未终态元素（对齐 opencode 中断 flush 终态语义）：

        - 空文本 reasoning 占位（未被任何思考 update）→ 删除，避免卡显示「思考中」空块
        - 非空文本但仍 finished=false 的思考块 → 标 finished=true 保留内容
        - running 工具卡（tool_end 未到，被中断/异常）→ 标 error，避免永久 pending
        按元素归属卡 PATCH（分卡后旧卡元素仍定位正确）。
        """
        for e in list(self._elements):
            if e.get("type") == "reasoning" and e.get("data", {}).get("finished") is False:
                rid = e.get("element_id", "")
                owner = self._element_card_ids.get(rid) or self._card_msg_id
                rtext = str(e.get("data", {}).get("text") or "").strip()
                if not rtext:
                    await self._patch_msg(owner, {"op": "remove", "element_id": rid})
                    self._elements = [
                        x for x in self._elements if x.get("element_id") != rid
                    ]
                else:
                    await self._patch_msg(owner, {
                        "op": "update",
                        "element_id": rid,
                        "data": {**e.get("data", {}), "finished": True},
                    })
                    self._elements = [
                        {**x, "data": {**x.get("data", {}), "finished": True}}
                        if x.get("element_id") == rid else x
                        for x in self._elements
                    ]
            elif e.get("type") == "tool_card" and e.get("data", {}).get("status") == "running":
                eid = e.get("element_id", "")
                owner = self._element_card_ids.get(eid) or self._card_msg_id
                await self._patch_msg(owner, {
                    "op": "update",
                    "element_id": eid,
                    "data": {**e.get("data", {}), "status": "error", "error": "interrupted"},
                })
                self._elements = [
                    x if x.get("element_id") != eid
                    else {**x, "data": {**x.get("data", {}), "status": "error", "error": "interrupted"}}
                    for x in self._elements
                ]

    async def append_element(
        self,
        type_: str,
        data: Dict[str, Any],
        *,
        element_id: Optional[str] = None,
    ) -> None:
        """增量 append 元素；同 element_id 已存在 → 改发 update（原位替换）。"""
        if self._finalized:
            return
        eid = element_id or self.next_element_id(type_)
        existed = any(e.get("element_id") == eid for e in self._elements)
        if not existed and len(self._elements) >= MAX_AGGREGATE_ELEMENTS_PER_CARD:
            await self._seal_intermediate_card()
            self._segment_index += 1
            self._card_msg_id = None
            self._markdown_id = None  # 分卡后新卡重新 append 正文元素
            await self.ensure_card()
        element = {"type": type_, "element_id": eid, "data": data}
        if existed:
            self._elements = [
                e if e.get("element_id") != eid else element for e in self._elements
            ]
            await self._patch({"op": "update", "element_id": eid, "data": data})
        else:
            self._elements.append(element)
            await self.ensure_card()
            # 记录元素归属卡：分卡后旧卡元素 update 仍能定位（工具终态/reasoning 终态）。
            self._element_card_ids[eid] = self._card_msg_id or ""
            await self._patch({"op": "append", "element": element})

    async def update_element(self, element_id: str, data: Dict[str, Any]) -> bool:
        """按 element_id 整体替换元素 data（工具终态/状态推进）。

        返回 True 表示 PATCH 落地；finalized 早退、无归属映射或
        PATCH 失败返回 False。

        分卡后旧卡元素已不在 _elements 累计（_seal_intermediate_card 清空），
        但 _element_card_ids 归属映射保留：按归属 PATCH 到正确消息
        （对齐 opencode aggregateElementCardIds），避免误打当前新卡 → 400。
        """
        if self._finalized:
            return False
        owner = self._element_card_ids.get(element_id)
        if owner is None:
            logger.debug(
                "Wanling aggregate update unknown element %s (skipped)", element_id
            )
            return False
        self._elements = [
            e if e.get("element_id") != element_id else {**e, "data": data}
            for e in self._elements
        ]
        return await self._patch_msg(owner, {"op": "update", "element_id": element_id, "data": data})

    async def append_or_merge_markdown(self, text: str, *, final: bool = False) -> None:
        """追加 markdown 元素；相邻前缀重叠则合并（防重复），否则独立元素。

        hermes 的 send() 收到中间文本（执行中输出），post_llm_call 收到最终正文。
        两者可能开头重叠（LLM 把同一句先说一遍再展开，如「8月12日 的热点来了（」
        与「8月12日 的热点来了（AIHOT 已更新）：...」）。处理：
        - 新文本 startswith 最后一条 markdown → update 它为较长者（合并去重）
        - 最后一条 markdown startswith 新文本 → 忽略（已更长）
        - 否则 → append 独立元素（中间文本各段保留，不拼接不覆盖）
        整卡可有多个 markdown 元素（执行中输出各段 + 最终正文），相邻重叠合并。
        """
        if self._finalized or not text or not text.strip():
            return
        text = text.strip()
        # 找最后一条 markdown 元素
        last_id = ""
        last_text = ""
        for e in reversed(self._elements):
            if e.get("type") == "markdown":
                last_id = e.get("element_id", "")
                last_text = str(e.get("data", {}).get("text") or "").strip()
                break
        if last_id and last_text:
            if text.startswith(last_text) and text != last_text:
                await self.update_element(last_id, {"text": text})
                self._markdown_id = last_id
                return
            if last_text.startswith(text):
                self._markdown_id = last_id
                return  # 最后元素已更长（更完整的快照），忽略
        eid = self.next_element_id("markdown")
        await self.append_element("markdown", {"text": text}, element_id=eid)
        self._markdown_id = eid

    def _current_card_element_ids(self) -> set:
        """当前卡（_card_msg_id）上的元素 id 集合（分卡后旧卡元素不在此列）。"""
        current = self._card_msg_id
        if not current:
            return set()
        return {
            eid for eid, mid in self._element_card_ids.items() if mid == current
        }

    async def reorder_markdown_to_end(self) -> None:
        """reorder：把正文（markdown）元素移到末尾（reasoning/工具卡之后、footer 前）。

        生成中正文元素可能因中间文本先到而落在工具卡之间；回合末最终正文后
        reorder 归位：[工具卡/审批/reasoning..., markdown..., footer]。
        仅作用于当前卡元素（分卡后旧卡已 seal，元素顺序定格）。
        """
        if self._finalized:
            return
        current_ids = self._current_card_element_ids()
        if not current_ids:
            return
        markdown_ids = [
            e.get("element_id", "")
            for e in self._elements
            if e.get("type") == "markdown" and e.get("element_id", "") in current_ids
        ]
        if not markdown_ids:
            return
        ordered: List[str] = [
            e.get("element_id", "")
            for e in self._elements
            if e.get("element_id", "") in current_ids
            and e.get("element_id", "") not in markdown_ids
        ]
        ordered.extend(markdown_ids)
        # 已末尾短路：卡内影子副本顺序与目标一致时跳过 PATCH（避免无谓请求）
        current_order = [
            e.get("element_id", "")
            for e in self._elements
            if e.get("element_id", "") in current_ids
        ]
        if ordered == current_order:
            return  # markdown 已在末尾，无需 reorder
        await self._patch({"op": "reorder", "order": ordered})

    async def reorder_reasoning_before_markdown(self, reasoning_id: str) -> None:
        """reorder：把 reasoning 元素移到所有 markdown 元素之前（工具卡之后）。

        hermes 中间文本（send 触发）先于 reasoning 进卡，导致 markdown 在
        reasoning 前；回合末 append reasoning 后，重排为
        [工具卡..., reasoning, markdown..., footer]。
        仅作用于当前卡元素（分卡后旧卡已 seal，元素顺序定格）。
        """
        current_ids = self._current_card_element_ids()
        if not current_ids:
            return
        ordered: List[str] = []
        markdown_ids: List[str] = []
        for e in self._elements:
            eid = e.get("element_id", "")
            if eid not in current_ids:
                continue  # 旧卡元素不参与当前卡 reorder
            if eid == reasoning_id:
                continue
            if e.get("type") == "markdown":
                markdown_ids.append(eid)
            else:
                ordered.append(eid)
        # 插入：非 markdown 元素（工具卡等）之后、markdown 之前
        idx = len(ordered)
        ordered[idx:idx] = [reasoning_id]
        ordered.extend(markdown_ids)
        if ordered:
            await self._patch({"op": "reorder", "order": ordered})

    # ── 收尾 ─────────────────────────────────────────────────────────

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
        """回合结束收尾：追加 footer + 翻转 state done + silent false（计未读）。"""
        if self._finalized:
            return
        self._finalized = True
        # reasoning 收尾 + running 工具兜底：抽到 _settle_unfinished_elements 共用
        # （分卡 seal 也调用），未终态元素按归属卡 PATCH，避免旧卡元素脱离收尾盲区。
        await self._settle_unfinished_elements()
        footer_data: Dict[str, Any] = {"reason": reason, "finished": True}
        if stopped:
            footer_data["stopped"] = True
        if model:
            footer_data["model"] = model
        if mode:
            footer_data["mode"] = mode
        if tokens:
            footer_data["tokens"] = tokens
        if duration:
            footer_data["duration"] = duration
        footer_id = self.next_element_id("footer")
        element = {"type": "footer", "element_id": footer_id, "data": footer_data}
        self._elements.append(element)
        await self._patch({"op": "append", "element": element})
        await self._patch({"op": "set_state", "state": "done"})
        await self._patch({"op": "set_silent", "silent": False})

        # 空卡清理：回合结束卡里只有 footer（无工具/思考/正文实际内容）时，
        # 撤回该消息（scope=recall，全员不可见），避免用户看到空卡。典型场景：
        # interrupt 断卡后新回合被立即打断，只建卡没内容。recall 需 5 分钟内 +
        # sender 本人（agent 是 sender），空卡刚建满足条件。hide 仅对调用者隐藏，
        # 用户端仍可见空卡，故用 recall。
        if self._card_msg_id:
            content_ids = {
                e.get("type") for e in self._elements if e.get("type") != "footer"
            }
            if not content_ids:
                await self._rest(
                    "DELETE",
                    f"/api/messages/{self._card_msg_id}?scope=recall",
                    None,
                )
                logger.debug(
                    "Wanling aggregate: 空卡已撤回 conv=%s msg=%s",
                    self.conv_id, self._card_msg_id,
                )

    # ── 底层 PATCH ───────────────────────────────────────────────────

    async def _patch(self, data: Dict[str, Any]) -> None:
        """对当前卡（_card_msg_id）发增量 PATCH。"""
        await self._patch_msg(self._card_msg_id, data)

    async def _patch_msg(self, msg_id: Optional[str], data: Dict[str, Any]) -> bool:
        """对指定聚合卡消息发增量 PATCH（分卡后旧卡元素操作定位用）。

        返回 True 表示 PATCH 落地（server 返回 ok）；msg_id 为空或
        请求失败/被拒返回 False，调用方可据此决定是否保留恢复通道。
        """
        if not msg_id:
            return False
        content = {"msg_type": "aggregate_card", "data": data}
        resp = await self._rest(
            "PATCH", f"/api/messages/{msg_id}", {"content": content}
        )
        if not isinstance(resp, dict) or not resp.get("ok"):
            logger.warning(
                "Wanling aggregate PATCH failed conv=%s msg=%s op=%s",
                self.conv_id, msg_id, data.get("op"),
            )
            return False
        return True


# ── 会话上下文注册表（session_id → manager） ────────────────────────
#
# hermes hook（同步 worker 线程）只拿到 session_id / sender_id，需要反查
# conv_id 并找到对应 manager。adapter 消费者在收到首个回合事件时创建
# manager（用 adapter.lookup_conv_by_user 拿 conv_id），注册进本表；
# 回合结束 finish() 后注销（下个回合重建新卡）。

_SESSIONS: Dict[str, AggregateCardManager] = {}
_SESSIONS_LOCK = threading.Lock()
# session_id → 最近 turn_id（用于跨回合区分：新 turn 首事件重建 manager）。
_SESSION_TURNS: Dict[str, str] = {}
_SESSION_TURNS_LOCK = threading.Lock()

# session_id → sender_id（pre_llm_call 注册；tool hooks 无 sender_id 字段，
# 用此记忆在事件里补带，供消费者首事件兜底建 manager）。
_SESSION_SENDERS: Dict[str, str] = {}
_SESSION_SENDERS_LOCK = threading.Lock()
# session_id → conv_id 持久记忆（跨回合保留）。manager 回合结束注销后，
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


def get_active_by_conv(conv_id: str) -> Optional[AggregateCardManager]:
    """按 conv_id 找「聚合卡激活中」的 manager（未 finish）。

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

# 审批卡持久映射：session_key(oc_request_id) → {conv_id, msg_id, element_id}。
# 回合结束后 manager 可能已注销（审批决策晚于回合收尾），permission_decided
# 需脱离活跃 manager 直接 PATCH 该消息更新元素。
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


def take_conv_text(conv_id: str) -> bool:
    """adapter.send() 调用：命中则抑制正文并清除标记（一次性）。"""
    if not conv_id:
        return False
    with _CONV_TEXT_TAKEN_LOCK:
        if _CONV_TEXT_TAKEN.pop(conv_id, False):
            return True
    return False


def register_session(manager: AggregateCardManager) -> None:
    with _SESSIONS_LOCK:
        _SESSIONS[manager.session_id] = manager


def get_session(session_id: str) -> Optional[AggregateCardManager]:
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
    """adapter 事件循环内消费自己的事件队列，路由到 session manager。

    adapter 需提供：
      aggregate_events  —— 线程安全 queue.Queue
      aggregate_token() —— () -> str，最新 agent JWT
    """
    import queue as _queue

    q = getattr(adapter, "aggregate_events", None)
    if q is None:
        return
    server_url = getattr(adapter, "server_url", "")
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
            await _dispatch_event(adapter, event, server_url)
        except Exception as e:
            logger.debug("Wanling aggregate event dispatch failed: %s", e)


async def _dispatch_event(adapter: Any, event: Dict[str, Any], server_url: str) -> None:
    if not _aggregate_enabled():
        return
    kind = event.get("kind")

    # 断卡（interrupt）：Agent 执行中用户发新消息 → 结束当前聚合卡段落。
    # 按 conv_id 定位活跃 manager，finish(reason="interrupt") 收尾当前卡，
    # 重置正文/卡状态（保留 manager，下个回合 pre_llm_call 开新卡）。
    if kind == "interrupt":
        conv_id = event.get("conv_id") or ""
        manager = get_active_by_conv(conv_id) if conv_id else None
        if manager is None:
            return
        if not manager._finalized:
            # 收尾前：把 running 工具卡标 error（interrupt 打断工具执行，tool_end 不到）
            for e in list(manager._elements):
                if (
                    e.get("type") == "tool_card"
                    and e.get("data", {}).get("status") == "running"
                ):
                    eid = e.get("element_id", "")
                    await manager.update_element(
                        eid,
                        {
                            **e.get("data", {}),
                            "status": "error",
                            "error": "interrupted",
                        },
                    )
            await manager.finish(reason="interrupt", stopped=False)
        # 重置卡状态：下个回合 pre_llm_call 开新卡。_finalized 复位允许 append。
        manager._finalized = False
        manager._markdown_id = None
        manager._card_msg_id = None
        manager._elements = []
        return

    # 审批卡特殊路由：permission_card / permission_decided 的 session_id 字段是
    # hermes session_key（send_exec_approval 无 hermes session_id），不能走
    # session 路由。改为按 conv_id 定位活跃 manager（聚合卡激活期间审批嵌入）。
    if kind in ("permission_card", "permission_decided"):
        conv_id = event.get("conv_id") or ""
        manager = get_active_by_conv(conv_id) if conv_id else None
        # permission_decided 在回合结束后（manager 已注销）仍需处理：走持久映射。
        if kind == "permission_decided" and manager is None:
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
            status = "approved" if decision in ("allow_once", "allow_always", "once", "always") else "denied"
            content = {
                "msg_type": "aggregate_card",
                "data": {
                    "op": "update",
                    "element_id": record["element_id"],
                    "data": {"oc_request_id": oc_request_id, "status": status, "result": decision},
                },
            }
            # 独立临时 manager 持有 token/server_url，直接 PATCH 历史消息。
            # PATCH 落地才清理持久映射（防泄漏）；失败保留映射，
            # 重复决策可重试恢复，避免审批卡永停 pending。
            tmp = AggregateCardManager("", record["conv_id"], server_url, adapter.aggregate_token)
            resp = await tmp._rest("PATCH", f"/api/messages/{record['msg_id']}", {"content": content})
            if isinstance(resp, dict) and resp.get("ok"):
                drop_permission_card(oc_request_id)
            return
        if manager is None:
            return
        if kind == "permission_card":
            eid = manager.next_element_id("permission_card")
            await manager.append_element(
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
            await manager._patch({"op": "set_silent", "silent": False})
            # 记录持久映射（回合结束后 manager 可能注销，决策时仍能定位 PATCH）
            sk = event.get("session_key") or ""
            if sk:
                remember_permission_card(sk, conv_id, manager._card_msg_id or "", eid)
        else:
            oc_request_id = event.get("session_key") or ""
            decision = event.get("decision") or ""
            if not oc_request_id:
                return
            status = "approved" if decision in ("allow_once", "allow_always", "once", "always") else "denied"
            patch_data = {"oc_request_id": oc_request_id, "status": status, "result": decision}
            # 优先活跃 manager（回合中审批）：按元素定位 update
            eid = ""
            for e in reversed(manager._elements):
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
                if await manager.update_element(eid, patch_data):
                    # 审批解决 → 翻转 silent=true 恢复安静（对齐 opencode：终态后不打扰）。
                    owner = manager._element_card_ids.get(eid) or manager._card_msg_id
                    if await manager._patch_msg(owner, {"op": "set_silent", "silent": True}):
                        # 审批终态落地 → 清理持久映射（防泄漏）
                        drop_permission_card(oc_request_id)
            else:
                # 回合结束后 manager 已注销：用持久映射直接 PATCH 该消息。
                # update 与 set_silent 均落地才 drop 映射；任一失败保留映射
                # 供重复决策重试恢复。
                record = get_permission_card(oc_request_id)
                if record and record.get("msg_id"):
                    content = {
                        "msg_type": "aggregate_card",
                        "data": {
                            "op": "update",
                            "element_id": record["element_id"],
                            "data": patch_data,
                        },
                    }
                    resp_update = await manager._rest(
                        "PATCH",
                        f"/api/messages/{record['msg_id']}",
                        {"content": content},
                    )
                    # 审批解决 → silent=true 恢复安静（不再响铃/未读）
                    resp_silent = await manager._rest(
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

    # 新回合：注销旧 manager（上回合已 finish 或异常残留），下个事件重建新卡。
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

    manager = get_session(session_id)
    if manager is None:
        # 首事件：拿 conv_id 建 manager。优先级：持久记忆 > 新回合复用 > sender 反查。
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
        manager = AggregateCardManager(
            session_id, conv_id, server_url, adapter.aggregate_token,
        )
        remember_session_conv(session_id, conv_id)
        register_session(manager)

    if kind == "pre_llm_call":
        # 回合开始（LLM 首次调用）：确保卡已建。后续工具循环的多次
        # pre_llm_call 复用同一卡（ensure_card 幂等）。
        # 引用锚点：建卡前从 adapter 取最近用户消息 id（POST 带 data.quote）。
        if not manager.quote_message_id:
            getter = getattr(adapter, "last_user_msg_id", None)
            if getter is not None:
                manager.quote_message_id = getter(manager.conv_id) or None
        await manager.ensure_card()
        # 首次建卡：append reasoning 占位（finished=false，APP 显示「正在思考...」），
        # 避免建卡瞬间空卡突兀。真实 reasoning（回合末）update 该元素为终态。
        if not manager._elements:
            placeholder_id = manager.next_element_id("reasoning")
            await manager.append_element(
                "reasoning",
                {"text": "", "finished": False},
                element_id=placeholder_id,
            )
    elif kind == "tool_start":
        name = event.get("tool_name") or "tool"
        args = event.get("args")
        if not isinstance(args, dict):
            args = {"value": str(args)}
        eid = manager.next_element_id("tool_card")
        await manager.append_element(
            "tool_card",
            {"name": name, "input": args, "status": "running"},
            element_id=eid,
        )
    elif kind == "tool_end":
        # 定位对应 tool_card：同一回合工具串行，取最后 append 的、匹配工具名
        # 且仍 running 的 tool_card 元素（hermes pre/post 成对，无并发交叠）。
        name = event.get("tool_name") or ""
        eid = ""
        for e in reversed(manager._elements):
            if (
                e.get("type") == "tool_card"
                and e.get("data", {}).get("name") == name
                and e.get("data", {}).get("status") == "running"
            ):
                eid = e.get("element_id", "")
                break
        if not eid:
            return
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
                data["output"] = json.dumps(result, ensure_ascii=False, default=str)
        if event.get("error_message"):
            data["error"] = str(event["error_message"])
        if event.get("duration_ms"):
            data["duration"] = float(event["duration_ms"]) / 1000.0
        await manager.update_element(eid, data)
    elif kind == "reasoning":
        # 终态思考（post_llm_call 回合末）：把最后一个未终态思考块（当前思考）
        # 标为 finished=true；无未终态块则 append 新终态元素。
        text = event.get("text") or ""
        if text.strip():
            target_id = ""
            for e in reversed(manager._elements):
                if (
                    e.get("type") == "reasoning"
                    and e.get("data", {}).get("finished") is False
                ):
                    target_id = e.get("element_id", "")
                    break
            if target_id:
                await manager.update_element(
                    target_id, {"text": text, "finished": True}
                )
            else:
                eid = manager.next_element_id("reasoning")
                await manager.append_element(
                    "reasoning", {"text": text, "finished": True}, element_id=eid,
                )
                # 思考应在正文之前：reasoning 后 reorder，把 reasoning 移到所有
                # markdown 元素之前（工具卡之后）。hermes 中间文本先进卡导致
                # markdown 在 reasoning 前，reorder 纠正时序。
                await manager.reorder_reasoning_before_markdown(eid)
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
        for e in reversed(manager._elements):
            if e.get("type") == "reasoning":
                last_id = e.get("element_id", "")
                last_text = str(e.get("data", {}).get("text") or "").strip()
                last_finished = bool(e.get("data", {}).get("finished"))
                break
        if last_id and not last_finished:
            if not last_text:
                # 建卡占位（空文本）：首块，update 为当前思考（保持 finished=false）
                await manager.update_element(last_id, {"text": text, "finished": False})
                return
            # 前一块已有内容：新思考到达 = 前块结束，标终态
            await manager.update_element(
                last_id, {"text": last_text, "finished": True}
            )
        eid = manager.next_element_id("reasoning")
        await manager.append_element(
            "reasoning", {"text": text, "finished": False}, element_id=eid,
        )
        await manager.reorder_reasoning_before_markdown(eid)
    elif kind == "markdown":
        # 最终正文（post_llm_call）：累积到单一正文元素（覆盖中间快照），
        # 随后 reorder 把正文移到末尾（reasoning 后、footer 前）。
        text = event.get("text") or ""
        await manager.append_or_merge_markdown(text)
        await manager.reorder_markdown_to_end()
    elif kind == "markdown_update":
        # 中间文本（send 触发）：累积到单一正文元素（流式 build，位置暂不定）。
        text = event.get("text") or ""
        await manager.append_or_merge_markdown(text)
    elif kind == "finish":
        await manager.finish(
            reason=event.get("reason", "stop"),
            stopped=bool(event.get("stopped")),
            model=event.get("model"),
            mode=event.get("mode"),
            tokens=event.get("tokens"),
            duration=event.get("duration"),
        )
        unregister_session(session_id)
        forget_session_sender(session_id)
