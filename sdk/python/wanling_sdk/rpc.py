"""JSON-RPC 2.0 分发层,与 TS sdk/src/rpc.ts 语义对齐。"""

from __future__ import annotations

import inspect
from collections.abc import Callable
from typing import Any

ERR_METHOD_NOT_FOUND = -32601
ERR_INTERNAL = -32603
DEFAULT_TIMEOUT_HINT_MS = 5000


class RPCError(Exception):
    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


Handler = Callable[[Any], Any]


class RPCDispatcher:
    def __init__(self) -> None:
        self._handlers: dict[str, dict[str, Any]] = {}

    def register(
        self,
        name: str,
        handler: Handler,
        timeout_hint_ms: int = DEFAULT_TIMEOUT_HINT_MS,
    ) -> None:
        self._handlers[name] = {"handler": handler, "timeout_hint_ms": timeout_hint_ms}

    def methods(self) -> list[str]:
        return list(self._handlers.keys())

    def list_methods(self) -> list[dict[str, Any]]:
        return [
            {"name": name, "timeout_hint_ms": defn["timeout_hint_ms"]}
            for name, defn in self._handlers.items()
        ]

    async def dispatch(self, call: dict[str, Any]) -> dict[str, Any]:
        req_id = call.get("id")
        method = call.get("method")
        defn = self._handlers.get(method)
        if defn is None:
            return {
                "jsonrpc": "2.0", "id": req_id,
                "error": {"code": ERR_METHOD_NOT_FOUND, "message": f"method not found: {method}"},
            }
        try:
            result = defn["handler"](call.get("params"))
            if inspect.isawaitable(result):
                result = await result
            return {"jsonrpc": "2.0", "id": req_id, "result": result}
        except RPCError as e:
            return {"jsonrpc": "2.0", "id": req_id, "error": {"code": e.code, "message": e.message}}
        except Exception as e:  # noqa: BLE001 - 统一转 JSON-RPC error
            return {"jsonrpc": "2.0", "id": req_id, "error": {"code": ERR_INTERNAL, "message": str(e)}}
