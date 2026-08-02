import json

import pytest

from wanling_sdk.client import WanlingClient


class FakeWS:
    def __init__(self):
        self.sent = []
        self.open = True
        self.closed = False

    async def send(self, data):
        self.sent.append(data)

    async def close(self):
        self.closed = True


def json_loads(s: str):
    return json.loads(s)


@pytest.fixture
def client():
    c = WanlingClient("http://localhost:18008", "agent-1", "secret")
    c._ws = FakeWS()
    return c


@pytest.mark.asyncio
async def test_send_typed_payload(client):
    await client.send_typed("c1", "markdown", {"text": "hi"}, silent=True)
    sent = json_loads(client._ws.sent[0])
    assert sent["op"] == 0
    assert sent["t"] == "MESSAGE_CREATE"
    assert sent["d"]["content"] == {"msg_type": "markdown", "data": {"text": "hi"}, "silent": True}


@pytest.mark.asyncio
async def test_send_stream_op14(client):
    await client.send_stream("c1", "s1", "text", "abc")
    sent = json_loads(client._ws.sent[0])
    assert sent["op"] == 14
    assert sent["d"]["conversation_id"] == "c1"


@pytest.mark.asyncio
async def test_message_create_emits_message(client):
    got = []
    client.on("message", got.append)

    async def feed():
        await client._handle_message({"op": 0, "t": "MESSAGE_CREATE", "s": 1, "d": {"conversation_id": "c1"}})

    await feed()
    assert got[0]["conversation_id"] == "c1"
    assert client._last_seq == 1


@pytest.mark.asyncio
async def test_approval_decided_emits_event(client):
    got = []
    client.on("approval.decided", got.append)
    await client._handle_message({"op": 0, "t": "APPROVAL_DECIDED", "s": 2, "d": {"session_key": "k"}})
    assert got[0]["session_key"] == "k"


@pytest.mark.asyncio
async def test_rpc_call_returns_plugin_result(client):
    client.register_method("echo", lambda params: {"echoed": params})
    await client._handle_message({"op": 12, "d": {"jsonrpc": "2.0", "id": "r1", "method": "echo", "params": 1}})
    sent = json_loads(client._ws.sent[0])
    assert sent["op"] == 13
    assert sent["d"]["result"] == {"echoed": 1}


@pytest.mark.asyncio
async def test_report_models(client):
    await client.report_models([{"provider_id": "p", "provider_name": "P", "model_id": "m", "model_name": "M"}])
    sent = json_loads(client._ws.sent[0])
    assert sent["t"] == "AGENT_MODELS"


@pytest.mark.asyncio
async def test_send_not_connected_raises():
    c = WanlingClient("http://localhost:18008", "a", "s")
    with pytest.raises(RuntimeError):
        await c.send("c1", {"msg_type": "text", "data": {"text": "x"}})


class FakeWSErr:
    def __init__(self):
        self.closed = False

    async def recv(self):
        raise ConnectionError("peer closed during hello")

    async def close(self):
        self.closed = True


@pytest.mark.asyncio
async def test_establish_ws_failure_cleans_up_ws(monkeypatch):
    c = WanlingClient("http://localhost:18008", "a", "s")
    fake = FakeWSErr()

    async def fake_exchange():
        return "t"

    async def fake_connect(url):
        return fake

    monkeypatch.setattr(c, "_exchange_token", fake_exchange)
    monkeypatch.setattr("wanling_sdk.client.websockets.connect", fake_connect)
    with pytest.raises(ConnectionError):
        await c._establish_ws()
    assert c._ws is None
    assert fake.closed is True


@pytest.mark.asyncio
async def test_establish_ws_wrong_hello_cleans_up_ws(monkeypatch):
    c = WanlingClient("http://localhost:18008", "a", "s")
    fake = FakeWS()

    async def fake_hello_recv():
        return json.dumps({"op": 999})

    async def fake_exchange():
        return "t"

    async def fake_connect(url):
        return fake

    fake.recv = fake_hello_recv
    monkeypatch.setattr(c, "_exchange_token", fake_exchange)
    monkeypatch.setattr("wanling_sdk.client.websockets.connect", fake_connect)
    with pytest.raises(RuntimeError):
        await c._establish_ws()
    assert c._ws is None
    assert fake.closed is True


@pytest.mark.asyncio
async def test_report_models_not_connected_drops():
    c = WanlingClient("http://localhost:18008", "a", "s")
    await c.report_models([{"provider_id": "p", "provider_name": "P", "model_id": "m", "model_name": "M"}])
    await c.report_slash_catalog([{"name": "n", "template": "t", "source": "command"}])
    await c.report_capabilities([{"name": "echo", "timeout_hint_ms": 5000}])
    assert c._ws is None
