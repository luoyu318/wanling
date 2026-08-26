"""SessionMapping 对称测试(与 TS session_mapping.test.ts 用例一一对应)。"""

import json
import os

import pytest

from wanling_sdk.session_mapping import SessionMapping


@pytest.mark.asyncio
async def test_atomic_write_and_reload_restores_both_indexes(tmp_path):
    path = tmp_path / "sub" / "mapping.json"  # 子目录不存在 → 递归建目录
    created = []

    async def create_conversation(session_id, opts):
        created.append(session_id)
        return "conv_1"

    m = SessionMapping(str(path), create_conversation)
    # miss 时建会话,返回 convId
    assert await m.ensure_conversation("sess_1", {"title": "T"}) == "conv_1"
    assert created == ["sess_1"]
    # 幂等:已知 session 不再建
    assert await m.ensure_conversation("sess_1", {"title": "T"}) == "conv_1"
    assert created == ["sess_1"]
    # tmp 文件已 rename,无残留
    assert not os.path.exists(f"{path}.tmp")
    # 新实例 load 恢复双索引
    async def should_not_create(session_id, opts):
        raise AssertionError("不应再建")

    m2 = SessionMapping(str(path), should_not_create)
    assert m2.by_session("sess_1") == "conv_1"
    assert m2.by_conversation("conv_1") == "sess_1"
    # remove 后内存 + 落盘同步清除
    m2.remove("sess_1")
    assert m2.by_session("sess_1") is None
    assert m2.by_conversation("conv_1") is None

    async def create2(session_id, opts):
        return "conv_2"

    m3 = SessionMapping(str(path), create2)
    assert m3.by_session("sess_1") is None


@pytest.mark.asyncio
async def test_corrupt_file_backed_up_and_reset(tmp_path):
    path = tmp_path / "mapping.json"
    path.write_text("{not json", encoding="utf-8")

    async def create(session_id, opts):
        return "conv_x"

    m = SessionMapping(str(path), create)
    # load 不抛,索引重置为空
    assert m.by_session("whatever") is None
    backups = [f.name for f in tmp_path.iterdir() if f.name.startswith("mapping.json.corrupt.")]
    assert len(backups) == 1
    # 重置后可正常重建映射
    assert await m.ensure_conversation("s2", {"title": "T2"}) == "conv_x"
    raw = json.loads(path.read_text(encoding="utf-8"))
    assert list(raw["mappings"].keys()) == ["conv_x"]
    assert raw["version"] == 1
