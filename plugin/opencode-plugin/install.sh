#!/usr/bin/env bash
#
# OpenCode Plugin 安装/更新脚本
#
# 用法：
#   # 全新安装（交互式或参数式）
#   ./install.sh --server=URL --agent-id=ID --secret-key=KEY [--no-allow-all]
#
#   # 扫码配对（推荐，无需手输凭据；用万灵 app 扫码授权）
#   ./install.sh --pair [--server=URL]
#
#   # 更新代码（改了代码后同步，不动配置）
#   ./install.sh --update
#
#   # 更新配置
#   ./install.sh --config --server=新URL
#
set -euo pipefail

# ─── 颜色 ──────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[34m"; NC="\033[0m"
else
    GREEN=""; YELLOW=""; RED=""; BLUE=""; NC=""
fi
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()   { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }

# ─── 常量(默认值,可用 flag 覆盖) ───────────────────────────────────────────
readonly PLUGIN_NAME="opencode-plugin"
CONFIG_DIR="${HOME}/.config/opencode-wanling"
SERVICE_NAME="opencode-wanling"

# 单文件二进制产物路径(bun compile,免 NodeJS)。空 = 用源码模式(node dist/index.js)。
# 远程安装时由 install-remote.sh 下载产物后以 --binary=<路径> 传入。
PLUGIN_BIN=""

# ─── 参数解析 ──────────────────────────────────────────────────────────────
MODE="install"
SERVER_URL="http://localhost:18008"
AGENT_ID=""
SECRET_KEY=""
ALLOW_ALL="true"
ALLOWED_USERS=""
OPENCODE_PORT="4096"
CONTROL_PORT="19780"
PROXY_PORT="5096"
OWNER_USER_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pair) MODE="pair"; shift ;;
        --update) MODE="update"; shift ;;
        --config) MODE="config"; shift ;;
        --server=*) SERVER_URL="${1#*=}"; shift ;;
        --agent-id=*) AGENT_ID="${1#*=}"; shift ;;
        --secret-key=*) SECRET_KEY="${1#*=}"; shift ;;
        --no-allow-all) ALLOW_ALL="false"; shift ;;
        --allowed-users=*) ALLOWED_USERS="${1#*=}"; shift ;;
        --opencode-port=*) OPENCODE_PORT="${1#*=}"; shift ;;
        --control-port=*) CONTROL_PORT="${1#*=}"; shift ;;
        --proxy-port=*) PROXY_PORT="${1#*=}"; shift ;;
        --config-dir=*) CONFIG_DIR="${1#*=}"; shift ;;
        --service-name=*) SERVICE_NAME="${1#*=}"; shift ;;
        --binary=*) PLUGIN_BIN="${1#*=}"; shift ;;
        --help|-h) cat <<EOF
用法: $0 [模式] [选项]

模式:
  (默认)  全新安装(交互式或参数式)
  --pair          扫码配对(推荐,无需手输凭据)
  --update        更新代码(改了代码后同步,不动配置)
  --config        更新配置

选项:
  --server=URL              万灵服务器地址 (默认 http://localhost:18008)
  --agent-id=ID             Agent ID
  --secret-key=KEY          Secret Key
  --no-allow-all            禁止所有用户访问(配合 --allowed-users)
  --allowed-users=U1,U2     允许访问的用户列表
  --opencode-port=N         OpenCode serve 端口 (默认 4096)
  --control-port=N          控制 API 端口 (默认 19780)
  --proxy-port=N            proxy 端口 (默认 5096)
  --config-dir=PATH         配置目录 (默认 ~/.config/opencode-wanling)
  --service-name=NAME       systemd 服务名 (默认 opencode-wanling)
  --binary=PATH             单文件二进制产物路径(免 NodeJS,远程安装由 install-remote.sh 传入)

多实例示例:
  # 第二套实例(隔离 configDir + 端口 + 服务名)
  $0 --config-dir=~/.config/opencode-wanling-second \\
     --service-name=opencode-wanling-second \\
     --opencode-port=4097 --proxy-port=5097 --control-port=19781 \\
     --server=http://localhost:18009
EOF
            exit 0 ;;
        *) die "未知参数: $1（用 --help 看完整选项）" ;;
    esac
done

# CONFIG_FILE 衍生自 CONFIG_DIR(放在参数解析后,让 --config-dir 生效)
CONFIG_FILE="${CONFIG_DIR}/config.json"

# ─── 查找插件目录 ──────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$SCRIPT_DIR"

