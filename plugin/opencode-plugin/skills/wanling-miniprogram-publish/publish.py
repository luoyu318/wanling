#!/usr/bin/env python3
"""发布万灵小程序：本地包（目录或 zip）→ 自检 → 打包 → 上传到所属 server。

用法:
  python3 publish.py <小程序目录 | 已打包的 .zip>

流程:
  1. 从 $WANLING_CONFIG_DIR/config.json 读取凭证（serverUrl/agentId/secretKey，只读不打印）
  2. 传入目录则先本地自检（manifest 必填/格式/白名单/entry 存在）再打 zip（根目录须含 manifest.json）
  3. POST /api/agents/:id/token 换 agent JWT
  4. POST /api/mini-programs（multipart 字段名 file，仅 .zip）——agent 身份上传，owner 自动归属其服务的用户

输出:
  成功打印 server 返回（id/appid/version）与后续提示；失败打印 server 错误 code/message（fail fast）。
  同 appid 重传 = 换版本（version 必须递增）且状态重置回私有；上架公共库需实例管理员 publish。
"""
import json
import os
import re
import sys
import zipfile

MAX_ZIP_BYTES = 20 * 1024 * 1024
MAX_FILES = 2000
ALLOWED_PERMISSIONS = {"wanling.api", "wanling.chat.read", "wanling.chat.share", "wanling.nav"}
APPID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{2,31}$")


def load_config():
    cfg_dir = os.environ.get("WANLING_CONFIG_DIR") or os.path.expanduser("~/.config/opencode-wanling")
    cfg_file = os.environ.get("WANLING_CONFIG_FILE") or os.path.join(cfg_dir, "config.json")
    if not os.path.isfile(cfg_file):
        sys.exit(f"[mp-publish] config 不存在: {cfg_file}")
    with open(cfg_file, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    # 环境变量优先（与 plugin config.ts 惯例一致），便于指向本地 server 测试
    server_url = os.environ.get("WANLING_SERVER_URL") or cfg.get("serverUrl") or "http://localhost:18008"
    agent_id = cfg.get("agentId") or ""
    secret_key = cfg.get("secretKey") or ""
    if not agent_id or not secret_key:
        sys.exit("[mp-publish] config.json 缺少 agentId/secretKey")
    return server_url, agent_id, secret_key


def exchange_token(server_url, agent_id, secret_key):
    import urllib.error
    import urllib.request
    req = urllib.request.Request(
        f"{server_url}/api/agents/{agent_id}/token",
        data=json.dumps({"agent_id": agent_id, "secret_key": secret_key}).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        sys.exit(f"[mp-publish] 换 token 失败 HTTP {e.code}: {e.read()[:200]}")
    if not payload.get("ok"):
        sys.exit(f"[mp-publish] 换 token 失败: {payload.get('error')}")
    return payload["data"]["token"]


def local_check(src_dir):
    """上传前自检：与 server validate.go 同规则，让 agent 在本地就能发现包问题。"""
    mf = os.path.join(src_dir, "manifest.json")
    if not os.path.isfile(mf):
        sys.exit(f"[mp-publish] 缺少 manifest.json（必须在目录根）")
    m = json.load(open(mf, encoding="utf-8"))
    appid = m.get("appid", "")
    if not APPID_RE.match(appid):
        sys.exit(f"[mp-publish] appid 非法（需匹配 ^[a-z0-9][a-z0-9-]{{2,31}}$）: {appid!r}")
    if not m.get("name"):
        sys.exit("[mp-publish] name 必填")
    if not isinstance(m.get("version"), int) or m["version"] <= 0:
        sys.exit("[mp-publish] version 需为正整数（同 appid 重传必须递增）")
    entry = m.get("entry") or "index.html"
    if not os.path.isfile(os.path.join(src_dir, entry)):
        sys.exit(f"[mp-publish] entry {entry} 不存在于目录")
    for p in m.get("permissions") or []:
        if p not in ALLOWED_PERMISSIONS:
            sys.exit(f"[mp-publish] 未知 permission: {p}（白名单: {sorted(ALLOWED_PERMISSIONS)}）")
    zip_path = os.path.join("/tmp", f"mp_publish_{appid}.zip")
    count = 0
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
        for root, _dirs, files in os.walk(src_dir):
            for fn in files:
                full = os.path.join(root, fn)
                rel = os.path.relpath(full, src_dir)
                if os.path.abspath(full) == os.path.abspath(zip_path):
                    continue
                zf.write(full, rel)
                count += 1
                if count > MAX_FILES:
                    sys.exit(f"[mp-publish] 文件数超 {MAX_FILES}")
    size = os.path.getsize(zip_path)
    if size > MAX_ZIP_BYTES:
        sys.exit(f"[mp-publish] 包 {size} 字节超上限 {MAX_ZIP_BYTES}")
    return zip_path, appid, m["version"]


def upload(server_url, token, zip_path):
    import mimetypes
    import uuid
    import urllib.error
    import urllib.request

    boundary = uuid.uuid4().hex
    fname = os.path.basename(zip_path)
    with open(zip_path, "rb") as f:
        body = (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="{fname}"\r\n'
            f"Content-Type: {mimetypes.guess_type(fname)[0] or 'application/zip'}\r\n\r\n"
        ).encode() + f.read() + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(
        f"{server_url}/api/mini-programs",
        data=body,
        headers={
            "Authorization": f"Bearer {token}",
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            payload = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        try:
            err = json.loads(e.read()).get("error", {})
        except Exception:
            err = {}
        sys.exit(f"[mp-publish] 上传失败 HTTP {e.code}: code={err.get('code')} message={err.get('message')}")
    if not payload.get("ok"):
        err = payload.get("error") or {}
        sys.exit(f"[mp-publish] 上传失败: code={err.get('code')} message={err.get('message')}")
    return payload["data"]


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = sys.argv[1]
    server_url, agent_id, secret_key = load_config()
    if os.path.isdir(src):
        zip_path, appid, version = local_check(src)
        print(f"[mp-publish] 自检通过: {appid} v{version}, 包 {zip_path}")
    elif src.endswith(".zip") and os.path.isfile(src):
        zip_path = src
        appid, version = "(zip)", "?"
    else:
        sys.exit(f"[mp-publish] 路径不存在或不是目录/.zip: {src}")
    token = exchange_token(server_url, agent_id, secret_key)
    data = upload(server_url, token, zip_path)
    print("[mp-publish] ✓ 发布成功:", json.dumps(data, ensure_ascii=False))
    print("[mp-publish] 提示: 当前为私有小程序（仅 owner 可见可运行）；")
    print("             同 appid 再发布=换版本（version 需递增，状态重置回私有）；")
    print("             上架公共库（全实例可用）需实例管理员 publish。")


if __name__ == "__main__":
    main()
