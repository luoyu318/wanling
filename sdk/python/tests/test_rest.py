import json

import httpx
import pytest
from httpx import AsyncClient, MockTransport

from wanling_sdk.rest import ApiError, WanlingRestClient


def build_client(handler):
    transport = MockTransport(handler)
    client = WanlingRestClient("http://localhost:18008/", lambda: _async_token())
    client._client = AsyncClient(transport=transport)
    return client


async def _async_token():
    return "jwt-token"


def ok_json(data):
    def handler(request):
        return httpx_response(200, {"ok": True, "data": data})

    return handler


def httpx_response(status, payload):
    import httpx

    return httpx.Response(status, json=payload)


@pytest.mark.asyncio
async def test_send_card_message():
    seen = {}

    def handler(request):
        seen["url"] = str(request.url)
        seen["body"] = json.loads(request.content)
        seen["auth"] = request.headers.get("Authorization")
        return httpx_response(200, {"ok": True, "data": {"message_id": "m1"}})

    client = build_client(handler)
    mid = await client.send_card_message("conv-1", "card", {"action": "x"})
    assert mid == "m1"
    assert seen["url"] == "http://localhost:18008/api/conversations/conv-1/messages"
    assert seen["body"] == {"content": {"msg_type": "card", "data": {"action": "x"}, "silent": True}}
    assert seen["auth"] == "Bearer jwt-token"


@pytest.mark.asyncio
async def test_create_group_as_agent():
    def handler(request):
        return httpx_response(200, {"ok": True, "data": {"id": "conv-9"}})

    client = build_client(handler)
    assert await client.create_group_as_agent("u1", "agent_session", "t") == "conv-9"


@pytest.mark.asyncio
async def test_http_error_raises_api_error():
    def handler(request):
        return httpx_response(404, {"ok": False, "error": {"code": "not_found", "message": "x"}})

    client = build_client(handler)
    with pytest.raises(Exception) as exc:
        await client.update_conversation_title("c1", "n")
    assert "404" in str(exc.value)


@pytest.mark.asyncio
async def test_network_error_raises_api_error():
    def handler(request):
        raise httpx.ConnectError("connection refused", request=request)

    client = build_client(handler)
    with pytest.raises(ApiError) as exc:
        await client.update_conversation_title("c1", "n")
    assert exc.value.status == 0
    assert "request failed" in str(exc.value)


@pytest.mark.asyncio
async def test_aclose_releases_client():
    def handler(request):
        return httpx_response(200, {"ok": True, "data": {"id": "conv-9"}})

    client = build_client(handler)
    async with client:
        assert await client.create_group_as_agent("u1", "agent_session", "t") == "conv-9"


@pytest.mark.asyncio
async def test_create_approval():
    seen = {}

    def handler(request):
        seen["url"] = str(request.url)
        seen["body"] = json.loads(request.content)
        return httpx_response(200, {"ok": True, "data": {"approval_id": "appr-1"}})

    client = build_client(handler)
    res = await client.create_approval(
        "conv-1",
        {"card_type": "command", "title": "命令执行审批", "preview": "rm -rf /tmp/x", "session_key": "sk-1", "timeout_sec": 300},
    )
    assert res["approval_id"] == "appr-1"
    assert seen["url"] == "http://localhost:18008/api/conversations/conv-1/approvals"
    assert seen["body"] == {
        "card_type": "command", "title": "命令执行审批", "preview": "rm -rf /tmp/x",
        "session_key": "sk-1", "timeout_sec": 300,
    }


@pytest.mark.asyncio
async def test_create_approval_auto_approved():
    def handler(request):
        return httpx_response(200, {"ok": True, "data": {"state": "approved", "auto_approved": True, "matched_pattern": "rm *"}})

    client = build_client(handler)
    res = await client.create_approval(
        "conv-1",
        {"card_type": "command", "title": "t", "preview": "rm -rf /x", "session_key": "sk-1", "allow_pattern": "rm *"},
    )
    assert res["auto_approved"] is True


@pytest.mark.asyncio
async def test_download_file_returns_content_type():
    def handler(request):
        assert request.headers["Authorization"] == "Bearer jwt-token"
        return httpx.Response(200, content=b"\x89PNG\r\n\x1a\n", headers={"Content-Type": "image/png"})

    client = build_client(handler)
    result = await client.download_file("file-1")
    assert result.buffer == b"\x89PNG\r\n\x1a\n"
    assert result.content_type == "image/png"


@pytest.mark.asyncio
async def test_download_file_without_content_type():
    def handler(request):
        return httpx.Response(200, content=b"raw-bytes")

    client = build_client(handler)
    result = await client.download_file("file-1")
    assert result.buffer == b"raw-bytes"
    assert result.content_type is None