# ─── 前置检查 ─────────────────────────────────────────────────────────────
check_node() {
    if ! command -v node &>/dev/null; then
        die "Node.js 未安装。请先安装 Node.js >= 18: https://nodejs.org"
    fi
    local ver
    ver=$(node --version | sed 's/^v//')
    info "Node.js 版本: $ver"
}

# ─── 配置读写 ──────────────────────────────────────────────────────────────
read_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        SERVER_URL=$(jq -r '.serverUrl // ""' "$CONFIG_FILE" 2>/dev/null || echo "$SERVER_URL")
        AGENT_ID=$(jq -r '.agentId // ""' "$CONFIG_FILE" 2>/dev/null || echo "$AGENT_ID")
        SECRET_KEY=$(jq -r '.secretKey // ""' "$CONFIG_FILE" 2>/dev/null || echo "$SECRET_KEY")
        ALLOW_ALL=$(jq -r '.allowAll // "true"' "$CONFIG_FILE" 2>/dev/null || echo "$ALLOW_ALL")
        OPENCODE_PORT=$(jq -r '.opencodePort // "4096"' "$CONFIG_FILE" 2>/dev/null || echo "$OPENCODE_PORT")
        CONTROL_PORT=$(jq -r '.controlPort // "19780"' "$CONFIG_FILE" 2>/dev/null || echo "$CONTROL_PORT")
        PROXY_PORT=$(jq -r '.proxyPort // "5096"' "$CONFIG_FILE" 2>/dev/null || echo "$PROXY_PORT")
        OWNER_USER_ID=$(jq -r '.ownerUserId // ""' "$CONFIG_FILE" 2>/dev/null || echo "$OWNER_USER_ID")
    fi
}

write_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" <<EOF
{
  "serverUrl": "${SERVER_URL}",
  "agentId": "${AGENT_ID}",
  "secretKey": "${SECRET_KEY}",
  "ownerUserId": "${OWNER_USER_ID}",
  "allowAll": ${ALLOW_ALL},
  "allowedUsers": [],
  "opencodePort": ${OPENCODE_PORT},
  "controlPort": ${CONTROL_PORT},
  "proxyPort": ${PROXY_PORT}
}
EOF
    chmod 600 "$CONFIG_FILE"
    ok "配置已写入 $CONFIG_FILE"
}

# ─── 交互式配置 ────────────────────────────────────────────────────────────
interactive_config() {
    echo ""
    read -r -p "Wanling 服务器地址 [${SERVER_URL}]: " input
    SERVER_URL="${input:-$SERVER_URL}"

    read -r -p "Agent ID [${AGENT_ID:-(未设置)}]: " input
    AGENT_ID="${input:-$AGENT_ID}"

    read -r -s -p "Secret Key [${SECRET_KEY:+(已设置)}]: " input
    echo ""
    SECRET_KEY="${input:-$SECRET_KEY}"

    echo ""
    read -r -p "允许所有用户? (true/false) [${ALLOW_ALL}]: " input
    ALLOW_ALL="${input:-$ALLOW_ALL}"
}

# ─── 安装依赖 ──────────────────────────────────────────────────────────────
install_deps() {
    info "安装 npm 依赖..."
    cd "$PLUGIN_DIR"
    local npm_log
    if npm_log=$(npm install 2>&1); then
        ok "npm 依赖已就绪"
    else
        die "npm install 失败:${npm_log:+ $npm_log}"
    fi
}

# ─── 构建 ──────────────────────────────────────────────────────────────────
build_code() {
    info "编译 TypeScript..."
    cd "$PLUGIN_DIR"
    if [[ ! -x node_modules/.bin/tsc ]]; then
        die "未找到 tsc 编译器，请先运行 npm install 安装依赖"
    fi
    node_modules/.bin/tsc || die "TypeScript 编译失败"
    ok "编译完成"
}

