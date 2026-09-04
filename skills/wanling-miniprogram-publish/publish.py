#!/usr/bin/env python3
"""发布万灵小程序：本地包（目录或 zip）→ 自检 → 打包 → 上传到所属 server。

用法:
  python3 publish.py <小程序目录 | 已打包的 .zip>

流程:
  1. 按探测顺序读取凭据 config.json（serverUrl/agentId/secretKey，只读不打印）:
     WANLING_CONFIG_FILE → WANLING_CONFIG_DIR → ~/.config/opencode-wanling → ~/.config/wanling-skills
  2. 传入目录则先本地自检（manifest 必填/格式/白名单/navigationBar/icon 魔数/entry 存在，与 server validate.go 同规则）再打 zip（根目录须含 manifest.json）
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
ALLOWED_PERMISSIONS = {"wanling.api", "wanling.chat.read", "wanling.chat.share", "wanling.nav", "wanling.storage"}
APPID_RE = re.compile(r"^[a-z0-9][a-z0-9-]{2,31}$")
# 以下与 server validate.go 对齐
ICON_EXTS = {".png", ".jpg", ".jpeg", ".webp"}
MAX_ICON_BYTES = 256 << 10
COLOR_RE = re.compile(r"^#[0-9a-fA-F]{6}$")
COLLECTION_NAME_RE = re.compile(r"^[a-z0-9_-]{1,32}$")
ALLOWED_COLLECTION_MODES = {"private", "shared_read", "shared_write"}
MAX_COLLECTIONS = 16


def sniff_image_ct(b):
    """按魔数嗅探图片类型（镜像 server SniffImageCT）；非图片返回空串。"""
    if b[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if b[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if len(b) >= 12 and b[:4] == b"RIFF" and b[8:12] == b"WEBP":
        return "image/webp"
    return ""


def validate_navigation_bar(nb):
    """镜像 server validateNavigationBar：style 枚举、颜色 #RRGGBB（可空）。"""
    if nb is None:
        return
    if not isinstance(nb, dict):
        sys.exit("[mp-publish] navigationBar 需为对象")
    style = nb.get("style", "")
    if style not in ("", "default", "custom"):
        sys.exit(f"[mp-publish] navigation_bar.style 需为 default/custom, got {style!r}")
    for field in ("backgroundColor", "foregroundColor"):
        v = nb.get(field) or ""
        if v and not COLOR_RE.match(v):
            sys.exit(f"[mp-publish] navigation_bar.{field} 需为 #RRGGBB, got {v!r}")


def validate_icon(m, src_dir):
    """镜像 server icon 校验：声明了就必须是白名单扩展名/真实存在/≤256KB/魔数为图片。"""
    icon = m.get("icon") or ""
    if not icon:
        return
    if os.path.splitext(icon)[1].lower() not in ICON_EXTS:
        sys.exit(f"[mp-publish] icon 扩展名需为 png/jpg/jpeg/webp, got {icon!r}")
    ipath = os.path.join(src_dir, icon)
    if not os.path.isfile(ipath):
        sys.exit(f"[mp-publish] icon {icon} 不在目录内")
    with open(ipath, "rb") as f:
        data = f.read()
    if len(data) > MAX_ICON_BYTES:
        sys.exit(f"[mp-publish] icon 超 256KB 上限（{len(data)} 字节）")
    if not sniff_image_ct(data):
        sys.exit("[mp-publish] icon 内容非图片（魔数不识别）")


def validate_collections(m):
    """镜像 server validate.go 的 collections 校验：
    ≤16 个、name 正则 + default 保留、mode 三选一、重名拒。"""
    colls = m.get("collections") or []
    if len(colls) > MAX_COLLECTIONS:
        sys.exit(f"[mp-publish] collections 数量超上限({MAX_COLLECTIONS})")
    seen = set()
    for c in colls:
        name = c.get("name", "") if isinstance(c, dict) else ""
        if not COLLECTION_NAME_RE.match(name):
            sys.exit(f"[mp-publish] collection name 非法: {name!r}(须 ^[a-z0-9_-]{{1,32}}$)")
        if name == "default":
            sys.exit("[mp-publish] collection name 保留: default")
        if c.get("mode") not in ALLOWED_COLLECTION_MODES:
            sys.exit(f"[mp-publish] collection mode 非法: {c.get('mode')!r}(须 private/shared_read/shared_write)")
        if name in seen:
            sys.exit(f"[mp-publish] collection 重名: {name}")
        seen.add(name)


def config_candidates():
    """凭据探测顺序(与 install.sh 装后检测同序):第一个存在的文件生效。
    WANLING_CONFIG_FILE 显式指定(唯一候选,不存在即报错) → 否则依次:
    WANLING_CONFIG_DIR → opencode 插件配置(存在则用) → 技能 setup 配置(存在则用)。"""
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
        print(f"[mp-publish] server: {env_server} (env: 宿主 agent 身份)")
        return env_server, env_agent, env_secret
    if env_server or env_agent or env_secret:
        # 部分设置会跨 server 混用身份（如 env 的密钥发给文件里的另一台 server）,拒绝
        sys.exit("[mp-publish] 宿主 env 三元组不完整: WANLING_SERVER_URL/WANLING_AGENT_ID/"
                 "WANLING_SECRET_KEY 需同时设置或同时不设")
    candidates = config_candidates()
    cfg_file = next((p for p in candidates if os.path.isfile(p)), "")
    if not cfg_file:
        sys.exit(
            "[mp-publish] 未找到凭据配置,已探测:\n  " + "\n  ".join(candidates)
            + "\n  （或宿主进程 env 三元组 WANLING_SERVER_URL/WANLING_AGENT_ID/WANLING_SECRET_KEY）"
            + "\n[mp-publish] 运行 skills/install.sh --setup 用 APP 扫码完成授权"
        )
    with open(cfg_file, "r", encoding="utf-8") as f:
        cfg = json.load(f)
    # 环境变量优先（与 plugin config.ts 惯例一致），便于指向本地 server 测试
    server_url = os.environ.get("WANLING_SERVER_URL") or cfg.get("serverUrl") or "http://localhost:18008"
    agent_id = cfg.get("agentId") or ""
    secret_key = cfg.get("secretKey") or ""
    if not agent_id or not secret_key:
        sys.exit("[mp-publish] config.json 缺少 agentId/secretKey")
    # 可视性:打印生效 server 与 config 来源(不含密钥),多实例时便于发现打错目标
    print(f"[mp-publish] server: {server_url} (config: {cfg_file})")
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
    validate_navigation_bar(m.get("navigationBar"))
    validate_collections(m)
    validate_icon(m, src_dir)
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
