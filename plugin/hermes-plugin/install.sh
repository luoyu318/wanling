#!/usr/bin/env bash
#
# Hermes Wanling Plugin 安装/更新脚本
#
# 用法：
#   # 全新安装（交互式或参数式）
#   ./install.sh --server=URL --agent-id=ID --secret-key=KEY [--home-user=UID] [--no-allow-all]
#   ./install.sh --profile=heiyu --server=... --agent-id=...                  # 装到指定 profile
#   ./install.sh --register --server=URL --user-token=TOKEN                   # 注册新 agent
#
#   # 扫码配对（推荐，无需 user token；用万灵 app 扫码授权）
#   ./install.sh --pair
#   ./install.sh --pair --server=URL --profile=NAME
#
#   # 更新代码（改了 adapter.py/plugin.yaml 后同步，不动配置）
#   ./install.sh --update                                       # 同步到所有已装 wanling 的位置
#   ./install.sh --update --profile=heiyu                        # 只同步指定 profile
#
#   # 更新配置（改 server_url/agent_id 等，不动代码）
#   ./install.sh --config                                        # 交互式重设默认 profile 配置
#   ./install.sh --config --profile=heiyu --server=新URL         # 改指定 profile 的部分字段
#
# 默认 WANLING_ALLOW_ALL_USERS=true（dev 友好）。
# 生产环境用 --no-allow-all + 手动设 WANLING_ALLOWED_USERS。
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

# ─── 常量 ──────────────────────────────────────────────────────────────────
readonly PLUGIN_NAME="wanling"
readonly PLUGIN_PLATFORM="wanling-platform"
readonly ENV_MARKER_BEGIN="# >>> wanling-plugin (managed by install.sh) >>>"
readonly ENV_MARKER_END="# <<< wanling-plugin (managed by install.sh) <<<"

# ─── 全局变量：路径解析结果（resolve_paths 写入） ──────────────────────────
PLUGIN_DIR=""
ENV_FILE=""
CONFIG_YAML=""
PROFILE_LABEL=""

# ─── 参数 ──────────────────────────────────────────────────────────────────
MODE="install"          # install | update | config | pair
PROFILE=""              # 空=全局/默认 profile
SERVER=""
AGENT_ID=""
SECRET_KEY=""
HOME_USER=""
ALLOW_ALL="true"
REGISTER_MODE="false"
USER_TOKEN=""
AGENT_NAME="Hermes Agent"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server=*)       SERVER="${1#*=}"; shift ;;
        --agent-id=*)     AGENT_ID="${1#*=}"; shift ;;
        --secret-key=*)   SECRET_KEY="${1#*=}"; shift ;;
        --home-user=*)    HOME_USER="${1#*=}"; shift ;;
        --allow-all)      ALLOW_ALL="true"; shift ;;
        --no-allow-all)   ALLOW_ALL="false"; shift ;;
        --register)       REGISTER_MODE="true"; shift ;;
        --pair)           MODE="pair"; shift ;;
        --user-token=*)   USER_TOKEN="${1#*=}"; shift ;;
        --agent-name=*)   AGENT_NAME="${1#*=}"; shift ;;
        --profile=*)      PROFILE="${1#*=}"; shift ;;
        --update|--update-code) MODE="update"; shift ;;
        --config|--update-config) MODE="config"; shift ;;
        --dry-run)        DRY_RUN="true"; shift ;;
        --help|-h)
            sed -n '3,21p' "$0"
            exit 0 ;;
        *) die "未知参数: $1（用 --help 查看用法）" ;;
    esac
done

# ─── 前置检查 ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HERMES_BIN="${HERMES_BIN:-hermes}"
HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"

[[ -f "$SCRIPT_DIR/plugin.yaml" ]] || die "未找到 plugin.yaml，请在 plugin/hermes-plugin/ 目录下运行"
[[ -f "$SCRIPT_DIR/adapter.py" ]] || die "未找到 adapter.py"
[[ -f "$SCRIPT_DIR/__init__.py" ]] || die "未找到 __init__.py"
[[ -d "$HERMES_HOME" ]] || die "$HERMES_HOME 不存在，请先安装 hermes-agent"
command -v curl >/dev/null 2>&1 || die "未找到 curl"

