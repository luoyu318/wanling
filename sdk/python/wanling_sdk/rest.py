"""REST 客户端:agent 视角会话/消息/文件/审批方法,与 TS rest.ts 对齐。"""

from __future__ import annotations

import os
from collections.abc import Awaitable, Callable
from typing import Any, Self

import httpx


class ApiError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status


TokenProvider = Callable[[], Awaitable[str]]


class WanlingRestClient:
    def __init__(self, server_url: str, token_provider: TokenProvider) -> None:
        self._base_url = server_url.rstrip("/")
        self._token_provider = token_provider
        self._client = httpx.AsyncClient()

    async def aclose(self) -> None:
        await self._client.aclose()

    async def __aenter__(self) -> Self:
        return self

    async def __aexit__(self, *exc: object) -> None:
        await self.aclose()

    async def _headers(self) -> dict[str, str]:
        token = await self._token_provider()
        return {"Authorization": f"Bearer {token}"}

    async def request(
        self,
        method: str,
        path: str,
        body: dict | None = None,
        timeout: float = 10.0,
    ) -> dict[str, Any]:
        try:
            resp = await self._client.request(
                method,
                f"{self._base_url}{path}",
                json=body,
                headers=await self._headers(),
                timeout=timeout,
            )
        except httpx.HTTPError as e:
            raise ApiError(0, f"request failed: {e}") from e
        if not 200 <= resp.status_code < 300:
            raise ApiError(resp.status_code, f"HTTP {resp.status_code}")
        return resp.json()

    async def send_card_message(
        self,
        conv_id: str,
        msg_type: str,
        data: dict,
        silent: bool = True,
    ) -> str:
        content = {"msg_type": msg_type, "data": data, "silent": silent}
        resp = await self.request("POST", f"/api/conversations/{conv_id}/messages", {"content": content})
        message_id = resp.get("data", {}).get("message_id")
        if not message_id:
            raise ApiError(0, "send_card_message: missing message_id")
        return message_id

    async def update_message_content(self, msg_id: str, content: dict) -> None:
        await self.request("PATCH", f"/api/messages/{msg_id}", {"content": content})

    async def create_group_as_agent(
        self,
        user_id: str,
        type: str,
        title: str,
        directory: str | None = None,
    ) -> str:
        body: dict[str, Any] = {"user_id": user_id, "type": type, "title": title}
        if directory:
            body["directory"] = directory
        resp = await self.request("POST", "/api/agents/me/conversations", body)
        conv_id = resp.get("data", {}).get("id")
        if not conv_id:
            raise ApiError(0, "create_group_as_agent: missing id")
        return conv_id

    async def update_conversation_title(self, conv_id: str, title: str) -> None:
        await self.request("PATCH", f"/api/agents/me/conversations/{conv_id}/title", {"title": title})

    async def update_session_meta(self, conv_id: str, meta: dict) -> None:
        await self.request("PATCH", f"/api/agents/me/conversations/{conv_id}/session-meta", meta)

    async def upload_file(self, file_path: str, conv_id: str | None = None) -> str:
        size = os.path.getsize(file_path)
        if size > 20 * 1024 * 1024:
            raise ApiError(0, f"upload_file: {file_path} too large ({size} bytes > 20MB)")
        token = await self._token_provider()
        params = {"conversation_id": conv_id} if conv_id else {}
        try:
            with open(file_path, "rb") as f:  # noqa: ASYNC230 - 本地文件上传,一次性读取
                resp = await self._client.post(
                    f"{self._base_url}/api/upload",
                    files={"file": (os.path.basename(file_path), f)},
                    params=params,
                    headers={"Authorization": f"Bearer {token}"},
                    timeout=60.0,
                )
        except httpx.HTTPError as e:
            raise ApiError(0, f"request failed: {e}") from e
        if resp.status_code != 200:
            raise ApiError(resp.status_code, f"upload failed: HTTP {resp.status_code}")
        data = resp.json()
        file_id = data.get("data", {}).get("id")
        if not file_id:
            raise ApiError(0, "upload: missing id")
        return file_id

    async def download_file(self, file_id: str) -> bytes:
        try:
            resp = await self._client.get(
                f"{self._base_url}/api/files/{file_id}",
                headers=await self._headers(),
                timeout=60.0,
            )
        except httpx.HTTPError as e:
            raise ApiError(0, f"request failed: {e}") from e
        if resp.status_code != 200:
            raise ApiError(resp.status_code, f"download failed: HTTP {resp.status_code}")
        return resp.content
