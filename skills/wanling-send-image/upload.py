#!/usr/bin/env python3
"""上传本地文件到万灵 server，返回 file_id 和可直接用于回复的 markdown 图片引用。

用法:
  python3 wanling_upload.py <local_path> [conversation_id]

流程:
  1. 按探测顺序读取凭据 config.json（serverUrl/agentId/secretKey）:
     WANLING_CONFIG_FILE → WANLING_CONFIG_DIR → ~/.config/opencode-wanling → ~/.config/wanling-skills
  2. POST /api/agents/:id/token 换 agent JWT
  3. POST /api/upload?conversation_id=... 上传（multipart 字段名 file）拿 file_id

输出: 末行打印 `![alt](/api/files/{file_id})`，前面的输出是日志。
"""
import json
import mimetypes
import os
import re
import sys
import urllib.error
import urllib.request

MAX_SIZE = 20 * 1024 * 1024
SAFE_EXTS = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp"}


def _redact(v):
    return "<redacted>" if v else ""


def config_candidates():
    """凭据探测顺序(与 install.sh 装后检测同序):第一个存在的文件生效。
    WANLING_CONFIG_FILE 显式指定(唯一候选,不存在即报错) → 否则依次:
    WANLING_CONFIG_DIR → opencode 插件配置(存在则用) → 技能 setup 配置(存在则用)。
    注:文件探测之前,load_config 还有一层进程级 env 三元组(hermes 宿主身份)。"""
    if os.environ.get("WANLING_CONFIG_FILE"):
        return [os.environ["WANLING_CONFIG_FILE"]]
    candidates = []
    if os.environ.get("WANLING_CONFIG_DIR"):
        candidates.append(os.path.join(os.environ["WANLING_CONFIG_DIR"], "config.json"))
    candidates.append(os.path.expanduser("~/.config/opencode-wanling/config.json"))
    candidates.append(os.path.expanduser("~/.config/wanling-skills/config.json"))
    return candidates