# ─── Systemd service ──────────────────────────────────────────────────────
setup_systemd() {
    local service_file="${HOME}/.config/systemd/user/${SERVICE_NAME}.service"
    local opencode_bin
    opencode_bin=$(which opencode 2>/dev/null)
    if [[ -z "$opencode_bin" ]]; then
        die "未在 PATH 中找到 opencode 二进制。请先安装 opencode，再重跑本脚本。"
    fi
    info "探测到 opencode 二进制: ${opencode_bin}"
    mkdir -p "$(dirname "$service_file")"

    # ExecStart:二进制模式直接用产物(免 NodeJS);源码模式 node dist/index.js
    local exec_start
    if [[ -n "$PLUGIN_BIN" && -x "$PLUGIN_BIN" ]]; then
        exec_start="${PLUGIN_BIN}"
    else
        exec_start="$(which node) ${PLUGIN_DIR}/dist/index.js"
    fi

    cat > "$service_file" <<EOF
[Unit]
Description=OpenCode Wanling Plugin
After=network.target

[Service]
Type=simple
ExecStart=${exec_start}
WorkingDirectory=${PLUGIN_DIR}
Restart=on-failure
RestartSec=5
Environment=NODE_ENV=production
Environment=OPENCODE_BIN=${opencode_bin}
Environment=WANLING_CONFIG_DIR=${CONFIG_DIR}

[Install]
WantedBy=default.target
EOF

    systemctl --user daemon-reload
    ok "systemd 服务已创建: ${SERVICE_NAME}"
}

# ─── Shell 快捷命令 ────────────────────────────────────────────────────────
setup_shell_aliases() {
    local bin_dir="${HOME}/.local/bin"
    mkdir -p "$bin_dir"

    # 脚本自包含(无 profile 硬编码),覆盖安全
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts"

    for script in ocwl ocwl-restart ocwl-logs; do
        local src="${script_dir}/${script}"
        if [[ ! -f "$src" ]]; then
            warn "脚本 ${script} 不在 ${script_dir},跳过"
            continue
        fi
        cp "$src" "${bin_dir}/${script}"
        chmod +x "${bin_dir}/${script}"
    done

    # 校验 ~/.local/bin 在 PATH
    if ! echo "${PATH}" | tr ':' '\n' | grep -qx "${bin_dir}"; then
        warn "${bin_dir} 不在 PATH,请手动加入 .zshrc/.bashrc:
  export PATH=\"${bin_dir}:\$PATH\""
    else
        ok "快捷命令已安装到 ${bin_dir}(ocwl / ocwl-restart / ocwl-logs)"
    fi
}

# ─── 服务启动 ───────────────────────────────────────────────────────────────
ensure_service() {
    if systemctl --user is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        systemctl --user restart "${SERVICE_NAME}"
        ok "服务已重启（应用新配置）"
    else
        systemctl --user start "${SERVICE_NAME}"
        systemctl --user enable "${SERVICE_NAME}" 2>/dev/null
        ok "服务已启动并设为开机自启"
    fi
}

# ─── 安装结果汇总 ──────────────────────────────────────────────────────────
print_summary() {
    local title="$1"
    local conv_id="${2:-}"
    local sync_arg="conv_id=<会话ID>"
    [[ -n "$conv_id" ]] && sync_arg="conv_id=${conv_id}"
    local profile_hint=""
    local default_dir="${HOME}/.config/opencode-wanling"
    if [[ "$CONFIG_DIR" != "$default_dir" ]]; then
        local s
        s=$(basename "$CONFIG_DIR" | sed 's/^opencode-wanling-//')
        [[ -n "$s" && "$s" != "opencode-wanling" ]] && profile_hint=" -p ${s}"
    fi
    cat <<EOF

────────────────────────────────────────
  ${title}
────────────────────────────────────────

  服务
    启动      systemctl --user start ${SERVICE_NAME}
    开机自启  systemctl --user enable ${SERVICE_NAME}
    日志      ocwl-logs${profile_hint}   (或 journalctl --user -u ${SERVICE_NAME} -f)

  使用
    进入 OpenCode   ocwl${profile_hint}            （当前目录生效，自动连万灵）
    重启服务        ocwl-restart${profile_hint}
    实时日志        ocwl-logs${profile_hint}

  接口
    控制 API        http://127.0.0.1:${CONTROL_PORT}
    触发同步        curl -X POST http://127.0.0.1:${CONTROL_PORT}/sync?${sync_arg}

  配置(多实例隔离)
    configDir       ${CONFIG_DIR}
    opencode 端口   ${OPENCODE_PORT}
    proxy 端口      ${PROXY_PORT}

  提示
    OpenCode 多会话需要 Agent 标记为 OpenCode 类型。
    在万灵 APP「我的 → Agent」新建/编辑 Agent 时选择「OpenCode」类型
    （服务端 POST /api/agents 的 type=opencode）。
────────────────────────────────────────
EOF
}

