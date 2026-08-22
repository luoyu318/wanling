"""REST 客户端:agent 视角会话/消息/文件/审批方法,与 TS rest.ts 对齐。"""

from __future__ import annotations

import os
from collections.abc import Awaitable, Callable
from typing import Any, Self
from urllib.parse import quote

import httpx


class ApiError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status


TokenProvider = Callable[[], Awaitable[str]]


class WanlingRestClient:
    def __init__(
        self,
        server_url: str,
        token_provider: TokenProvider,
        max_upload_bytes: int = 32 * 1024 * 1024,
    ) -> None:
        self._base_url = server_url.rstrip("/")
        self._token_provider = token_provider
        # 上传上限默认对齐 server UPLOAD_MAX_BYTES(32MB),可由调用方收紧/放宽。
        self._max_upload_bytes = max_upload_bytes
        self._client = httpx.AsyncClient()

    async def aclose(self) -> None:
        await self._client.aclose()

    async def __aenter__(self) -> Self:
        return self

    async def __aexit__(self, *exc: object) -> None:
        await self.aclose()

    def _envelope_ok(self, resp: dict[str, Any]) -> None:
        """envelope 校验(ok 必须为 true,对齐 docs/ai-handbook/rest-response.md)。"""
        if not resp.get("ok"):
            raise ApiError(0, "envelope not ok")

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
        """发一条卡片消息(HTTP 通道,agent 视角)。

        注意:silent 默认 True,静默、不计未读、不弹通知,适合工具卡/过程消息。
        发普通文本回复请改用 client.send_typed(WS,默认非 silent)或本方法显式
        silent=False,否则 APP 端不响铃也不计未读。
        对齐 server POST /api/conversations/:id/messages(SendAsAgent)。
        """
        content = {"msg_type": msg_type, "data": data, "silent": silent}
        resp = await self.request("POST", f"/api/conversations/{conv_id}/messages", {"content": content})
        message_id = resp.get("data", {}).get("message_id")
        if not message_id:
            raise ApiError(0, "send_card_message: missing message_id")
        return message_id

    async def create_approval(self, conv_id: str, body: dict) -> dict[str, Any]:
        """发起审批卡(approvals 状态机通道,含 allow_pattern 会话白名单)。

        对齐 server POST /api/conversations/:id/approvals(CreateApproval):
        - card_type 仅 command/tool/file/slash_confirm,slash_confirm 必带 confirm_id
        - allow_pattern 仅 command 生效,命中白名单服务端返 auto_approved=true(不再发卡)
        响应 data 正常含 approval_id;白名单命中含 state/auto_approved/matched_pattern。
        """
        resp = await self.request("POST", f"/api/conversations/{conv_id}/approvals", body)
        return resp.get("data", {}) or {}

    async def update_message_content(self, msg_id: str, content: dict) -> None:
        await self.request("PATCH", f"/api/messages/{msg_id}", {"content": content})

    async def patch_aggregate_message(self, msg_id: str, op: dict) -> None:
        """聚合卡增量 PATCH(data.op 走 server applyContentOp 增量合并)。

        对齐 docs/ai-handbook/aggregate-card.md 增量协议:
        - append/update/remove/reorder 维护 elements
        - set_state / set_segment / set_silent 改卡状态与 silent(翻转 false 触发未读+通知)
        与 update_message_content(全量替换)互补,聚合卡流式增量用本方法。
        """
        content = {"msg_type": "aggregate_card", "data": op}
        await self.request("PATCH", f"/api/messages/{msg_id}", {"content": content})

    async def recall_message(self, msg_id: str) -> None:
        """撤回自己发的消息(scope=recall:全局软删,双向不可见;server 限 5 分钟内)。

        聚合卡空卡清理(aggregate_card recall_empty)用,对齐 server
        DELETE /api/messages/:id?scope=recall。
        """
        resp = await self.request("DELETE", f"/api/messages/{msg_id}?scope=recall")
        self._envelope_ok(resp)

    async def get_approval(self, approval_id: str) -> dict[str, Any]:
        """查审批详情(GET /api/approvals/:id,双角色鉴权)。

        agent 断线重连错过 APPROVAL_DECIDED/EXPIRED 推送时主动查
        (Approvals.resync 用)。question 决议含 decided_answers(option id
        列表),其余类型该字段缺省。
        """
        resp = await self.request("GET", f"/api/approvals/{approval_id}")
        self._envelope_ok(resp)
        return resp.get("data") or {}

    async def list_agent_conversations(self, conv_type: str | None = None) -> list[dict[str, Any]]:
        """agent 视角列自己的会话(GET /api/agents/me/conversations,agentAuth)。

        envelope data 直接是数组(server ListAsAgent 返 []model.Conversation)。
        type 可选过滤(如 "agent_session",SessionMapping 恢复映射用)。
        """
        query = f"?type={quote(conv_type, safe='')}" if conv_type else ""
        resp = await self.request("GET", f"/api/agents/me/conversations{query}")
        self._envelope_ok(resp)
        data = resp.get("data")
        return data if isinstance(data, list) else []

    async def list_agent_sessions(self, agent_id: str) -> list[dict[str, Any]]:
        """列某 agent 的 agent_session 会话(GET /api/agents/:id/sessions)。

        envelope data 直接是数组(server ListAgentSessions 返
        []ConversationListItem,主键是会话 id,无独立 session_id 字段)。
        注意:server 该路由当前挂 userAuth(仅 user JWT 可调);agent 侧对账
        请用 list_agent_conversations("agent_session")。
        """
        resp = await self.request("GET", f"/api/agents/{agent_id}/sessions")
        self._envelope_ok(resp)
        data = resp.get("data")
        return data if isinstance(data, list) else []

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
        if size > self._max_upload_bytes:
            raise ApiError(0, f"upload_file: {file_path} too large ({size} bytes > {self._max_upload_bytes})")
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
