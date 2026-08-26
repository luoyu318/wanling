"""AggregateCard 对称测试(与 TS aggregate_card.test.ts 用例一一对应)。"""

import pytest

from wanling_sdk.aggregate_card import AggregateCard


class FakeIo:
    """录制的 io 桩:cards/patches/updates/recalled 供断言 wire 序列。"""

    def __init__(self, fail_patch: int = 0) -> None:
        self.card_seq = 0
        self.cards = []  # [{id, data}]
        self.patches = []  # [(card_id, op)]
        self.updates = []  # [(card_id, content)]
        self.recalled = []
        self._patch_calls = 0
        self._fail_patch = fail_patch

    async def send_card(self, data):
        self.card_seq += 1
        mid = f"m{self.card_seq}"
        self.cards.append({"id": mid, "data": data["data"]})
        return mid

    async def patch(self, card_id, op):
        self._patch_calls += 1
        if self._patch_calls <= self._fail_patch:
            raise RuntimeError("patch down")
        self.patches.append((card_id, op))
        return {}

    async def update_content(self, card_id, content):
        self.updates.append((card_id, content))
        return {}

    async def recall(self, message_id):
        self.recalled.append(message_id)


@pytest.mark.asyncio
async def test_append_same_element_id_becomes_update():
    io = FakeIo()
    card = AggregateCard("c1", io)
    r1 = await card.append("tool_card", {"type": "tool_card", "element_id": "t1", "name": "bash"})
    r2 = await card.append("tool_card", {"type": "tool_card", "element_id": "t1", "name": "bash", "status": "done"})
    assert r1 == {"id": "t1"}
    assert r2 == {"id": "t1"}
    # 建卡幂等:两次 append 只建一张卡
    assert len(io.cards) == 1
    # 第一次 append、第二次 update(server append 无 upsert,同 id 原位替换)
    assert io.patches[0][1] == {
        "op": "append",
        "element": {"type": "tool_card", "element_id": "t1", "data": {"name": "bash"}},
    }
    assert io.patches[1][1] == {
        "op": "update",
        "element_id": "t1",
        "data": {"name": "bash", "status": "done"},
    }


@pytest.mark.asyncio
async def test_auto_split_at_20_elements_with_set_segment():
    io = FakeIo()
    card = AggregateCard("c1", io)

    async def push(i: int) -> None:
        await card.append("markdown", {"type": "markdown", "element_id": f"md_{i}", "text": f"t{i}"})

    for i in range(1, 21):
        await push(i)
    # 满 20 不分卡,第 20 个仍在首卡
    assert len(io.cards) == 1
    await push(21)
    # 第 21 个触发分卡:首卡 seal(done + segment first),新卡建卡带 segment last
    assert len(io.cards) == 2
    first_card_ops = [op for card_id, op in io.patches if card_id == "m1"]
    assert {"op": "set_state", "state": "done"} in first_card_ops
    assert {"op": "set_segment", "segment": "first"} in first_card_ops
    assert io.cards[1]["data"]["segment"] == "last"
    assert io.cards[1]["data"]["state"] == "generating"
    assert io.cards[1]["data"]["elements"] == []
    assert io.patches[-1][0] == "m2"
    assert io.patches[-1][1]["op"] == "append"
    assert io.patches[-1][1]["element"]["element_id"] == "md_21"
    # 跨卡 update:旧卡元素(md_1)仍打到旧卡(归属映射命中)
    await card.update("md_1", {"text": "edited"})
    assert io.patches[-1] == (
        "m1",
        {"op": "update", "element_id": "md_1", "data": {"text": "edited"}},
    )
    # 第二次分卡(第 41 个元素):第二张卡 seal 为 middle,第三张卡 last
    for i in range(22, 41):
        await push(i)
    await push(41)
    assert len(io.cards) == 3
    second_card_ops = [op for card_id, op in io.patches if card_id == "m2"]
    assert {"op": "set_segment", "segment": "middle"} in second_card_ops
    assert io.cards[2]["data"]["segment"] == "last"


@pytest.mark.asyncio
async def test_serial_queue_survives_previous_failure():
    io = FakeIo(fail_patch=1)
    card = AggregateCard("c1", io)
    with pytest.raises(RuntimeError, match="patch down"):
        await card.append("markdown", {"type": "markdown", "text": "a"})
    # 队列吞掉前次失败:第二次 append 仍执行且成功
    await card.append("markdown", {"type": "markdown", "text": "b"})
    assert len(io.patches) == 1
    assert io.patches[0][1]["op"] == "append"
    assert io.patches[0][1]["element"]["data"] == {"text": "b"}


@pytest.mark.asyncio
async def test_update_before_append_buffered_and_replayed():
    io = FakeIo()
    card = AggregateCard("c1", io)
    # update 先于 append 到达:元素不在卡上,不 PATCH(避免 server 400),缓存待补
    await card.update("tool_x", {"status": "working"})
    assert len(io.patches) == 0
    await card.append("tool_card", {"type": "tool_card", "element_id": "tool_x", "name": "x"})
    # append 落地后自动补发 update,且与元素初始 data 合并
    assert [op["op"] for _, op in io.patches] == ["append", "update"]
    assert io.patches[1][1] == {"op": "update", "element_id": "tool_x", "data": {"name": "x", "status": "working"}}


@pytest.mark.asyncio
async def test_late_update_after_finish_zero_wire():
    io = FakeIo()
    card = AggregateCard("c1", io)
    await card.append("tool_card", {"type": "tool_card", "element_id": "t1", "name": "bash"})
    await card.finish({"duration_ms": 100})
    # 收尾后工具终态迟到:sealed,不建新卡(resetRound/孤儿 generating 卡)、
    # 不 PATCH 已收尾卡、不触发降级全量替换 —— 对齐 opencode pending 缓存语义
    wire = (len(io.cards), len(io.patches), len(io.updates))
    await card.update("t1", {"status": "done", "output": "ok"})
    assert (len(io.cards), len(io.patches), len(io.updates)) == wire


