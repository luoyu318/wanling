#!/usr/bin/env bash
#
# Wanling 管理面板（交互式菜单）
#
# 用法：./scripts/admin.sh
#
# 功能：
#   [1] 添加用户（调 wanling-admin add-user）
#   [2] 重置用户密码
#   [3] 列出所有用户
#   [4] 一键发布（构建 + rsync + 重启远程服务）
#   [5] 本地构建 APK + 部署到 nginx 静态目录
#   [6] 重启本地服务
#   [7] 重启桌面 APP
#   [9] 数据库迁移
#   [0] 退出
#
set -euo pipefail

# ─── 路径 ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER_DIR="$ROOT/server"
APP_DIR="$ROOT/app"

# ─── 颜色 ─────────────────────────────────────────────────────────────────
# 用 $'...' ANSI-C 引用让 \033 真正变成 ESC 字符，
# 这样 cat <<EOF 直接拼接字符串就能渲染颜色（不像 echo -e 会再解释一次）。
if [[ -t 1 ]]; then
    GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RED=$'\033[31m'; BLUE=$'\033[34m'; NC=$'\033[0m'
else
    GREEN=""; YELLOW=""; RED=""; BLUE=""; NC=""
fi
info()  { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
ok()    { printf '%s[OK]%s %s\n' "$GREEN" "$NC" "$*"; }
warn()  { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
die()   { printf '%s[ERR]%s %s\n' "$RED" "$NC" "$*" >&2; }

# ─── 工具函数 ─────────────────────────────────────────────────────────────

# 编译 admin tool 到 /tmp（增量编译，已编译过会很快）
build_admin() {
    info "编译 wanling-admin..."
    (cd "$SERVER_DIR" && go build -o /tmp/wanling-admin ./cmd/admin-tool) || die "编译失败"
}

# 用 server 的 .env 加载 DB 配置 + 跑 admin 命令
run_admin() {
    local env_file="$SERVER_DIR/.env"
    [[ -f "$env_file" ]] || die "缺少 $env_file"
    # shellcheck disable=SC1090
    set -a; . "$env_file"; set +a
    /tmp/wanling-admin "$@"
}

pause() {
    echo
    read -r -p "按回车返回菜单..." _
}

# pgrep_any <pattern1> [pattern2 ...]
# 任一 pattern 用 pgrep -f 命中即返回 0。
# 注意：pgrep 默认基本正则，'\|'（或）在不同实现行为不一致，实测本环境匹配不到，
# 故避免用 'a\|b'，改为多个 pattern 分别 pgrep 再「或」起来，兼容性最好。
pgrep_any() {
    local p
    for p in "$@"; do
        if pgrep -f "$p" >/dev/null 2>&1; then
            return 0
        fi
    done
    return 1
}

# pkill_any <signal> <pattern1> [pattern2 ...]
# 对每个 pattern 发信号，任一命中即可。配合 pgrep_any 使用。
pkill_any() {
    local sig="$1"; shift
    local p
    for p in "$@"; do
        pkill -"$sig" -f "$p" 2>/dev/null || true
    done
}

# stop_and_wait <label> <pattern1> [pattern2 ...]
# 先发 SIGTERM 让进程走优雅关闭，轮询等它退出；超时再 SIGKILL 强杀。
# 配合 server 的优雅关闭（最长 30s），这里轮询上限 35s 给足余量。
# label 在前、pattern 在后，pattern 可多个（兼容多种进程名形态）。
stop_and_wait() {
    local label="$1"; shift
    local patterns=("$@")

    if ! pgrep_any "${patterns[@]}"; then
        return 0
    fi

    info "停止 $label (SIGTERM)..."
    pkill_any TERM "${patterns[@]}"

    local waited=0
    local timeout=35
    while pgrep_any "${patterns[@]}"; do
        if (( waited >= timeout )); then
            warn "$label ${timeout}s 未退出，SIGKILL 强杀"
            pkill_any KILL "${patterns[@]}"
            sleep 1
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if pgrep_any "${patterns[@]}"; then
        die "$label 停止失败，请手动处理"
    fi
    ok "$label 已停止"
}

# wait_port_free <port> [timeout_sec]
# 轮询等待端口释放，防止上一进程还在 TIME_WAIT / 未完全关闭就 bind 冲突。
wait_port_free() {
    local port="$1"
    local timeout="${2:-10}"
    local waited=0
    while ss -tlnH 2>/dev/null | grep -q ":$port "; do
        if (( waited >= timeout )); then
            warn "端口 $port 仍被占用 (等了 ${timeout}s)"
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 0
}

# wait_health <url> [timeout_sec]
# 轮询 health 端点判断服务真正可用，比「端口在」更可靠（能抓到启动后立即崩溃）。
wait_health() {
    local url="$1"
    local timeout="${2:-15}"
    local waited=0
    while ! curl -sf "$url" >/dev/null 2>&1; do
        if (( waited >= timeout )); then
            return 1
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 0
}

# ─── 菜单项 ───────────────────────────────────────────────────────────────

menu_add_user() {
    build_admin
    local username password
    read -r -p "用户名 (3-64 字符): " username
    [[ -n "$username" ]] || { warn "用户名为空"; pause; return; }
    read -rs -p "密码 (≥6 位，留空则终端交互): " password; echo
    if [[ -n "$password" ]]; then
        run_admin add-user --username="$username" --password="$password"
    else
        # 密码留空让 admin tool 自己从 /dev/tty 读（无回显）
        run_admin add-user --username="$username"
    fi
    pause
}

menu_reset_password() {
    build_admin
    local username password
    read -r -p "用户名: " username
    [[ -n "$username" ]] || { warn "用户名为空"; pause; return; }
    read -rs -p "新密码 (≥6 位，留空则终端交互): " password; echo
    if [[ -n "$password" ]]; then
        run_admin reset-password --username="$username" --new-password="$password"
    else
        run_admin reset-password --username="$username"
    fi
    pause
}

menu_list_users() {
    build_admin
    run_admin list-users
    pause
}

menu_deploy() {
    bash "$SCRIPT_DIR/deploy.sh"
    pause
}

menu_build_apk() {
    info "构建 APK (release)..."
    (
        cd "$APP_DIR"
        PUB_HOSTED_URL=https://pub.flutter-io.cn \
        FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn \
        flutter build apk --release
    ) || die "APK 构建失败"

    local apk="$APP_DIR/build/app/outputs/flutter-apk/app-release.apk"
    [[ -f "$apk" ]] || die "APK 文件不存在: $apk"

    # 默认 cp 到 nginx 静态目录
    local dist_dir="/srv/wanling-dist"
    if [[ -d "$dist_dir" ]]; then
        cp "$apk" "$dist_dir/wanling-release.apk"
        ok "APK 已复制到 $dist_dir/wanling-release.apk"
        echo "  局域网下载: http://$(hostname -I | awk '{print $1}'):8088/wanling-release.apk"
    else
        ok "APK 位于: $apk"
    fi
    pause
}

menu_restart_local_server() {
    info "重启本地服务..."

    # 1. 优雅停旧进程：SIGTERM 轮询等退出（配合 server 优雅关闭最长 30s），
    #    超时 SIGKILL。再等端口释放，避免 bind 冲突。
    stop_and_wait "server" "wanling-server" "server/cmd/main"
    local port
    port=$(grep -E '^SERVER_PORT=' "$SERVER_DIR/.env" 2>/dev/null | cut -d= -f2)
    port="${port:-18008}"
    wait_port_free "$port" || die "端口 $port 无法释放"

    info "编译 server..."
    (cd "$SERVER_DIR" && go build -o /tmp/wanling-server ./cmd/main.go) || die "编译失败"

    # 2. 日志改追加（>>），避免重启冲掉上次的报错线索。
    cd "$ROOT"
    nohup bash -c 'set -a && . ./server/.env && set +a && /tmp/wanling-server' \
        >> /tmp/wanling-server.log 2>&1 &
    disown 2>/dev/null || true

    # 3. 用 health 端点轮询判定「真正可用」，而非仅看端口在。
    #    端口在但进程秒崩（如 DB 连不上）也能被抓到。
    if wait_health "http://localhost:$port/health" 15; then
        ok "服务已启动 (PID $(pgrep -f wanling-server | head -1))"
    else
        warn "服务未在 15s 内就绪，看 /tmp/wanling-server.log"
        tail -15 /tmp/wanling-server.log 2>/dev/null
    fi
    pause
}

menu_restart_app() {
    info "重启桌面 APP..."
    # flutter_tools.snapshot 是父进程；bundle/app 是它衍生出的真正 APP，kill 父不会自动收子。
    # 用 stop_and_wait 优雅等待退出，避免旧 APP 还在就起新的导致重复窗口。
    stop_and_wait "Flutter runner" "flutter_tools.snapshot run"
    stop_and_wait "桌面 APP" "$APP_DIR/build/linux/.*/bundle/app"
    (
        cd "$APP_DIR"
        nohup bash -c 'PUB_HOSTED_URL=https://pub.flutter-io.cn \
                        FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn \
                        flutter run -d linux --release' \
            >> /tmp/chat-app.log 2>&1 &
        disown
    )
    ok "APP 启动中（30s 后可用）"
    pause
}

menu_push() {
    info "git push..."
    cd "$ROOT"
    git push
    pause
}

menu_migrate() {
    info "编译迁移工具..."
    (cd "$SERVER_DIR" && go build -o /tmp/wanling-migrate ./cmd/migrate) || die "编译失败"

    # env 文件：优先 MIGRATE_ENV_FILE，回退源码树 server/.env
    # 服务器上跑 admin.sh 时通常 export MIGRATE_ENV_FILE=/usr/local/wanling/etc/.env
    local env_file="${MIGRATE_ENV_FILE:-$SERVER_DIR/.env}"
    [[ -f "$env_file" ]] || die "缺少 env 文件: $env_file（可 export MIGRATE_ENV_FILE=<path> 覆盖）"

    # cd 到 server/ 让 migrate 默认的 .env 和 migrations/ 相对路径都能命中
    echo
    (cd "$SERVER_DIR" && /tmp/wanling-migrate --env="$env_file" --status)
    echo
    local confirm
    read -r -p "运行待应用的迁移? [y/N] " confirm
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        (cd "$SERVER_DIR" && /tmp/wanling-migrate --env="$env_file")
        echo
        (cd "$SERVER_DIR" && /tmp/wanling-migrate --env="$env_file" --status)
    fi
    pause
}

# ─── 主菜单循环 ───────────────────────────────────────────────────────────

show_menu() {
    cat <<EOF

	${GREEN}═══════════════ Wanling 管理面板 ═══════════════${NC}
	  ${BLUE}[1]${NC} 添加用户
	  ${BLUE}[2]${NC} 重置用户密码
	  ${BLUE}[3]${NC} 列出所有用户
	  ${BLUE}[4]${NC} 一键发布（构建 + rsync + 重启远程）
	  ${BLUE}[5]${NC} 构建 APK + 推到 nginx 静态目录
	  ${BLUE}[6]${NC} 重启本地服务
	  ${BLUE}[7]${NC} 重启桌面 APP
	  ${BLUE}[8]${NC} git push
	  ${BLUE}[9]${NC} 数据库迁移
	  ${BLUE}[0]${NC} 退出
	${GREEN}═══════════════════════════════════════════════${NC}
EOF
}

main() {
    while true; do
        show_menu
        local choice
	        read -r -p "选择 [0-9]: " choice
	        case "$choice" in
	            1) menu_add_user ;;
	            2) menu_reset_password ;;
	            3) menu_list_users ;;
	            4) menu_deploy ;;
	            5) menu_build_apk ;;
	            6) menu_restart_local_server ;;
	            7) menu_restart_app ;;
	            8) menu_push ;;
	            9) menu_migrate ;;
	            0) echo "再见"; exit 0 ;;
	            *) warn "无效选择: $choice" ;;
	        esac
    done
}

main "$@"
