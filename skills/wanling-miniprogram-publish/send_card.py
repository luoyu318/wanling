#!/usr/bin/env python3
"""按 appid 把小程序卡片发到万灵会话(独立 mini_program_card 消息)。

用法:
  python3 send_card.py <appid> [conversation_id]
  python3 send_card.py --dry-run <appid>    # 只查询不发,显示将发的卡片数据

流程:
  1. 凭据探测顺序与 upload.py 一致:
     env 三元组 → WANLING_CONFIG_FILE → WANLING_CONFIG_DIR → ~/.config/opencode-wanling → ~/.config/wanling-skills
  2. POST /api/agents/:id/token 换 agent JWT
  3. GET /api/mini-programs 按 appid 查 name/icon
  4. POST /api/conversations/:id/messages 发 mini_program_card

conv_id 省略时从 session-maps.json 取 lastSyncAt 最新的 wanlingConvId
(多会话并发时不可靠,优先用 wanling_send_miniprogram_card tool)。
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request

APPID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{2,31}$")


def config_candidates():
    """凭据探测顺序(与 upload.py 同序):第一个存在的文件生效。
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
    """返回 (server_url, agent_id, secret_key, cfg_dir)。
    cfg_dir 为生效配置所在目录,session-maps.json 从同目录定位(与所属套一致)。"""
    env_server = os.environ.get("WANLING_SERVER_URL")
    env_agent = os.environ.get("WANLING_AGENT_ID")
    env_secret = os.environ.get("WANLING_SECRET_KEY")
    if env_server and env_agent and env_secret:
        print(f"[wanling-send-card] server: {env_server} (env: 宿主 agent 身份)")
        cfg_dir = os.environ.get("WANLING_CONFIG_DIR") or os.path.expanduser("~/.config/opencode-wanling")
        return env_server, env_agent, env_secret, cfg_dir
    if env_server or env_agent or env_secret:
        sys.exit("[wanling-send-card] 宿主 env 三元组不完整: WANLING_SERVER_URL/WANLING_AGENT_ID/"
                 "WANLING_SECRET_KEY 需同时设置或同时不设")
    candidates = config_candidates()
    cfg_file = next((p for p in candidates if os.path.isfile(p)), "")
    if not cfg_file:
        sys.exit(
            "[wanling-send-card] 未找到凭据配置,已探测:\n  " + "\n  ".join(candidates)
            + "\n  （或宿主进程 env 三元组 WANLING_SERVER_URL/WANLING_AGENT_ID/WANLING_SECRET_KEY）"
            + "\n[wanling-send-card] 运行 skills/install.sh --setup 用 APP 扫码完成授权"
        )
    with open(cfg_file, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    server_url = cfg.get("serverUrl") or "http://localhost:18008"
    agent_id = cfg.get("agentId") or ""
    secret_key = cfg.get("secretKey") or ""
    if not agent_id or not secret_key:
        sys.exit("[wanling-send-card] config.json 缺少 agentId/secretKey")
    print(f"[wanling-send-card] server: {server_url} (config: {cfg_file})")
    return server_url, agent_id, secret_key, os.path.dirname(cfg_file)


def request_json(req, timeout=30):
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        try:
            err = json.loads(e.read()).get("error", {})
        except Exception:
            err = {}
        sys.exit(f"[wanling-send-card] HTTP {e.code}: code={err.get('code')} message={err.get('message')}")
    if not isinstance(payload, dict) or not payload.get("ok"):
        err = (payload or {}).get("error") or {}
        sys.exit(f"[wanling-send-card] 请求失败: code={err.get('code')} message={err.get('message')}")
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
        sys.exit("[wanling-send-card] 换 agent token 失败")
    return data["token"]


def find_mini_program(server_url, token, appid):
    """GET /api/mini-programs 按 appid 过滤;查不到不区分不存在/无权限(防泄露)。"""
    req = urllib.request.Request(
        f"{server_url.rstrip('/')}/api/mini-programs",
        headers={"Authorization": f"Bearer {token}"},
        method="GET",
    )
    data = request_json(req, timeout=15)
    for it in data or []:
        if isinstance(it, dict) and it.get("appid") == appid:
            return it
    sys.exit(f"[wanling-send-card] 未找到或不可见: {appid}")


def send_card_message(server_url, token, conv_id, appid, title, icon):
    """POST /api/conversations/:id/messages 发独立 mini_program_card 消息。

    icon 空则不带(APP 端 fallback 通用图标色块,与小程序内分享行为一致)。
    """
    card_data = {"appid": appid, "title": title}
    if icon:
        card_data["icon"] = icon
    body = json.dumps({
        "content": {"msg_type": "mini_program_card", "data": card_data},
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
        sys.exit("[wanling-send-card] 发卡失败: 响应缺 message_id")
    return data["message_id"]


def lookup_conv_from_session_maps(cfg_dir):
    """从 session-maps.json 取 lastSyncAt 最新的 wanlingConvId(多会话并发不可靠)。"""
    f = os.path.join(cfg_dir, "session-maps.json")
    if not os.path.isfile(f):
        return ""
    try:
        with open(f, "r", encoding="utf-8") as fh:
            maps = json.load(fh).get("maps") or []
    except (OSError, ValueError):
        return ""
    best, best_ts = "", ""
    for m in maps:
        if not isinstance(m, dict) or not m.get("wanlingConvId"):
            continue
        ts = m.get("lastSyncAt") or ""
        if ts >= best_ts:
            best, best_ts = m["wanlingConvId"], ts
    return best


def main():
    args = sys.argv[1:]
    dry = "--dry-run" in args
    if dry:
        args.remove("--dry-run")
    if len(args) < 1 or len(args) > 2:
        sys.exit(__doc__)
    appid = args[0]
    if not APPID_RE.match(appid):
        sys.exit(f"[wanling-send-card] appid 格式非法(小写字母/数字/连字符,3-32 位): {appid}")
    conv_id = args[1] if len(args) > 1 else ""

    server_url, agent_id, secret_key, cfg_dir = load_config()
    if not conv_id:
        conv_id = lookup_conv_from_session_maps(cfg_dir)
        if not conv_id and not dry:
            sys.exit("[wanling-send-card] conv_id 未提供且 session-maps.json 无可用映射,请显式传 conv_id")
    print(f"[wanling-send-card] server={server_url} agent={agent_id} conv={conv_id or '(dry-run)'}")
    token = exchange_token(server_url, agent_id, secret_key)
    mp = find_mini_program(server_url, token, appid)
    title = mp.get("name") or "小程序"
    icon = mp.get("icon") or ""
    print(f"[wanling-send-card] 卡片: appid={appid} title={title} icon={icon or '(无,APP 端 fallback)'}")
    if dry:
        print("[wanling-send-card] dry-run 结束,未发送")
        return
    msg_id = send_card_message(server_url, token, conv_id, appid, title, icon)
    print(f"[wanling-send-card] 已发小程序卡片 message_id={msg_id}")


if __name__ == "__main__":
    main()
