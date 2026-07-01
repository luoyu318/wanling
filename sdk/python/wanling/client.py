"""WanlingAgentClient — agent 端唯一入口，组合 HTTP + WS 双通道。"""

from __future__ import annotations

import os
from typing import Any

from wanling.auth import agent_token
from wanling.http import _HTTP
from wanling.ws import WanlingWS, DispatchCallback


class WanlingAgentClient:
    """以 agent 身份连接万灵服务端。

    HTTP 用于会话/审批/文件操作，WS 用于收发消息 + 实时事件。

    用法:
        client = WanlingAgentClient("ag_xxx", "sk_xxx", "http://localhost:18008")
        await client.connect()

        conv = client.find_or_create_conv("u_xxx")
        msg_id, _ = client.send_message(conv["id"], "hello")
        await client.close()
    """

    def __init__(self, agent_id: str, secret_key: str,
                 base_url: str = "http://localhost:18008"):
        self.agent_id = agent_id
        self.base_url = base_url.rstrip("/")

        # 换 JWT
        t = agent_token(agent_id, secret_key, base_url)
        self._token = t.token

        # 内部组件
        self.http = _HTTP(base_url, self._token)
        self.ws = WanlingWS(base_url, self._token)

    @classmethod
    def from_env(cls) -> WanlingAgentClient:
        """从环境变量读取凭证。WANLING_AGENT_ID / WANLING_SECRET_KEY / WANLING_SERVER。"""
        agent_id = os.environ.get("WANLING_AGENT_ID", "")
        secret_key = os.environ.get("WANLING_SECRET_KEY", "")
        base_url = os.environ.get("WANLING_SERVER", "http://localhost:18008")
        if not agent_id or not secret_key:
            raise RuntimeError(
                "缺少凭证: 请设置 WANLING_AGENT_ID 和 WANLING_SECRET_KEY 环境变量"
            )
        return cls(agent_id, secret_key, base_url)

    # ── 连接 ──

    async def connect(self) -> None:
        """WS 连接 + 握手。"""
        await self.ws.connect()

    async def close(self) -> None:
        await self.ws.close()

    @property
    def on_dispatch(self) -> DispatchCallback | None:
        return self.ws.on_dispatch

    @on_dispatch.setter
    def on_dispatch(self, cb: DispatchCallback | None) -> None:
        self.ws.on_dispatch = cb

    # ── 会话 ──

    def find_or_create_conv(self, user_id: str) -> dict[str, Any]:
        return self.http.find_or_create_conv(user_id)

    # ── 消息 ──

    async def send_message(self, user_id: str, text: str,
                           msg_type: str = "text") -> None:
        """通过 WS 发文本消息给指定 user。"""
        await self.ws.send_message(user_id, text)

    # ── 审批 ──

    def create_approval(self, conv_id: str,
                        card_type: str,
                        title: str,
                        preview: str = "",
                        session_key: str = "",
                        **kwargs) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "card_type": card_type,
            "title": title,
            "preview": preview,
            "session_key": session_key,
        }
        payload.update(kwargs)
        return self.http.create_approval(conv_id, payload)

    def get_approval(self, approval_id: str) -> dict[str, Any]:
        return self.http.get_approval(approval_id)

    # ── 文件 ──

    def upload_file(self, file_path: str) -> dict[str, Any]:
        return self.http.upload_file(file_path)

    def download_file(self, file_id: str, save_path: str,
                      thumb: bool = False) -> None:
        self.http.download_file(file_id, save_path, thumb)

    # ── 消息删除 ──

    def delete_message(self, msg_id: str) -> None:
        self.http.delete_message(msg_id)

    def batch_delete(self, ids: list[str]) -> dict[str, Any]:
        return self.http.batch_delete(ids)
