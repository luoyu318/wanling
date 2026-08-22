"""StreamSession 对称测试(与 TS stream_session.test.ts 用例一一对应)。

asyncio 无 vitest 式 fake timer,用小 throttle_ms 真睡 + 充足时间余量验证时序。
"""

import asyncio

import pytest

from wanling_sdk.stream_session import StreamSession


@pytest.mark.asyncio
async def test_first_frame_immediate_then_throttle_then_tail_flush():
    frames = []
    s = StreamSession("c1", lambda _c, f: frames.append(f["text"]), {"throttle_ms": 100, "tail_ms": 100})
    s.push("a")  # 首帧立即
    await asyncio.sleep(0.05)
    s.push("b")  # 节流中 → 挂兜底 timer(100ms 后)
    assert frames == ["a"]
    await asyncio.sleep(0.05)
    assert frames == ["a"]  # 未到节流间隔不 flush
    await asyncio.sleep(0.2)
    assert frames == ["a", "ab"]  # 尾部兜底 flush(累积全量快照,非增量)


@pytest.mark.asyncio
async def test_aggregate_fields_and_default_msg_type():
    frames = []
    s = StreamSession(
        "c1",
        lambda _c, f: frames.append(f),
        {"aggregate": {"message_id": "m1", "element_id": "e1"}},
    )
    s.push("x")
    frame = frames[0]
    assert frame["msg_type"] == "text"
    assert frame["text"] == "x"
    assert frame["aggregate"] == {"message_id": "m1", "element_id": "e1"}
    assert isinstance(frame["stream_id"], str) and frame["stream_id"]


@pytest.mark.asyncio
async def test_end_cancels_timer_and_flushes_tail():
    frames = []
    s = StreamSession("c1", lambda _c, f: frames.append(f["text"]), {"throttle_ms": 100})
    s.push("a")  # 首帧立即
    await asyncio.sleep(0.05)
    s.push("b")  # 节流中,挂兜底 timer
    await s.end("final")  # 关闭:清 timer + 立即 flush 余量(finalText 不走流式通道)
    assert frames == ["a", "ab"]
    s.push("c")  # 已关闭,忽略
    await asyncio.sleep(0.15)
    assert frames == ["a", "ab"]


@pytest.mark.asyncio
async def test_abort_discards_buffer():
    frames = []
    s = StreamSession("c1", lambda _c, f: frames.append(f["text"]), {"throttle_ms": 100})
    s.push("a")  # 首帧立即
    await asyncio.sleep(0.05)
    s.push("b")  # 节流中,挂兜底 timer
    s.abort()  # 丢弃缓冲
    await asyncio.sleep(0.15)
    assert frames == ["a"]