@pytest.mark.asyncio
async def test_late_update_after_interrupt_zero_wire_and_new_round():
    io = FakeIo()
    card = AggregateCard("c1", io)
    await card.append("tool_card", {"type": "tool_card", "element_id": "t1", "name": "bash"})
    await card.interrupt()
    card_count = len(io.cards)
    patch_count = len(io.patches)
    # 用户停止后工具终态迟到:同 finish 语义,零 wire 流量
    await card.update("t1", {"status": "done"})
    assert len(io.cards) == card_count
    assert len(io.patches) == patch_count
    # 新一轮 append:resetRound 路径未被破坏,正常开新卡
    await card.append("markdown", {"type": "markdown", "element_id": "md_1", "text": "next"})
    assert len(io.cards) == card_count + 1
    assert io.cards[-1]["data"]["state"] == "generating"
    assert io.cards[-1]["data"]["elements"] == []
    # 新一轮 update 打到新卡(resetRound 已清迟到缓存,不跨轮泄漏)
    await card.update("md_1", {"text": "edited"})
    assert io.patches[-1] == (
        f"m{card_count + 1}",
        {"op": "update", "element_id": "md_1", "data": {"text": "edited"}},
    )


@pytest.mark.asyncio
async def test_three_consecutive_failures_degraded_self_heal():
    io = FakeIo(fail_patch=3)
    card = AggregateCard("c1", io)
    with pytest.raises(RuntimeError, match="patch down"):
        await card.append("markdown", {"type": "markdown", "element_id": "m1", "text": "a"})
    with pytest.raises(RuntimeError, match="patch down"):
        await card.append("markdown", {"type": "markdown", "element_id": "m2", "text": "b"})
    # 第三次连续失败触发降级:影子副本全量替换推 server 收敛,append 改写 update 重试成功
    r3 = await card.append("markdown", {"type": "markdown", "element_id": "m3", "text": "c"})
    assert r3 == {"id": "m3"}
    assert len(io.updates) == 1
    card_id, content = io.updates[0]
    assert card_id == "m1"
    assert content["msg_type"] == "aggregate_card"
    assert content["data"]["state"] == "generating"
    assert content["data"]["elements"] == [
        {"type": "markdown", "element_id": "m1", "data": {"text": "a"}},
        {"type": "markdown", "element_id": "m2", "data": {"text": "b"}},
        {"type": "markdown", "element_id": "m3", "data": {"text": "c"}},
    ]
    # 自愈 envelope 不带 silent 键(server merge_preserved_silent 并入原值,防覆写已翻转的响铃)
    assert "silent" not in content
    # 重试的 op 是幂等 update(全量已含新元素,防重复 append)
    assert io.patches[-1] == ("m1", {"op": "update", "element_id": "m3", "data": {"text": "c"}})


@pytest.mark.asyncio
async def test_finish_appends_footer_done_unsilent_idempotent():
    io = FakeIo()
    card = AggregateCard("c1", io)
    await card.append("markdown", {"type": "markdown", "text": "hi"})
    await card.finish({"duration_ms": 1200, "model": "glm"})
    await card.finish({})
    assert [op["op"] for _, op in io.patches] == ["append", "append", "set_state", "set_silent"]
    # duration_ms 映射协议字段 duration;finished 由 finish 语义置 true
    footer_element = io.patches[1][1]["element"]
    assert footer_element["type"] == "footer"
    assert footer_element["data"] == {"model": "glm", "duration": 1200, "finished": True}
    assert io.patches[2][1] == {"op": "set_state", "state": "done"}
    assert io.patches[3][1] == {"op": "set_silent", "silent": False}


@pytest.mark.asyncio
async def test_auto_element_id_type_seq():
    """未携带 element_id 时按 type_seq 生成(协议:字母开头/≤20字符/全卡唯一)。"""
    io = FakeIo()
    card = AggregateCard("c1", io)
    r1 = await card.append("reasoning", {"type": "reasoning", "text": "think"})
    r2 = await card.append("tool_card", {"type": "tool_card", "name": "bash"})
    # 单一全局 seq 跨 type 递增(对齐 plugin aggregateSeq 口径),跨卡不归零保全卡唯一
    assert r1 == {"id": "reasoning_1"}
    assert r2 == {"id": "tool_card_2"}
    assert [op["op"] for _, op in io.patches] == ["append", "append"]
    # 显式 id 不消耗 seq
    await card.append("markdown", {"type": "markdown", "element_id": "custom", "text": "x"})
    r4 = await card.append("markdown", {"type": "markdown", "text": "y"})
    assert r4 == {"id": "markdown_3"}
    # 超 20 字符的长 type 截断兜底
    r5 = await card.append("t" * 30, {"text": "z"})
    assert len(r5["id"]) <= 20
    assert r5["id"][0].isalpha()


@pytest.mark.asyncio
async def test_seq_reset_across_rounds():
    """收尾后新回合 seq 归零复用(对齐 plugin 跨轮瞬态清理)。"""
    io = FakeIo()
    card = AggregateCard("c1", io)
    await card.append("reasoning", {"type": "reasoning", "text": "a"})
    await card.finish({})
    r = await card.append("reasoning", {"type": "reasoning", "text": "b"})
    assert r == {"id": "reasoning_1"}


@pytest.mark.asyncio
async def test_recall_empty_card():
    io = FakeIo()
    card = AggregateCard("c1", io, {"recall_empty": True})
    await card.finish({})
    assert io.recalled == ["m1"]
    assert len(io.patches) == 0