def load_config():
    # 0) 进程级三元组（hermes 等宿主 agent 的 env 注入,工具子进程天然继承）：
    #    宿主内跑技能 = 宿主身份（主密钥），每个 agent 独立,不共享 fallback。
    env_server = os.environ.get("WANLING_SERVER_URL")
    env_agent = os.environ.get("WANLING_AGENT_ID")
    env_secret = os.environ.get("WANLING_SECRET_KEY")
    if env_server and env_agent and env_secret:
        print(f"[wanling-upload] server: {env_server} (env: 宿主 agent 身份)")
        return env_server, env_agent, env_secret
    if env_server or env_agent or env_secret:
        # 部分设置会跨 server 混用身份（如 env 的密钥发给文件里的另一台 server）,拒绝
        sys.exit("[wanling-upload] 宿主 env 三元组不完整: WANLING_SERVER_URL/WANLING_AGENT_ID/"
                 "WANLING_SECRET_KEY 需同时设置或同时不设")
    candidates = config_candidates()
    cfg_file = next((p for p in candidates if os.path.isfile(p)), "")
    if not cfg_file:
        sys.exit(
            "[wanling-upload] 未找到凭据配置,已探测:\n  " + "\n  ".join(candidates)
            + "\n  （或宿主进程 env 三元组 WANLING_SERVER_URL/WANLING_AGENT_ID/WANLING_SECRET_KEY）"
            + "\n[wanling-upload] 运行 skills/install.sh --setup 用 APP 扫码完成授权"
        )
    with open(cfg_file, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    server_url = cfg.get("serverUrl") or "http://localhost:18008"
    agent_id = cfg.get("agentId") or ""
    secret_key = cfg.get("secretKey") or ""
    if not agent_id or not secret_key:
        sys.exit("[wanling-upload] config.json 缺少 agentId/secretKey")
    # 可视性:打印生效 server 与 config 来源(不含密钥),多实例时便于发现打错目标
    print(f"[wanling-upload] server: {server_url} (config: {cfg_file})")
    return server_url, agent_id, secret_key


def request_json(req, timeout=30):
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        try:
            err = json.loads(e.read()).get("error", {})
        except Exception:
            err = {}
        sys.exit(f"[wanling-upload] HTTP {e.code}: code={err.get('code')} message={err.get('message')}")
    if not isinstance(payload, dict) or not payload.get("ok"):
        err = (payload or {}).get("error") or {}
        sys.exit(f"[wanling-upload] 请求失败: code={err.get('code')} message={err.get('message')}")
    return payload.get("data")


def exchange_token(server_url, agent_id, secret_key):
    req = urllib.request.Request(
        f"{server_url.rstrip('/')}/api/agents/{agent_id}/token",
        data=json.dumps({"agent_id": agent_id, "secret_key": secret_key}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    data = request_json(req, timeout=10)
    if not isinstance(data, dict) or not data.get("token"):
        sys.exit("[wanling-upload] 换 agent token 失败")
    return data["token"]


def upload(server_url, token, local_path, conv_id=None):
    size = os.path.getsize(local_path)
    if size > MAX_SIZE:
        sys.exit(f"[wanling-upload] 文件过大: {size} > {MAX_SIZE}")
    filename = os.path.basename(local_path)
    ext = os.path.splitext(filename)[1].lower()
    if ext not in SAFE_EXTS:
        sys.exit(f"[wanling-upload] 不支持的类型 {ext}，仅支持图片: {sorted(SAFE_EXTS)}")
    mime = mimetypes.guess_type(filename)[0] or "application/octet-stream"

    with open(local_path, "rb") as f:
        file_bytes = f.read()

    boundary = "----WanlingUpload" + os.urandom(8).hex()
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
        f"Content-Type: {mime}\r\n\r\n"
    ).encode() + file_bytes + f"\r\n--{boundary}--\r\n".encode()

    url = f"{server_url.rstrip('/')}/api/upload"
    if conv_id:
        url += f"?conversation_id={conv_id}"
    req = urllib.request.Request(
        url,
        data=body,
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Authorization": f"Bearer {token}",
        },
        method="POST",
    )
    data = request_json(req, timeout=30)
    if not isinstance(data, dict) or not data.get("id"):
        sys.exit("[wanling-upload] 上传响应缺少 file_id")
    return data["id"]


def check_download(server_url, token, file_id):
    req = urllib.request.Request(
        f"{server_url.rstrip('/')}/api/files/{file_id}",
        headers={"Authorization": f"Bearer {token}"},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read()
    except urllib.error.HTTPError as e:
        print(f"[wanling-upload] check failed: HTTP {e.code}")
        return False
    ctype = resp.headers.get("Content-Type", "")
    ok = 200 <= resp.status < 300 and ctype.startswith("image/")
    print(f"[wanling-upload] check status={resp.status} ctype={ctype} bytes={len(body)}")
    return ok


def send_image_message(server_url, token, conv_id, file_id):
    """POST /api/conversations/:id/messages 建独立 image 消息（agentAuth SendAsAgent）。

    等价于 WS MESSAGE_CREATE(msg_type=image)，APP 端渲染为独立图片消息（可点击放大），
    与聚合卡内嵌的 markdown 引用是不同的展示形态。
    """
    body = json.dumps({
        "content": {"msg_type": "image", "data": {"file_id": file_id}},
    }).encode()
    req = urllib.request.Request(
        f"{server_url.rstrip('/')}/api/conversations/{conv_id}/messages",
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
        },
        method="POST",
    )
    data = request_json(req, timeout=15)
    if not isinstance(data, dict) or not data.get("message_id"):
        sys.exit("[wanling-upload] 发独立 image 消息失败: 响应缺 message_id")
    return data["message_id"]


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--check":
        file_id = sys.argv[2]
        server_url, agent_id, secret_key = load_config()
        token = exchange_token(server_url, agent_id, secret_key)
        sys.exit(0 if check_download(server_url, token, file_id) else 1)
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    local_path = sys.argv[1]
    conv_id = sys.argv[2] if len(sys.argv) > 2 else ""
    if not os.path.isfile(local_path):
        sys.exit(f"[wanling-upload] 文件不存在: {local_path}")

    server_url, agent_id, secret_key = load_config()
    print(f"[wanling-upload] server={server_url} agent={agent_id} conv={conv_id or '(owner 兜底)'}")
    token = exchange_token(server_url, agent_id, secret_key)
    file_id = upload(server_url, token, local_path, conv_id)
    print(f"[wanling-upload] file_id={file_id}")
    if conv_id:
        msg_id = send_image_message(server_url, token, conv_id, file_id)
        print(f"[wanling-upload] 已发独立 image 消息 message_id={msg_id}")
    print(f"![image](/api/files/{file_id})")


if __name__ == "__main__":
    main()