if [[ "$REGISTER_MODE" == "true" ]]; then
    command -v python3 >/dev/null 2>&1 || die "注册模式需要 python3（解析 server 返回的 JSON）"
fi

# dry-run 包装：打印命令但不执行
run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY]${NC} $*"
    else
        eval "$@"
    fi
}

# ─── 路径解析：根据 --profile 写入全局变量 ─────────────────────────────────
# 不用 nameref（local -n）：某些 bash 5.2 调用栈下会 segfault。
resolve_paths() {
    if [[ -z "$PROFILE" ]]; then
        PLUGIN_DIR="$HERMES_HOME/plugins/$PLUGIN_NAME"
        ENV_FILE="$HERMES_HOME/.env"
        CONFIG_YAML="$HERMES_HOME/config.yaml"
        PROFILE_LABEL="默认 profile（全局）"
    else
        PLUGIN_DIR="$HERMES_HOME/profiles/$PROFILE/plugins/$PLUGIN_NAME"
        ENV_FILE="$HERMES_HOME/profiles/$PROFILE/.env"
        CONFIG_YAML="$HERMES_HOME/profiles/$PROFILE/config.yaml"
        PROFILE_LABEL="profile=$PROFILE"
    fi
}

# ─── 扫描所有已装 wanling 插件位置（update 全量同步用） ────────────────────
find_installed_plugin_dirs() {
    if [[ -d "$HERMES_HOME/plugins/$PLUGIN_NAME" ]]; then
        echo "$HERMES_HOME/plugins/$PLUGIN_NAME"
    fi
    if [[ -d "$HERMES_HOME/profiles" ]]; then
        for p_dir in "$HERMES_HOME/profiles"/*/plugins/$PLUGIN_NAME; do
            [[ -d "$p_dir" ]] && echo "$p_dir"
        done
    fi
}

# ─── 同步插件代码文件到指定目录 ────────────────────────────────────────────
sync_plugin_files() {
    local target="$1"
    run "mkdir -p '$target'"
    run "cp '$SCRIPT_DIR/plugin.yaml' '$target/'"
    run "cp '$SCRIPT_DIR/__init__.py' '$target/'"
    run "cp '$SCRIPT_DIR/adapter.py' '$target/'"
}

# ─── 交互式补全参数 ────────────────────────────────────────────────────────
prompt() {
    local var="$1" msg="$2" default="${3:-}" out
    local current="${!var}"
    [[ -n "$current" ]] && return
    if [[ "$DRY_RUN" == "true" ]]; then
        printf -v "$var" '%s' "$default"
        return
    fi
    if [[ -n "$default" ]]; then
        read -r -p "$msg [$default]: " out
        out="${out:-$default}"
    else
        read -r -p "$msg: " out
    fi
    printf -v "$var" '%s' "$out"
}

prompt_secret() {
    local var="$1" msg="$2" default="${3:-}" out
    local current="${!var}"
    [[ -n "$current" ]] && return
    if [[ "$DRY_RUN" == "true" ]]; then
        printf -v "$var" '%s' "$default"
        return
    fi
    if [[ -n "$default" ]]; then
        local masked="${default:0:4}****${default: -4}"
        read -r -s -p "$msg [$masked，回车保留]: " out; echo
        out="${out:-$default}"
    else
        read -r -s -p "$msg: " out; echo
    fi
    printf -v "$var" '%s' "$out"
}

# ─── 从 .env 读现有 WANLING_* 值（config 模式回显用） ──────────────────────
read_env_value() {
    local env_file="$1" var_name="$2"
    [[ -f "$env_file" ]] || return 0
    grep -E "^${var_name}=" "$env_file" 2>/dev/null | head -1 | sed "s|^${var_name}=||" || true
}

# ─── 写 .env：marker 包裹整段，清理按 marker 删 ────────────────────────────
write_env_block() {
    local env_file="$1"
    run "mkdir -p '$(dirname "$env_file")'"
    run "touch '$env_file'"

    # 清理旧 marker 块
    if [[ -f "$env_file" ]] && grep -qF "$ENV_MARKER_BEGIN" "$env_file"; then
        local begin_escaped end_escaped
        begin_escaped=${ENV_MARKER_BEGIN//\//\\/}
        end_escaped=${ENV_MARKER_END//\//\\/}
        run "sed -i '/^${begin_escaped}\$/,/^${end_escaped}\$/d' '$env_file'"
    fi

    # 用 heredoc 构造块，避免 $() 吞尾换行。可选行用 $'\n' 显式拼接。
    local block home_line allow_line
    block=$(cat <<EOF

$ENV_MARKER_BEGIN
# added/updated by install.sh at $(date '+%Y-%m-%d %H:%M:%S')
WANLING_SERVER_URL=$SERVER
WANLING_AGENT_ID=$AGENT_ID
WANLING_SECRET_KEY=$SECRET_KEY
EOF
)
    [[ -n "$HOME_USER" ]] && block="$block"$'\n'"WANLING_HOME_USER=$HOME_USER"
    [[ "$ALLOW_ALL" == "true" ]] && block="$block"$'\n'"WANLING_ALLOW_ALL_USERS=true"
    block="$block"$'\n'"$ENV_MARKER_END"$'\n'

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY]${NC} 追加到 $env_file："
        printf '%s' "$block" | sed 's/^/    /'
    else
        printf '%s' "$block" >> "$env_file"
        chmod 600 "$env_file"
    fi
}

# ─── 改 config.yaml 的 plugins.enabled 列表 ────────────────────────────────
# 精确处理顶层 plugins: 块，避免误伤 checkpoints.enabled / display.enabled 等。
# - 若已有 plugins: 块：往它的 enabled: 列表加（已含则跳过）
# - 若无 plugins: 块：在文件末尾追加完整的 plugins: 块
ensure_plugin_enabled() {
    local config_yaml="$1"
    [[ -f "$config_yaml" ]] || { warn "$config_yaml 不存在，跳过 enabled 配置"; return; }

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY]${NC} 确保 $config_yaml 的 plugins.enabled 含 $PLUGIN_PLATFORM"
        return
    fi

    # 已在 plugins.enabled 列表则跳过。
    # 精确匹配 plugins: 块下的 "- wanling-platform" 行（2 空格缩进）。
    if awk '
        /^plugins:/ { in_plugins=1; next }
        /^[^[:space:]]/ { in_plugins=0 }
        in_plugins && $0 ~ /^[[:space:]]*-[[:space:]]*'"$PLUGIN_PLATFORM"'$/ { found=1; exit }
        END { exit !found }
    ' "$config_yaml"; then
        return
    fi

    # 用 awk 处理：找到 plugins: 块，往 enabled: 下追加。
    # 若没有 plugins: 块，记下来在末尾新建。
    local tmp has_plugins
    tmp=$(mktemp)
    has_plugins=0
    awk -v platform="$PLUGIN_PLATFORM" '
        BEGIN { in_plugins=0; added=0; has_plugins=0 }
        /^plugins:/ { in_plugins=1; has_plugins=1; print; next }
        /^[^[:space:]]/ {
            # 离开 plugins 块前，若还没加 platform 且 plugins 块里有 enabled:，这里不处理
            in_plugins=0
        }
        {
            print
        }
        END {
            # 末尾若无 plugins 块，新建一个
            if (!has_plugins) {
                printf "\nplugins:\n  enabled:\n  - %s\n  disabled: []\n", platform
            }
        }
    ' "$config_yaml" > "$tmp"

    if [[ "$has_plugins" == "0" ]]; then
        # 无 plugins 块，awk 已在末尾新建（含 platform），直接替换
        mv "$tmp" "$config_yaml"
    else
        # 有 plugins 块，需要往 enabled: 下插。
        # 重新处理：在 plugins: 块的 enabled: 行后追加 platform。
        awk -v platform="$PLUGIN_PLATFORM" '
            BEGIN { in_plugins=0; added=0 }
            /^plugins:/ { in_plugins=1; print; next }
            /^[^[:space:]]/ { in_plugins=0 }
            in_plugins && !added && /^[[:space:]]*enabled:/ {
                print
                printf "  - %s\n", platform
                added=1
                next
            }
            { print }
            END {
                # 兜底：若 plugins 块里没 enabled: 行（异常），在 plugins: 后补
                # 这里无法回溯，依赖 config.yaml 结构正常
            }
        ' "$config_yaml" > "$tmp"
        mv "$tmp" "$config_yaml"
    fi
}

# ─── 写/更新 config.yaml 的顶层 wanling.extra 块 ──────────────────────────
# adapter.py 读 extra（server_url/agent_id/secret_key/home_user）。
# 用 marker 包裹整段，清理按 marker 删后重写，避免旧值残留。
# 缩进参考 heiyu profile：顶层 wanling:，extra 下 4 空格缩进字段。
write_wanling_block() {
    local config_yaml="$1"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY]${NC} 写 $config_yaml 的 wanling.extra 块"
        return
    fi

    [[ -f "$config_yaml" ]] || { warn "$config_yaml 不存在，跳过 wanling 配置"; return; }

    # 删除已有的顶层 wanling: 块（从 ^wanling: 到下一个顶层 key 或文件末尾）
    # 用 awk 精确处理：进入 wanling 块后，遇到下一个顶层 key（行首非空白）就停
    local tmp
    tmp=$(mktemp)
    awk '
        BEGIN { skip=0 }
        /^[^[:space:]]/ {
            if (skip && $1 != "wanling:") skip=0
            if ($1 == "wanling:") { skip=1; next }
        }
        !skip { print }
        # skip 中且遇到下一个顶层 key：恢复打印（上面已处理）
    ' "$config_yaml" > "$tmp"
    mv "$tmp" "$config_yaml"

    # 追加新的 wanling 块到文件末尾
    {
        echo ""
        echo "wanling:"
        echo "  enabled: true"
        echo "  extra:"
        echo "    server_url: $SERVER"
        echo "    agent_id: $AGENT_ID"
        echo "    secret_key: $SECRET_KEY"
        if [[ -n "$HOME_USER" ]]; then
            echo "    home_user: $HOME_USER"
        fi
        if [[ "$ALLOW_ALL" == "true" ]]; then
            echo "    allow_all_users: true"
        fi
    } >> "$config_yaml"
}

# ─── 模式：update（只同步代码） ────────────────────────────────────────────
run_update_mode() {
    info "模式：更新插件代码（不动配置）"

    local targets=()
    if [[ -n "$PROFILE" ]]; then
        resolve_paths
        [[ -d "$PLUGIN_DIR" ]] || die "$PROFILE_LABEL 未安装 wanling 插件（$PLUGIN_DIR 不存在）。先用默认安装模式装一次。"
        targets+=("$PLUGIN_DIR")
        info "目标：$PROFILE_LABEL"
    else
        while IFS= read -r line; do
            targets+=("$line")
        done < <(find_installed_plugin_dirs)
        [[ ${#targets[@]} -gt 0 ]] || die "未找到任何已安装的 wanling 插件。先用默认安装模式装一次。"
        info "目标：所有已装位置（${#targets[@]} 个）"
    fi

    for t in "${targets[@]}"; do
        echo
        info "同步到 $t"
        sync_plugin_files "$t"
        [[ "$DRY_RUN" != "true" ]] && ok "已同步：$t"
    done

    echo
    if [[ "$DRY_RUN" == "true" ]]; then
        warn "DRY-RUN 完成（未实际执行）"
    else
        ok "✓ 代码更新完成（${#targets[@]} 个位置）"
    fi
    echo
    echo "重启 gateway 让新代码生效："
    if [[ -n "$PROFILE" ]]; then
        echo "  hermes --profile=$PROFILE gateway restart"
    else
        echo "  hermes gateway restart  # 默认 profile"
        echo "  hermes --profile=<name> gateway restart  # 各 profile 分别重启"
    fi
}

# ─── 模式：config（只改配置） ──────────────────────────────────────────────
run_config_mode() {
    info "模式：更新配置（不动代码）"
    resolve_paths
    [[ -d "$PLUGIN_DIR" ]] || die "$PROFILE_LABEL 未安装 wanling 插件。先用默认安装模式装一次。"

    info "目标：$PROFILE_LABEL"
    info "读取现有配置作为默认值（回车保留原值）..."

    local cur_server cur_agent cur_secret cur_home
    cur_server=$(read_env_value "$ENV_FILE" "WANLING_SERVER_URL")
    cur_agent=$(read_env_value "$ENV_FILE" "WANLING_AGENT_ID")
    cur_secret=$(read_env_value "$ENV_FILE" "WANLING_SECRET_KEY")
    cur_home=$(read_env_value "$ENV_FILE" "WANLING_HOME_USER")

    prompt SERVER "Wanling server URL" "$cur_server"
    prompt AGENT_ID "Agent ID" "$cur_agent"
    prompt_secret SECRET_KEY "Agent secret_key" "$cur_secret"
    prompt HOME_USER "Home user ID（可选）" "$cur_home"

    echo
    write_env_block "$ENV_FILE"
    ensure_plugin_enabled "$CONFIG_YAML"
    write_wanling_block "$CONFIG_YAML"

    echo
    if [[ "$DRY_RUN" == "true" ]]; then
        warn "DRY-RUN 完成（未实际执行）"
    else
        ok "✓ 配置更新完成（$PROFILE_LABEL）"
        echo "  Server:    $SERVER"
        echo "  Agent ID:  $AGENT_ID"
        [[ -n "$HOME_USER" ]] && echo "  Home user: $HOME_USER"
    fi
    echo
    echo "重启 gateway 让新配置生效："
    if [[ -n "$PROFILE" ]]; then
        echo "  hermes --profile=$PROFILE gateway restart"
    else
        echo "  hermes gateway restart"
    fi
}

# ─── 模式：pair（扫码配对） ─────────────────────────────────────────────────
# hermes 终端生成 ticket → 打印 ASCII 二维码 → 轮询拿凭据 → 写配置。
# 全程不依赖 user token，凭 ticket_id（256-bit）鉴权。
run_pair_mode() {
    info "模式：扫码配对（需用万灵 app 扫码授权）"
    resolve_paths

    prompt SERVER "Wanling server URL" "http://localhost:18008"
    command -v curl >/dev/null 2>&1 || die "未找到 curl"

    # 检测二维码生成工具（三级兜底）
    local qr_tool="none"
    if command -v qrencode >/dev/null 2>&1; then
        qr_tool="qrencode"
    elif command -v python3 >/dev/null 2>&1 && python3 -c "import qrcode" 2>/dev/null; then
        qr_tool="python"
    fi
    if [[ "$qr_tool" == "none" ]]; then
        warn "未找到 qrencode 或 python3+qrcode，将打印纯文本配对码"
        warn "建议安装：apt install qrencode  或  pip install qrcode"
    fi

    # 1. 生成 ticket
    info "连接 $SERVER 生成配对码..."
    local create_resp ticket_id
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY]${NC} 跳过实际连接 server"
        ticket_id="$(python3 -c "import secrets;print(secrets.token_hex(32))" 2>/dev/null || echo dryrunplaceholderforticketid0000000000000000000000000000000000)"
    else
        create_resp=$(curl -sf -X POST "$SERVER/api/pair/tickets" 2>/dev/null) \
            || die "无法连接 $SERVER（检查 URL / server 是否运行）"
        ticket_id=$(echo "$create_resp" | python3 -c "import sys,json;print(json.load(sys.stdin)['ticket_id'])" 2>/dev/null) \
            || die "解析 server 响应失败：$create_resp"
    fi
    ok "配对码已生成"

    # 2. 打印二维码（内容 = WLPAIR:<ticket_id>，带协议头便于 app 识别）
    local payload="WLPAIR:$ticket_id"
    echo
    info "请用万灵 app 扫描下方二维码（Agent 页右上角 + → 扫一扫）："
    echo
    case "$qr_tool" in
        qrencode)
            # ANSIUTF8 彩色最佳，老版本回退 ANSI
            qrencode -t ANSIUTF8 "$payload" 2>/dev/null || qrencode -t ANSI "$payload"
            ;;
        python)
            # tty=True 在非交互（管道/重定向）环境会抛 OSError。
            # 检测 stdout 是否 tty：是则用彩色 tty 模式，否则用纯字符矩阵。
            if [[ -t 1 ]]; then
                python3 -c "
import qrcode
qr = qrcode.QRCode(border=1)
qr.add_data('$payload')
qr.print_ascii(tty=True)
"
            else
                python3 -c "
import qrcode
qr = qrcode.QRCode(border=1)
qr.add_data('$payload')
qr.print_ascii(tty=False)
"
            fi
            ;;
        none)
            echo -e "${YELLOW}（无二维码工具，请用任意二维码生成器扫描下方文本）${NC}"
            echo "  $payload"
            ;;
    esac
    echo

    # 3. 轮询（2s 一次，最长 5 分钟）
    info "等待扫码...（最长 5 分钟）"
    local start=$SECONDS last_status="" elapsed
    while true; do
        elapsed=$((SECONDS - start))
        if (( elapsed > 300 )); then
            die "配对超时（5 分钟未完成），请重新运行"
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "${YELLOW}[DRY]${NC} 会每 2s 轮询 $SERVER/api/pair/tickets/$ticket_id"
            agent_id="<would-be-fetched>"
            secret_key="<would-be-fetched>"
            break
        fi

        local resp status agent_id secret_key=""
        resp=$(curl -sf "$SERVER/api/pair/tickets/$ticket_id" 2>/dev/null) \
            || die "轮询失败：无法连接 server"
        status=$(echo "$resp" | python3 -c "import sys,json;print(json.load(sys.stdin).get('status',''))" 2>/dev/null)

        if [[ "$status" == "completed" ]]; then
            agent_id=$(echo "$resp" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('agent_id',''))" 2>/dev/null)
            secret_key=$(echo "$resp" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('secret_key',''))" 2>/dev/null)
            # 自动取 owner_user_id 作为 home_user（cron 投递目标），
            # 用户无需手动输入。若 server 未返回则保持空（向后兼容）。
            owner_user_id=$(echo "$resp" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('owner_user_id',''))" 2>/dev/null)
            if [[ -n "$owner_user_id" && -z "$HOME_USER" ]]; then
                HOME_USER="$owner_user_id"
            fi
            if [[ -z "$secret_key" ]]; then
                die "配对码状态异常：completed 但未返回凭据（可能已被领过），请重新运行"
            fi
            ok "✓ 配对成功"
            break
        elif [[ "$status" == "expired" || "$status" == "not_found" ]]; then
            die "配对码已失效（$status），请重新运行"
        elif [[ "$status" == "scanned" && "$last_status" != "scanned" ]]; then
            info "已扫码，请在 app 中选择 Agent..."
            last_status="scanned"
        elif [[ "$status" == "pending" && -z "$last_status" ]]; then
            info "等待扫码...（已等 ${elapsed}s）"
            last_status="pending"
        fi

        sleep 2
    done

    # 4. 写配置（复用现有逻辑）
    AGENT_ID="$agent_id"
    SECRET_KEY="$secret_key"
    [[ -z "$HOME_USER" ]] && warn "未设 WANLING_HOME_USER，cron 任务无法投递"

    if [[ "$DRY_RUN" != "true" ]]; then
        info "安装 plugin 文件到 $PLUGIN_DIR"
        if [[ -d "$PLUGIN_DIR" ]]; then
            warn "目标目录已存在，直接覆盖"
            rm -rf "$PLUGIN_DIR"
        fi
        sync_plugin_files "$PLUGIN_DIR"
        write_env_block "$ENV_FILE"
        ensure_plugin_enabled "$CONFIG_YAML"
        write_wanling_block "$CONFIG_YAML"

        echo
        ok "✓ 安装完成（$PROFILE_LABEL）"
        echo "  Wanling server: $SERVER"
        echo "  Agent ID:       $AGENT_ID"
        echo
        echo "下一步：重启 gateway 让 plugin 生效："
        if [[ -n "$PROFILE" ]]; then
            echo "  hermes --profile=$PROFILE gateway restart"
        else
            echo "  hermes gateway restart"
        fi
    else
        warn "DRY-RUN 完成（未实际写入配置）"
    fi
}

# ─── 模式：install（全新安装） ─────────────────────────────────────────────
run_install_mode() {
    resolve_paths
    info "模式：全新安装 → $PROFILE_LABEL"

    if [[ "$REGISTER_MODE" == "true" ]]; then
        info "注册模式：在 server 上新建 agent，自动拿 agent_id + secret_key"
        prompt SERVER "Wanling server URL" "http://localhost:18008"
        prompt_secret USER_TOKEN "你的 user JWT token（用于创建 agent）"
        prompt AGENT_NAME "Agent 显示名" "Hermes Agent"

        if [[ "$DRY_RUN" != "true" ]]; then
            info "调用 POST $SERVER/api/agents 创建 agent..."
            RESP=$(curl -sf -X POST "$SERVER/api/agents" \
                -H "Authorization: Bearer $USER_TOKEN" \
                -H "Content-Type: application/json" \
                -d "{\"name\":\"$AGENT_NAME\"}") || die "创建 agent 失败（检查 server 是否可达 / user token 是否有效）"

            # 解析 JSON，失败打印原始响应
            if ! AGENT_ID=$(echo "$RESP" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])" 2>/dev/null) \
               || ! SECRET_KEY=$(echo "$RESP" | python3 -c "import sys,json;print(json.load(sys.stdin)['secret_key'])" 2>/dev/null); then
                echo -e "${RED}[ERR]${NC} 解析 server 响应失败。原始响应：" >&2
                echo "$RESP" >&2
                die "预期 {\"id\":..., \"secret_key\":...}，解析失败"
            fi
            ok "Agent 已创建：id=$AGENT_ID"
        else
            echo -e "${YELLOW}[DRY]${NC} 跳过实际创建 agent（dry-run）"
            AGENT_ID="<would-be-created>"
            SECRET_KEY="<would-be-created>"
        fi
    else
        prompt SERVER "Wanling server URL" "http://localhost:18008"
        prompt AGENT_ID "已注册的 agent_id（UUID）"
        prompt_secret SECRET_KEY "agent secret_key"
    fi

    [[ -z "$HOME_USER" ]] && warn "未设 WANLING_HOME_USER，cron 任务无法投递到任何 user（按需手动设）"

    echo
    info "安装 plugin 文件到 $PLUGIN_DIR"
    if [[ -d "$PLUGIN_DIR" && "$DRY_RUN" != "true" ]]; then
        # 不能用 .bak 备份：hermes 会扫描 plugins/ 下所有子目录，两个同名 plugin 双注册。
        warn "目标目录已存在，直接覆盖"
        rm -rf "$PLUGIN_DIR"
    fi
    sync_plugin_files "$PLUGIN_DIR"
    [[ "$DRY_RUN" != "true" ]] && ok "plugin 文件已复制"

    echo
    write_env_block "$ENV_FILE"
    ensure_plugin_enabled "$CONFIG_YAML"
    write_wanling_block "$CONFIG_YAML"

    echo
    if [[ "$DRY_RUN" == "true" ]]; then
        warn "DRY-RUN 完成（未实际执行）"
    else
        ok "✓ 安装完成（$PROFILE_LABEL）"
        echo "  Wanling server: $SERVER"
        echo "  Agent ID:       $AGENT_ID"
        [[ -n "$HOME_USER" ]] && echo "  Home user:      $HOME_USER"
        [[ "$ALLOW_ALL" == "true" ]] && warn "  当前为 ALLOW_ALL 模式（dev 用），生产环境建议改用 WANLING_ALLOWED_USERS"
        if [[ "$REGISTER_MODE" == "true" ]]; then
            echo
            echo -e "${YELLOW}提示${NC}：secret_key 只显示这一次，请妥善保存："
            echo "  $SECRET_KEY"
        fi
    fi
    echo
    echo "下一步：重启 gateway 让 plugin 生效："
    if [[ -n "$PROFILE" ]]; then
        echo "  hermes --profile=$PROFILE gateway restart"
    else
        echo "  hermes gateway restart"
    fi
    echo "查看状态：hermes gateway status"
    echo "看加载日志：tail -f ~/.hermes/logs/gateway.log"
}

# ─── 主入口 ────────────────────────────────────────────────────────────────
case "$MODE" in
    update) run_update_mode ;;
    config) run_config_mode ;;
    install) run_install_mode ;;
    pair) run_pair_mode ;;
    *) die "未知模式: $MODE" ;;
esac
