"""JWT 换取 —— agent_id + secret_key → Bearer token。"""

from __future__ import annotations

import json
from dataclasses import dataclass
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


@dataclass
class AgentToken:
    token: str


def agent_token(agent_id: str, secret_key: str,
                base_url: str = "http://localhost:18008",
                timeout: int = 10) -> AgentToken:
    """用 agent_id + secret_key 换取 JWT。

    Raises:
        RuntimeError: HTTP 错误、连接失败或响应缺 token 字段。
    """
    url = f"{base_url.rstrip('/')}/api/agents/{agent_id}/token"
    body = json.dumps({"agent_id": agent_id, "secret_key": secret_key}).encode()
    req = Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")

    try:
        with urlopen(req, timeout=timeout) as resp:
            data = json.loads(resp.read().decode())
    except HTTPError as e:
        body_text = ""
        try:
            body_text = e.read().decode()
        except Exception:
            pass
        raise RuntimeError(f"换 token 失败: HTTP {e.code} {e.reason} {body_text}") from e
    except URLError as e:
        raise RuntimeError(f"连接服务器失败: {e}") from e

    token = data.get("token")
    if not token:
        raise RuntimeError(f"换 token 响应缺字段: {data}")
    return AgentToken(token=token)
