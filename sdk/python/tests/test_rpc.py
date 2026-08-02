import pytest

from wanling_sdk.rpc import RPCDispatcher, RPCError


@pytest.mark.asyncio
async def test_register_and_dispatch():
    d = RPCDispatcher()
    d.register("echo", lambda params: {"echoed": params})
    resp = await d.dispatch({"jsonrpc": "2.0", "id": "1", "method": "echo", "params": {"x": 1}})
    assert resp["result"] == {"echoed": {"x": 1}}


@pytest.mark.asyncio
async def test_method_not_found():
    d = RPCDispatcher()
    resp = await d.dispatch({"jsonrpc": "2.0", "id": "2", "method": "nope"})
    assert resp["error"]["code"] == -32601


@pytest.mark.asyncio
async def test_rpc_error_passthrough():
    d = RPCDispatcher()

    async def boom(params):
        raise RPCError(-32002, "timeout")

    d.register("boom", boom)
    resp = await d.dispatch({"jsonrpc": "2.0", "id": "3", "method": "boom"})
    assert resp["error"] == {"code": -32002, "message": "timeout"}


@pytest.mark.asyncio
async def test_internal_error():
    d = RPCDispatcher()

    async def err(params):
        raise ValueError("boom")

    d.register("err", err)
    resp = await d.dispatch({"jsonrpc": "2.0", "id": "4", "method": "err"})
    assert resp["error"]["code"] == -32603


def test_list_methods_default_timeout():
    d = RPCDispatcher()
    d.register("a", lambda p: None, timeout_hint_ms=3000)
    d.register("b", lambda p: None)
    assert d.list_methods() == [
        {"name": "a", "timeout_hint_ms": 3000},
        {"name": "b", "timeout_hint_ms": 5000},
    ]
