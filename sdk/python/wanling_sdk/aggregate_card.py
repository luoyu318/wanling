"""聚合卡高层封装(与 TS aggregate_card.ts 对称)。

一次问答一张卡 — 建卡幂等(inflight 缓存防并发双卡)、PATCH 串行队列
(吞前次失败防坏链)、同 element_id append 自动改 update、20 元素自动分卡
(set_segment first/middle/last + 跨卡归属映射)、未就绪元素 update 缓存补发、
连续失败降级全量替换自愈(可选)。io 构造注入,不依赖 client。
"""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from typing import Any, TypeVar

T = TypeVar("T")

# 分卡上限:单卡元素数达 20 时追加新元素前自动开新卡(中间卡收尾不写 footer,
# 只有最后一张卡 finish 写 footer + 翻 silent 计未读)。与 plugin 侧
# MAX_AGGREGATE_ELEMENTS_PER_CARD 保持一致,硬性约束单卡 content 体积。
MAX_ELEMENTS = 20

# 聚合卡协议 schema 版本,建卡全量 content 携带(缺失视为 1)。
AGGREGATE_SCHEMA_VER = 1


class AggregateCard:
    """聚合卡会话:append/update/finish/interrupt,状态机对齐 TS 实现。

    io 协议(均为 async 方法,构造注入):
    - send_card(data: {msg_type, data}) -> str          建卡,返回消息 id
    - patch(message_id, op) -> Any                       聚合卡增量 PATCH
    - update_content(message_id, content) -> Any         全量替换(降级自愈用)
    - recall(message_id) -> None                         撤回删卡(可选,recallEmpty 用)
    """

    def __init__(self, conv_id: str, io: Any, opts: dict[str, Any] | None = None) -> None:
        self._conv_id = conv_id
        self._io = io
        self._opts: dict[str, Any] = dict(opts or {})
        # 当前卡消息 id(空串 = 未建卡/已收尾待重建)
        self._message_id = ""
        # 建卡请求飞行缓存:并发首调共享同一任务,只发一次建卡(防双卡)
        self._inflight: asyncio.Task | None = None
        # PATCH 串行队列:所有增量 op 按入队顺序执行,前次失败被吞不坏链
        self._queue: asyncio.Task | None = None
        # 跨卡归属映射:element_id → 所在卡 id(分卡后旧卡元素 update 仍定位旧卡)
        self._element_card_ids: dict[str, str] = {}
        # 未就绪元素的 update 缓存:append 落地后合并补发(多次 update 字段合并)
        self._pending_updates: dict[str, dict[str, Any]] = {}
        # PATCH 连续失败计数(成功清零;连续 3 次且开启自愈 → 降级全量替换)
        self._failure_count = 0
        # 本回合收尾标记:finish/interrupt 幂等守卫;再 append 视为新回合重置
        self._sealed = False
        # 当前卡本地影子镜像:分卡计数 / 同 id 检测 / update 合并 / 降级全量替换兜底
        self._mirror: list[dict[str, Any]] = []
        # 分卡序号:0=首卡,>0 已切卡;旧卡收尾时按序号打 first/middle,新卡建卡带 last
        self._segment_index = 0
        # 当前卡 data.segment 标记(降级全量替换时随影子副本携带)
        self._current_segment: str | None = None
        # 当前卡状态(降级全量替换时随影子副本携带)
        self._card_state: str = "generating"
        self._footer_seq = 0
        # element_id 自动生成计数器:单一全局 seq 跨 type/跨卡递增(全卡唯一),
        # 收尾 _reset_round 归零后下一轮复用(reasoning_1),对齐 plugin aggregateSeq。
        self._seq = 0

    def _enqueue(self, fn: Callable[[], Awaitable[T]]) -> asyncio.Task[T]:
        """串行队列:fn 排在先前所有 op 之后执行;队列本身吞掉前次失败
        (防坏链,等价 TS then(fn, fn)),fn 自身的错误仍向调用方传播。"""
        prev = self._queue

        async def _chained() -> T:
            if prev is not None:
                try:
                    await prev
                except Exception:  # noqa: S110, BLE001 - 前次失败不坏链,本次照常执行
                    pass
            return await fn()

        task = asyncio.ensure_future(_chained())
        self._queue = task
        return task

    async def _ensure_card(self) -> None:
        """建卡幂等:已有卡直接返回;建卡飞行中共享 inflight 防并发双卡;
        收尾(sealed)后再调用 = 新回合,重置跨轮瞬态后建新卡。"""
        if self._sealed:
            self._reset_round()
        if self._message_id != "":
            return
        if self._inflight is None:

            async def _create_if_needed() -> None:
                # 队列内二次确认:分卡流程可能已在先行任务里建好新卡
                if self._message_id == "":
                    await self._create_card()

            self._inflight = self._enqueue(_create_if_needed)
        await self._inflight

    async def _create_card(self) -> None:
        """直接建卡(仅在串行队列内调用,顺序由队列保证):分卡续卡
        (segment_index>0)的新卡带 segment "last"(当前为序列末卡,若后续
        再切卡,旧卡 _seal_intermediate_card 会 set_segment 覆盖为 middle)。"""
        data: dict[str, Any] = {
            "schema_ver": AGGREGATE_SCHEMA_VER,
            "state": "generating",
            "elements": [],
        }
        if self._segment_index > 0:
            data["segment"] = "last"
        self._message_id = await self._io.send_card({"msg_type": "aggregate_card", "data": data})
        self._card_state = "generating"
        self._current_segment = "last" if self._segment_index > 0 else None

    def _reset_round(self) -> None:
        """跨轮重置:清空上一回合全部瞬态(归属映射/pending/分卡序号/镜像),
        seq 归零后 element_id 复用不受残留干扰。"""
        self._sealed = False
        self._message_id = ""
        self._inflight = None
        self._mirror = []
        self._element_card_ids.clear()
        self._pending_updates.clear()
        self._segment_index = 0
        self._current_segment = None
        self._card_state = "generating"
        self._footer_seq = 0
        self._seq = 0

    def _next_element_id(self, element_type: str) -> str:
        """element_id 协议规则:type_seq 命名(reasoning_1/tool_card_2),字母开头、
        ≤20 字符(超长 type 截断,空 type 兜底 element);显式 id 不消耗 seq。"""
        self._seq += 1
        type_part = element_type[: max(1, 19 - len(str(self._seq)))] or "element"
        return f"{type_part}_{self._seq}"

    async def append(self, element_type: str, data: dict[str, Any]) -> dict[str, str]:
        """追加元素。data 可选携带 element_id:与卡内已有元素同 id 时自动改发
        update(原位替换,server append 无 upsert,直接 append 会出双元素)。
        返回最终 element_id(未携带时自动生成)。"""
        await self._ensure_card()
        # 拆出显式 element_id;调用方按类型约束携带的 type 字段剔除(以第一参数为准)
        explicit_id = data.get("element_id") if isinstance(data.get("element_id"), str) else None
        element_data = {k: v for k, v in data.items() if k not in ("element_id", "type")}
        element_id = explicit_id or self._next_element_id(element_type)
        element = {"type": element_type, "element_id": element_id, "data": element_data}

        async def _job() -> dict[str, str]:
            existed = any(e["element_id"] == element_id for e in self._mirror)
            # 分卡:追加新元素(非原位替换)且当前卡已满 → 先收尾旧卡再建新卡。
            # 切卡在串行队列内,与元素追加同序执行,不会并发开卡。
            if not existed and len(self._mirror) >= MAX_ELEMENTS:
                await self._seal_intermediate_card()
                self._segment_index += 1
            if self._message_id == "":
                await self._create_card()
            # 影子镜像先落地(降级全量替换的副本需含本元素);建卡成功后再入镜像,
            # 避免建卡失败时镜像与卡内容漂移
            self._mirror = (
                [element if e["element_id"] == element_id else e for e in self._mirror]
                if existed
                else [*self._mirror, element]
            )
            # 记录元素归属卡:分卡后旧卡元素 update 仍能定位(仅新 append 记录)
            if not existed:
                self._element_card_ids[element_id] = self._message_id
            await self._try_patch(
                {"op": "update", "element_id": element_id, "data": element["data"]}
                if existed
                else {"op": "append", "element": element}
            )
            # 竞态补发:append 前缓存的 pending update(update 早于元素就绪到达),
            # 合并进元素 data 后补发,避免元素永卡初始态。
            buffered = self._pending_updates.get(element_id)
            if buffered is not None:
                del self._pending_updates[element_id]
                merged = {**element["data"], **buffered}
                self._mirror = [
                    {**e, "data": merged} if e["element_id"] == element_id else e for e in self._mirror
                ]
                await self._try_patch({"op": "update", "element_id": element_id, "data": merged})
            return {"id": element_id}

        return await self._enqueue(_job)

    async def update(self, element_id: str, data: dict[str, Any]) -> None:
        """更新元素 data。当前卡元素:与本地镜像合并后发全量(server update 是
        整体替换而非 merge)。分卡后旧卡元素:经归属映射直接 PATCH 旧卡。
        元素未就绪(尚未 append):缓存待 append 落地后补发(多次 update 字段合并)。
        本方法不建卡(建卡是 append/finish 的职责);sealed 后迟到 update 走
        pending 缓存零 wire 流量,不建孤儿卡。"""

        async def _job() -> None:
            # sealed 后迟到 update(finish/interrupt 已收尾,如用户停止后工具终态):
            # 守卫在队列内读最新态,不触发 ensure_card 的 reset_round/建新卡(防孤儿
            # generating 卡)、不 PATCH 已收尾卡 —— 走 pending 缓存零 wire 流量,
            # 缓存由下一轮 reset_round 清空,不跨轮泄漏。
            if self._sealed:
                self._pending_updates[element_id] = {**(self._pending_updates.get(element_id) or {}), **data}
                return
            target = next((e for e in self._mirror if e["element_id"] == element_id), None)
            if target is not None:
                merged = {**target["data"], **data}
                self._mirror = [
                    {**e, "data": merged} if e["element_id"] == element_id else e for e in self._mirror
                ]
                await self._try_patch({"op": "update", "element_id": element_id, "data": merged})
                return
            # 分卡跨卡定位:归属映射命中旧卡 → 直接 PATCH 旧卡(旧卡无本地镜像,
            # 调用方需传全量 data,与 server 整体替换语义一致)
            owner_card = self._element_card_ids.get(element_id)
            if owner_card is not None and owner_card != self._message_id:
                await self._io.patch(owner_card, {"op": "update", "element_id": element_id, "data": data})
                return
            # 元素未就绪:缓存 pending(合并既有缓存),append 落地后一次补发
            self._pending_updates[element_id] = {**(self._pending_updates.get(element_id) or {}), **data}

        await self._enqueue(_job)

    async def finish(self, footer: dict[str, Any]) -> None:
        """回合收尾:追加 footer(duration_ms 映射 duration,finished=True)
        + set_state done + set_silent false(翻转计未读)。幂等:重复调用跳过。
        recall_empty 开启且无实际内容元素时撤回删卡(需 io.recall,缺省退化为
        无 footer 定格 done 不响铃)。"""
        if self._sealed:
            return
        await self._ensure_card()

        async def _job() -> None:
            # 守卫在队列内读最新态:并发的重复 finish 只收尾一次
            if self._sealed or self._message_id == "":
                return
            if self._recall_empty_card():
                recall = getattr(self._io, "recall", None)
                if recall is not None:
                    await recall(self._message_id)
                else:
                    self._card_state = "done"
                    await self._try_patch({"op": "set_state", "state": "done"})
                self._sealed = True
                return
            footer_data: dict[str, Any] = {k: v for k, v in footer.items() if k != "duration_ms"}
            footer_data["finished"] = True
            if footer.get("duration_ms") is not None:
                footer_data["duration"] = footer["duration_ms"]
            self._footer_seq += 1
            element = {
                "type": "footer",
                "element_id": f"footer_{self._footer_seq}",
                "data": footer_data,
            }
            self._mirror = [*self._mirror, element]
            await self._try_patch({"op": "append", "element": element})
            self._card_state = "done"
            await self._try_patch({"op": "set_state", "state": "done"})
            await self._try_patch({"op": "set_silent", "silent": False})
            self._sealed = True

        await self._enqueue(_job)

    async def interrupt(self) -> None:
        """用户断卡收尾:与 finish 同语义,footer 标记 reason=interrupt(APP 显示回合被打断)。"""
        await self.finish({"reason": "interrupt"})

    async def _try_patch(self, op: dict[str, Any]) -> None:
        """PATCH 失败计数:连续 3 次且 degraded_self_heal(默认开)→ 先经无 op
        全量替换把影子副本整体推 server 收敛(hermes degraded 自愈),append 改写
        为幂等 update(全量已含新元素,防重复)后重试一次;任一 patch 成功即清零计数。"""
        try:
            await self._io.patch(self._message_id, op)
            self._failure_count = 0
        except Exception:
            self._failure_count += 1
            if not (self._opts.get("degraded_self_heal", True) and self._failure_count >= 3):
                raise
            await self._degraded_replace()
            retry = (
                {"op": "update", "element_id": op["element"]["element_id"], "data": op["element"]["data"]}
                if op["op"] == "append"
                else op
            )
            await self._io.patch(self._message_id, retry)
            self._failure_count = 0

    async def _degraded_replace(self) -> None:
        """降级全量替换:当前卡影子副本(elements + state + segment)经
        update_content 整体推 server,收敛增量与全量的差异。envelope 不带
        silent 键,server merge_preserved_silent 会并入原值(显式带 silent
        用新值,会覆写 set_silent 已翻转的响铃,导致自愈清掉未读)。"""
        data: dict[str, Any] = {
            "schema_ver": AGGREGATE_SCHEMA_VER,
            "state": self._card_state,
            "elements": self._mirror,
        }
        if self._current_segment is not None:
            data["segment"] = self._current_segment
        await self._io.update_content(self._message_id, {"msg_type": "aggregate_card", "data": data})

    async def _seal_intermediate_card(self) -> None:
        """中间卡收尾(分卡用):旧卡 set_state done + set_segment(first/middle)
        定格,不写 footer、不翻 silent(中间卡空态),清当前卡累计让下一元素建新卡;
        保留归属映射(旧卡元素 update 仍定位旧卡)。"""
        if self._message_id == "":
            return
        self._current_segment = "first" if self._segment_index == 0 else "middle"
        self._card_state = "done"
        await self._try_patch({"op": "set_state", "state": "done"})
        await self._try_patch({"op": "set_segment", "segment": self._current_segment})
        self._message_id = ""
        self._inflight = None
        self._mirror = []
        self._current_segment = None

    def _recall_empty_card(self) -> bool:
        """空卡判定:recall_empty 开启且本回合从未成功 append 过内容元素。"""
        return bool(self._opts.get("recall_empty", False)) and len(self._element_card_ids) == 0