# ─── QR 码生成 ─────────────────────────────────────────────────────────────
qr_code() {
    local content="$1"
    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 "$content" 2>/dev/null && return
    fi
    if command -v python3 &>/dev/null; then
        python3 -c "
import sys
try:
    import qrcode
    qr = qrcode.QRCode(border=1)
    qr.add_data(sys.argv[1])
    qr.print_ascii(invert=True)
except ImportError:
    print('[qrcode 未安装，可用 pip install qrcode 安装]')
    print('QR 内容:', sys.argv[1])
" "$content" 2>/dev/null && return
    fi
    echo "请用任意二维码工具扫描:"
    echo "  $content"
}

# ─── 配对 ──────────────────────────────────────────────────────────────────
do_pair() {
    info "=== 扫码配对 opencode-plugin（需用万灵 app 扫码授权）==="

    command -v curl >/dev/null 2>&1 || die "未找到 curl"
    command -v python3 >/dev/null 2>&1 || die "未找到 python3"

    SERVER_URL="${SERVER_URL%/}"
    if [[ -z "$SERVER_URL" || "$SERVER_URL" == "http://localhost:18008" ]]; then
        read -r -p "Wanling 服务器地址 [${SERVER_URL}]: " input
        SERVER_URL="${input:-$SERVER_URL}"
    fi

    # 检测二维码工具
    local qr_tool="none"
    if command -v qrencode >/dev/null 2>&1; then
        qr_tool="qrencode"
    elif command -v python3 >/dev/null 2>&1 && python3 -c "import qrcode" 2>/dev/null; then
        qr_tool="python"
    fi
    if [[ "$qr_tool" == "none" ]]; then
        warn "未找到 qrencode 或 python3+qrcode，将打印纯文本配对码"
    fi

    # 1. 创建配对票据
    info "连接 $SERVER_URL 生成配对码..."
    local create_resp ticket_id http_code
    http_code=$(curl -s -o /tmp/.wl_pair_resp -w '%{http_code}' -X POST "$SERVER_URL/api/pair/tickets" \
        -H "Content-Type: application/json" \
        -d '{"type":"opencode"}')
    case "$http_code" in
        2*) ;;
        000) die "无法连接 $SERVER_URL（检查 URL / server 是否运行）" ;;
        *)   die "server 返回错误 $http_code（看 server 日志排查）。响应：$(cat /tmp/.wl_pair_resp)" ;;
    esac
    create_resp=$(cat /tmp/.wl_pair_resp)
    ticket_id=$(echo "$create_resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
d=d.get('data') or d
print(d.get('ticket_id') or d.get('id') or '')
" 2>/dev/null) || die "解析 server 响应失败：$create_resp"

    ok "配对码已生成"

    # 2. 打印二维码
    local payload="WLPAIR:${ticket_id}"
    echo ""
    info "请用万灵 APP 扫描下方二维码（消息 tab → 右上角 + → 扫一扫）："
    echo ""
    case "$qr_tool" in
        qrencode)
            qrencode -t ANSIUTF8 "$payload" 2>/dev/null || qrencode -t ANSI "$payload"
            ;;
        python)
            if [[ -t 1 ]]; then
                python3 -c "
import qrcode
qr = qrcode.QRCode(border=1)
qr.add_data('${payload}')
qr.print_ascii(tty=True)
"
            else
                python3 -c "
