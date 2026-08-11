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
