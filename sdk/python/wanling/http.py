"""HTTP 封装 — agent 端 REST 接口。

所有方法返回解析后的 JSON dict，异常统一以 RuntimeError 抛出。
"""

from __future__ import annotations

import json
from typing import Any, Optional
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


class _HTTP:
    """内部 HTTP 客户端。仅封装 agent 端可调用的接口。"""

    def __init__(self, base_url: str, token: str):
        self._base = base_url.rstrip("/")
        self._token = token

    # ── helpers ──

    def _req(self, method: str, path: str,
             body: dict[str, Any] | None = None,
             query: dict[str, str] | None = None) -> dict[str, Any]:
        url = self._base + path
        if query:
            params = "&".join(f"{k}={v}" for k, v in query.items())
            url += "?" + params
        headers = {
            "Authorization": f"Bearer {self._token}",
            "Content-Type": "application/json",
        }
        data = json.dumps(body).encode() if body else None
        req = Request(url, data=data, headers=headers, method=method)
        try:
            with urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode())
        except HTTPError as e:
            msg = ""
            try:
                msg = e.read().decode()
            except Exception:
                pass
            raise RuntimeError(f"{method} {path}: HTTP {e.code} {msg}") from e
        except URLError as e:
            raise RuntimeError(f"{method} {path}: 连接失败 {e}") from e

    # ── 会话 ──

    def find_or_create_conv(self, user_id: str) -> dict[str, Any]:
        """POST /api/agents/me/conversations"""
        return self._req("POST", "/api/agents/me/conversations",
                         {"user_id": user_id})

    # ── 审批 ──

    def create_approval(self, conv_id: str, payload: dict[str, Any]) -> dict[str, Any]:
        """POST /api/conversations/:id/approvals"""
        return self._req("POST", f"/api/conversations/{conv_id}/approvals", payload)

    def get_approval(self, approval_id: str) -> dict[str, Any]:
        """GET /api/approvals/:id"""
        return self._req("GET", f"/api/approvals/{approval_id}")

    # ── 文件 ──

    def upload_file(self, file_path: str) -> dict[str, Any]:
        """POST /api/upload (multipart)。返回 {id, filename}。"""
        raise NotImplementedError("upload_file 需要用 httpx 支持 multipart，预留")

    def download_file(self, file_id: str, save_path: str,
                      thumb: bool = False) -> None:
        """GET /api/files/:id → 写入 save_path。"""
        raise NotImplementedError("download_file 需要用 httpx 支持流式，预留")

    # ── 消息删除 ──

    def delete_message(self, msg_id: str) -> None:
        """DELETE /api/messages/:id → 204 No Content。"""
        url = self._base + f"/api/messages/{msg_id}"
        headers = {"Authorization": f"Bearer {self._token}"}
        req = Request(url, headers=headers, method="DELETE")
        try:
            with urlopen(req, timeout=10) as resp:
                if resp.status != 204:
                    raise RuntimeError(f"DELETE 预期 204，实际 {resp.status}")
        except HTTPError as e:
            raise RuntimeError(f"DELETE /api/messages/{msg_id}: HTTP {e.code}") from e

    def batch_delete(self, ids: list[str]) -> dict[str, Any]:
        """POST /api/messages/batch-delete → {deleted: N}。"""
        return self._req("POST", "/api/messages/batch-delete", {"ids": ids})