@pytest.mark.asyncio
async def test_download_file_http_error_raises():
    def handler(request):
        return httpx.Response(404, json={"ok": False, "error": {"code": "not_found", "message": "no file"}})

    client = build_client(handler)
    with pytest.raises(ApiError) as exc:
        await client.download_file("file-404")
    assert exc.value.status == 404


@pytest.mark.asyncio
async def test_upload_exceeds_max_bytes():
    import os
    import tempfile

    client = WanlingRestClient("http://localhost:18008/", lambda: _async_token(), max_upload_bytes=1024)
    fd, path = tempfile.mkstemp()
    try:
        with open(path, "wb") as f:  # noqa: ASYNC230 - 一次性临时文件,同步写即可
            f.write(b"x" * (2 * 1024 * 1024))
        with pytest.raises(ApiError) as exc:
            await client.upload_file(path)
        assert "too large" in str(exc.value)
    finally:
        os.close(fd)
        os.unlink(path)


@pytest.mark.asyncio
async def test_upload_default_max_bytes_allows_21mb():
    import os
    import tempfile

    client = WanlingRestClient("http://localhost:18008/", lambda: _async_token())

    def handler(request):
        return httpx_response(200, {"ok": True, "data": {"id": "f1"}})

    client._client = AsyncClient(transport=MockTransport(handler))
    fd, path = tempfile.mkstemp()
    try:
        with open(path, "wb") as f:  # noqa: ASYNC230 - 一次性临时文件,同步写即可
            f.write(b"y" * (21 * 1024 * 1024))  # 21MB(> 旧 20MB 限制)
        assert await client.upload_file(path) == "f1"
    finally:
        os.close(fd)
        os.unlink(path)


@pytest.mark.asyncio
async def test_patch_aggregate_message_append():
    seen = {}

    def handler(request):
        seen["url"] = str(request.url)
        seen["method"] = request.method
        seen["body"] = json.loads(request.content)
        return httpx_response(200, {"ok": True})

    client = build_client(handler)
    await client.patch_aggregate_message(
        "m1",
        {"op": "append", "element": {"type": "markdown", "element_id": "m1", "data": {"text": "hi"}}},
    )
    assert seen["url"] == "http://localhost:18008/api/messages/m1"
    assert seen["method"] == "PATCH"
    assert seen["body"] == {
        "content": {
            "msg_type": "aggregate_card",
            "data": {"op": "append", "element": {"type": "markdown", "element_id": "m1", "data": {"text": "hi"}}},
        }
    }


@pytest.mark.asyncio
async def test_patch_aggregate_message_set_silent():
    seen = {}

    def handler(request):
        seen["body"] = json.loads(request.content)
        return httpx_response(200, {"ok": True})

    client = build_client(handler)
    await client.patch_aggregate_message("m1", {"op": "set_silent", "silent": False})
    assert seen["body"] == {"content": {"msg_type": "aggregate_card", "data": {"op": "set_silent", "silent": False}}}


@pytest.mark.asyncio
async def test_get_approval():
    def handler(request):
        return httpx_response(200, {"ok": True, "data": {"state": "approved", "decided_action": "allow", "decided_answers": ["a"]}})

    client = build_client(handler)
    res = await client.get_approval("appr-1")
    assert res == {"state": "approved", "decided_action": "allow", "decided_answers": ["a"]}


@pytest.mark.asyncio
async def test_envelope_not_ok_raises_api_error():
    def handler(request):
        return httpx_response(200, {"ok": False})

    client = build_client(handler)
    with pytest.raises(ApiError):
        await client.get_approval("appr-1")


@pytest.mark.asyncio
async def test_recall_message():
    seen = {}

    def handler(request):
        seen["method"] = request.method
        seen["url"] = str(request.url)
        return httpx_response(200, {"ok": True})

    client = build_client(handler)
    await client.recall_message("m1")
    assert seen["method"] == "DELETE"
    assert seen["url"] == "http://localhost:18008/api/messages/m1?scope=recall"


@pytest.mark.asyncio
async def test_list_agent_conversations_type_filter():
    seen = {}

    def handler(request):
        seen["url"] = str(request.url)
        return httpx_response(200, {"ok": True, "data": [{"id": "conv-1", "type": "agent_session"}]})

    client = build_client(handler)
    res = await client.list_agent_conversations("agent_session")
    assert res == [{"id": "conv-1", "type": "agent_session"}]
    assert seen["url"] == "http://localhost:18008/api/agents/me/conversations?type=agent_session"


@pytest.mark.asyncio
async def test_list_agent_sessions():
    seen = {}

    def handler(request):
        seen["url"] = str(request.url)
        return httpx_response(200, {"ok": True, "data": [{"id": "conv-2", "type": "agent_session"}]})

    client = build_client(handler)
    res = await client.list_agent_sessions("agent-1")
    assert res == [{"id": "conv-2", "type": "agent_session"}]
    assert seen["url"] == "http://localhost:18008/api/agents/agent-1/sessions"