import qrcode
qr = qrcode.QRCode(border=1)
qr.add_data('${payload}')
qr.print_ascii(tty=False)
"
            fi
            ;;
        none)
            echo -e "${YELLOW}（无二维码工具，请用任意二维码生成器扫描）${NC}"
            echo "  ${payload}"
            ;;
    esac
    echo ""

    # 3. 轮询（2s 一次，最长 5 分钟）
    info "等待扫码...（最长 5 分钟）"
    local start=$SECONDS last_status="" elapsed
    local agent_id="" secret_key=""
    while true; do
        elapsed=$((SECONDS - start))
        if (( elapsed > 300 )); then
            die "配对超时（5 分钟未完成），请重新运行 --pair"
        fi

        local resp status poll_code
        poll_code=$(curl -s -o /tmp/.wl_pair_poll -w '%{http_code}' \
            "$SERVER_URL/api/pair/tickets/${ticket_id}")
        case "$poll_code" in
            2*) ;;
            000) die "轮询失败：无法连接 server" ;;
            *)   die "轮询失败：server 返回错误 $poll_code" ;;
        esac
        resp=$(cat /tmp/.wl_pair_poll)

        status=$(echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
d=d.get('data') or d
print(d.get('status',''))
" 2>/dev/null)

        if [[ "$status" == "completed" ]]; then
            agent_id=$(echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
d=d.get('data') or d
print(d.get('agent_id',''))
" 2>/dev/null)
            secret_key=$(echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
d=d.get('data') or d
print(d.get('secret_key',''))
" 2>/dev/null)
            OWNER_USER_ID=$(echo "$resp" | python3 -c "
import sys,json
d=json.load(sys.stdin)
d=d.get('data') or d
print(d.get('owner_user_id',''))
" 2>/dev/null)

            if [[ -z "$secret_key" ]]; then
                die "配对码状态异常：completed 但未返回凭据（可能已被领过），请重新运行"
            fi
            ok "配对成功！"
            break
        elif [[ "$status" == "expired" || "$status" == "not_found" ]]; then
            die "配对码已失效（$status），请重新运行"
        elif [[ "$status" == "scanned" && "$last_status" != "scanned" ]]; then
            info "已扫码，请在 APP 中选择 Agent..."
            last_status="scanned"
        elif [[ "$status" == "pending" && -z "$last_status" ]]; then
            info "等待扫码...（已等 ${elapsed}s）"
            last_status="pending"
        fi

        sleep 2
    done

    # 4. 写入配置 + 安装
    AGENT_ID="$agent_id"
    SECRET_KEY="$secret_key"
    write_config
    install_deps
    build_code
    setup_systemd
    setup_shell_aliases
    ensure_service

    print_summary "安装完成"
}

# ─── 模式: install ─────────────────────────────────────────────────────────
do_install() {
    info "=== 安装 opencode-plugin ==="
    # 二进制模式免 NodeJS;源码模式需 check_node
    local USE_BIN=false
    if [[ -n "$PLUGIN_BIN" && -x "$PLUGIN_BIN" ]]; then
        USE_BIN=true
        info "使用单文件二进制产物: $PLUGIN_BIN"
    else
        check_node
    fi

    if [[ -z "$AGENT_ID" || -z "$SECRET_KEY" ]]; then
        read_config
        interactive_config
    fi

    if [[ -z "$AGENT_ID" || -z "$SECRET_KEY" ]]; then
        die "agent-id 和 secret-key 不能为空"
    fi

    write_config
    if [[ "$USE_BIN" == "true" ]]; then
        # 二进制模式:复制产物到插件目录(systemd 引用固定路径,防临时目录被清)。
        # 产物已在插件目录(幂等重装)时跳过复制。
        mkdir -p "$PLUGIN_DIR"
        local target_bin="$PLUGIN_DIR/wanling-opencode-plugin"
        if [[ "$PLUGIN_BIN" != "$target_bin" ]]; then
            cp "$PLUGIN_BIN" "$target_bin"
            chmod +x "$target_bin"
        fi
        PLUGIN_BIN="$target_bin"
    else
        install_deps
        build_code
    fi
    setup_systemd
    setup_shell_aliases
    ensure_service

    print_summary "安装完成"
}

# ─── 模式: update ──────────────────────────────────────────────────────────
do_update() {
    info "=== 更新 opencode-plugin ==="
    local USE_BIN=false
    if [[ -n "$PLUGIN_BIN" && -x "$PLUGIN_BIN" ]]; then
        USE_BIN=true
        info "使用单文件二进制产物: $PLUGIN_BIN"
        # 复制产物到插件目录覆盖旧版(已在插件目录则跳过)
        mkdir -p "$PLUGIN_DIR"
        local target_bin="$PLUGIN_DIR/wanling-opencode-plugin"
        if [[ "$PLUGIN_BIN" != "$target_bin" ]]; then
            cp "$PLUGIN_BIN" "$target_bin"
            chmod +x "$target_bin"
        fi
        PLUGIN_BIN="$target_bin"
    else
        check_node
        install_deps
        build_code
    fi
    setup_systemd
    setup_shell_aliases

    if systemctl --user is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        systemctl --user restart "${SERVICE_NAME}"
        ok "服务已重启"
    else
        warn "服务未运行，已跳过重启（可手动启动）"
    fi
    print_summary "更新完成"
}

# ─── 模式: config ─────────────────────────────────────────────────────────
do_config() {
    info "=== 更新配置 ==="
    read_config
    interactive_config
    write_config

    if systemctl --user is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
        systemctl --user restart "${SERVICE_NAME}"
        ok "服务已重启"
    else
        info "配置已更新，启动服务: systemctl --user start ${SERVICE_NAME}"
    fi
}

# ─── 入口 ──────────────────────────────────────────────────────────────────
case "$MODE" in
    install) do_install ;;
    pair)    do_pair ;;
    update)  do_update ;;
    config)  do_config ;;
    *)       die "未知模式: $MODE" ;;
esac
