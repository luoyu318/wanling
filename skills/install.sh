#!/usr/bin/env bash
#
# 万灵 agent 技能安装器(本地/远程双模式,多平台目标)
#
# 布局: 技能本体统一种在 ~/.agents/skills/<name>(canonical),
#       --target 指定哪些 agent 工具通过软链发现它,避免多副本重复发现。
#
# 选项:
#   --target LIST     逗号分隔: agents,opencode,claude,codex,gemini,copilot(默认 opencode)
#   --dir PATH        安装到自定义目录(忽略 --target,不建软链)
#   --migrate-legacy  发现旧位置真实副本时允许迁移(默认停止,防静默覆盖)
#   --gen-manifest    (仅本地)重新生成 manifest.sha256
#   --setup           扫码授权技能凭据(APP 扫码选 Agent「授权技能使用」→ server 发子密钥);
#                     单跑 = 只授权不装技能;带技能名 = 先装再授权
#   --server=URL      万灵 server 地址(--setup 用;未传则交互输入,默认 http://localhost:18008)
#   --config-dir=PATH 凭据配置目录(--setup 用;默认 ~/.config/wanling-skills;
#                     setup 写路径刻意忽略 env WANLING_CONFIG_DIR,防运行环境注入 env 覆盖插件配置)
#   --force           --setup 允许向插件专用目录(opencode-wanling[-prod])写凭据(默认拒绝)
#   --remote          强制远程模式(默认按 SCRIPT_DIR 自动判定)
#   -h                帮助;技能名缺省 = 全部(--setup 单跑时除外)
#
# 远程(推荐,无需克隆仓库):
#   bash <(curl -fsSL https://gitee.com/luoyu318/wanling/raw/main/skills/install.sh) [选项] [技能名...]
# 本地(仓库内):
#   ./install.sh [选项] [技能名...]
#
# 技能: wanling-miniprogram-publish / wanling-send-image
set -euo pipefail

if [[ -t 1 ]]; then
    GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[34m"; NC="\033[0m"
else
    GREEN=""; YELLOW=""; RED=""; BLUE=""; NC=""
fi
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

usage() {
    # 仅取文件头帮助注释块(遇首个非注释行即止),不混入实现区注释
    awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^#( |$)/, ""); print }' "${BASH_SOURCE[0]}"
}

readonly RAW_GITEE="https://gitee.com/luoyu318/wanling/raw"
readonly RAW_GITHUB="https://raw.githubusercontent.com/luoyu318/wanling"
readonly BRANCH="${WANLING_SKILLS_BRANCH:-main}"
readonly CANONICAL="${HOME}/.agents/skills"

# target 名 → 该 agent 的技能发现目录(空串 = 通用目录本体,无需软链)
declare -A TARGET_DIR=(
    [agents]=""
    [opencode]="${HOME}/.opencode/skills"
    [claude]="${HOME}/.claude/skills"
    [codex]="${HOME}/.codex/skills"
    [gemini]="${HOME}/.gemini/skills"
    [copilot]="${HOME}/.copilot/skills"
)
# 历史安装器可能落过真实目录的位置(防同名重复发现)
LEGACY_DIRS=(
    "${HOME}/.claude/skills" "${HOME}/.codex/skills" "${HOME}/.gemini/skills"
    "${HOME}/.copilot/skills" "${HOME}/.config/opencode/skills" "${HOME}/.opencode/skills"
)

# ─── 参数解析 ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""
FORCE_REMOTE=false
TARGETS="opencode"
DIR_OVERRIDE=""
MIGRATE=false
GEN_MANIFEST=false
SETUP_MODE=false
SETUP_SERVER=""
SETUP_CONFIG_DIR=""
SETUP_FORCE=false
SETUP_TMP_RESP=""   # --setup 的 server 响应临时文件(mktemp 创建,EXIT trap 清理;须全局,trap 在函数返回后才触发)
REQUEST=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGETS="$2"; shift 2 ;;
        --dir) DIR_OVERRIDE="$2"; shift 2 ;;
        --migrate-legacy) MIGRATE=true; shift ;;
        --gen-manifest) GEN_MANIFEST=true; shift ;;
        --setup) SETUP_MODE=true; shift ;;
        --server=*) SETUP_SERVER="${1#*=}"; shift ;;
        --server) SETUP_SERVER="$2"; shift 2 ;;
        --config-dir=*) SETUP_CONFIG_DIR="${1#*=}"; shift ;;
        --config-dir) SETUP_CONFIG_DIR="$2"; shift 2 ;;
        --force) SETUP_FORCE=true; shift ;;
        --remote) FORCE_REMOTE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "未知选项: $1(-h 看帮助)" ;;
        *) REQUEST+=("$1"); shift ;;
    esac
done

IS_LOCAL=false
if [[ -n "$SCRIPT_DIR" && -d "$SCRIPT_DIR/wanling-miniprogram-publish" && "$FORCE_REMOTE" != true ]]; then
    IS_LOCAL=true
fi

# ─── --gen-manifest(仅本地): 重生成载荷清单 ────────────────────────────────
if [[ "$GEN_MANIFEST" == true ]]; then
    [[ "$IS_LOCAL" == true ]] || die "--gen-manifest 仅支持本地模式"
    ( cd "$SCRIPT_DIR" && find wanling-* -type f -not -name 'manifest.sha256' \
      -not -path '*/__pycache__/*' | sort |
      xargs -r sha256sum > manifest.sha256 )
    ok "manifest.sha256 已生成($(( $(wc -l < "$SCRIPT_DIR/manifest.sha256") )) 个文件)"
    exit 0
fi

# ─── server REST 响应字段提取 ──────────────────────────────────────────────
# 响应为 {ok,data:{...}} 包装;data 缺失时兼容顶层取字段。解析失败返回空串。
json_field() {   # $1=响应 JSON $2=字段名 → 打印字段值
    python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit
d = d.get("data") or d
v = d.get(sys.argv[1], "")
print("" if v is None else v)
' "$2" <<<"$1"
}

# ─── 二维码打印(三级兜底,与 plugin/opencode-plugin/install.sh 手法一致) ───
print_qr() {
    local content="$1"
    if command -v qrencode &>/dev/null; then
        qrencode -t ANSIUTF8 "$content" 2>/dev/null && return
    fi
    if command -v python3 &>/dev/null && python3 -c "import qrcode" 2>/dev/null; then
        python3 -c '
import sys, qrcode
qr = qrcode.QRCode(border=1)
qr.add_data(sys.argv[1])
qr.print_ascii(invert=True)
' "$content" 2>/dev/null && return
    fi
    warn "未找到 qrencode / python3+qrcode,请复制下方配对码用任意二维码工具生成后扫码"
}

# ─── 技能凭据探测(与 publish.py/upload.py load_config 同顺序) ─────────────
# WANLING_CONFIG_FILE 显式指定 → WANLING_CONFIG_DIR → opencode 插件配置(存在则用)
# → 技能 setup 配置(存在则用);第一个存在的文件生效。命中打印路径,未命中返回非零。
detect_credential() {
    local candidates=()
    if [[ -n "${WANLING_CONFIG_FILE:-}" ]]; then
        candidates=("${WANLING_CONFIG_FILE}")
    else
        if [[ -n "${WANLING_CONFIG_DIR:-}" ]]; then
            candidates+=("${WANLING_CONFIG_DIR}/config.json")
        fi
        candidates+=("${HOME}/.config/opencode-wanling/config.json")
        candidates+=("${HOME}/.config/wanling-skills/config.json")
    fi
    local p
    for p in "${candidates[@]}"; do
        if [[ -f "$p" ]]; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}

print_credential_status() {
    local cred
    if cred="$(detect_credential)"; then
        ok "已检测到凭据: ${cred}"
    else
        warn "未检测到技能凭据(发布/发图不可用);运行 skills/install.sh --setup 用 APP 扫码完成授权"
    fi
}

# ─── --setup: 扫码授权技能凭据 ────────────────────────────────────────────
# 流程: POST /api/pair/tickets(空 body,authorize 不新建 agent 不声明类型)
#       → 终端二维码 WLPAIR:<ticket_id> → APP 扫码选 Agent「授权技能使用」
#       → 2s 轮询 completed → 领 {agent_id, agent_name, secret_key(wlsk_ 子密钥)}
#       → 写 config(chmod 600,领完即焚凭据只存本机)。
do_setup() {
    command -v curl >/dev/null 2>&1 || die "未找到 curl"
    command -v python3 >/dev/null 2>&1 || die "扫码授权需要 python3(解析 server 响应)"

    # server URL:CLI 显式传入直接用;未传则交互(非交互终端直接用默认,防自动化卡死)
    if [[ -z "$SETUP_SERVER" ]]; then
        if [[ -t 0 ]]; then
            read -r -p "万灵服务器地址 [http://localhost:18008]: " input
            SETUP_SERVER="${input:-http://localhost:18008}"
        else
            warn "未传 --server 且非交互终端,使用默认 http://localhost:18008"
            SETUP_SERVER="http://localhost:18008"
        fi
    fi
    SETUP_SERVER="${SETUP_SERVER%/}"

    # 配置目录(写路径):只认 CLI --config-dir,未传则默认 ~/.config/wanling-skills。
    # 刻意忽略 env WANLING_CONFIG_DIR——setup 的运行环境可能被注入该 env(如在插件会话里
    # 执行安装器),写路径若跟随 env 会把技能凭据覆盖进插件配置目录;
    # 读路径(publish.py/upload.py 的 load_config 探测)仍保持 env 优先,不受此影响。
    if [[ -z "$SETUP_CONFIG_DIR" ]]; then
        SETUP_CONFIG_DIR="${HOME}/.config/wanling-skills"
    fi
    local config_file="${SETUP_CONFIG_DIR}/config.json"

    # 护栏:插件专用目录是插件主凭据所在,写技能凭据进去会覆盖/污染,默认拒绝;--force 显式放行
    local cfg_base
    cfg_base="$(basename "$SETUP_CONFIG_DIR")"
    if [[ "$cfg_base" == "opencode-wanling" || "$cfg_base" == "opencode-wanling-prod" ]]; then
        if [[ "$SETUP_FORCE" == true ]]; then
            echo -e "${RED}[FORCE]${NC} 警告: ${SETUP_CONFIG_DIR} 是插件专用配置目录,继续写入可能覆盖插件主凭据!" >&2
        else
            die "拒绝向插件专用目录写入技能凭据: ${SETUP_CONFIG_DIR}
(opencode-wanling / opencode-wanling-prod 是插件主配置,覆盖会破坏插件凭据)
请用 --config-dir=PATH 指定独立目录(默认 ~/.config/wanling-skills);确有需要可加 --force"
        fi
    fi

    info "=== 扫码授权技能凭据（用万灵 APP 扫码,选 Agent → 「授权技能使用」）==="

    # 1. 创建配对票据(空 body)
    info "连接 ${SETUP_SERVER} 生成配对码..."
    local http_code resp ticket_id
    # 响应临时文件:mktemp(0600 且名称不可预测;轮询 completed 时含 secret_key),退出统一清理
    SETUP_TMP_RESP="$(mktemp)" || die "创建临时响应文件失败"
    trap 'rm -f "$SETUP_TMP_RESP"' EXIT
    # set -e 下 curl 连接失败会使整条赋值语句非零、脚本静默终止(000 分支沦为死代码),
    # 用 || http_code=000 兜底,把连接失败导入 000 分支给用户明确报错
    # 超时:connect 5s / 总 15s,半开连接不再挂死
    http_code=$(curl --connect-timeout 5 --max-time 15 -s -o "$SETUP_TMP_RESP" -w '%{http_code}' -X POST \
        "${SETUP_SERVER}/api/pair/tickets" -H "Content-Type: application/json" -d '{}') || http_code=000
    case "$http_code" in
        2*) ;;
        000) die "无法连接 ${SETUP_SERVER}(检查 URL / server 是否运行)" ;;
        *)   die "server 返回错误 ${http_code}: $(cat "$SETUP_TMP_RESP")" ;;
    esac
    resp=$(cat "$SETUP_TMP_RESP")
    ticket_id=$(json_field "$resp" ticket_id)
    [[ -n "$ticket_id" ]] || die "解析配对票据失败: $(echo "$resp" | head -c 200)"

    # 2. 打印二维码 + 备用配对码
    local payload="WLPAIR:${ticket_id}"
    echo ""
    info "请用万灵 APP 扫码(消息 tab → 右上角 + → 扫一扫):"
    echo ""
    print_qr "$payload"
    echo ""
    echo "二维码不可用时,把以下内容生成二维码后扫描:"
    echo "  ${payload}"
    echo ""

    # 3. 轮询(2s 一次,票据 TTL 5min)
    info "等待扫码授权...（最长 5 分钟）"
    local start=$SECONDS elapsed last_status="" status
    local agent_id="" agent_name="" secret_key="" action=""
    while true; do
        elapsed=$((SECONDS - start))
        if (( elapsed > 300 )); then
            die "授权超时(票据 5 分钟过期),请重新运行 --setup"
        fi
        # 超时:connect 5s / 总 15s,轮询遇到半开连接不再挂死
        http_code=$(curl --connect-timeout 5 --max-time 15 -s -o "$SETUP_TMP_RESP" -w '%{http_code}' \
            "${SETUP_SERVER}/api/pair/tickets/${ticket_id}") || http_code=000
        case "$http_code" in
            2*) ;;
            000) die "轮询失败:无法连接 server" ;;
            *)   die "轮询失败:server 返回错误 ${http_code}" ;;
        esac
        resp=$(cat "$SETUP_TMP_RESP")
        status=$(json_field "$resp" status)

        if [[ "$status" == "completed" ]]; then
            action=$(json_field "$resp" action)
            agent_id=$(json_field "$resp" agent_id)
            agent_name=$(json_field "$resp" agent_name)
            secret_key=$(json_field "$resp" secret_key)
            # fail fast:bind 会重置主密钥,绝不能当技能子密钥落盘
            if [[ "$action" != "authorize" ]]; then
                die "票据以「${action:-bind}」方式完成(APP 侧选了绑定而非技能授权)。
技能配置只应持有子密钥,请重新运行 --setup 并在 APP 中选择「授权技能使用」"
            fi
            if [[ -z "$secret_key" || "$secret_key" != wlsk_* ]]; then
                die "凭据异常(缺 secret_key 或非子密钥前缀 wlsk_),请重新运行 --setup"
            fi
            ok "授权成功: Agent「${agent_name}」"
            break
        elif [[ "$status" == "expired" || "$status" == "not_found" ]]; then
            die "配对码已失效(${status}),请重新运行 --setup"
        elif [[ "$status" == "scanned" && "$last_status" != "scanned" ]]; then
            info "已扫码,请在 APP 中选择 Agent 并点「授权技能使用」..."
            last_status="scanned"
        elif [[ "$status" == "pending" && -z "$last_status" ]]; then
            info "等待扫码...(已等 ${elapsed}s)"
            last_status="pending"
        fi
        sleep 2
    done

    # 4. 写 config(0600 创建即生效,不留明文窗口;最小集与 opencode-wanling config 同构)
    mkdir -p "$SETUP_CONFIG_DIR"
    # secret_key 经环境变量传入,避免出现在 /proc/<pid>/cmdline(同机其他用户可读)
    WL_SETUP_SECRET="$secret_key" python3 - "$config_file" "$SETUP_SERVER" "$agent_id" <<'PYEOF'
import json, os, sys
path, server, agent_id = sys.argv[1:4]
secret = os.environ["WL_SETUP_SECRET"]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w", encoding="utf-8") as f:
    json.dump({"serverUrl": server, "agentId": agent_id, "secretKey": secret}, f, indent=2)
    f.write("\n")
os.chmod(path, 0o600)
PYEOF
    ok "凭据已写入 ${config_file}(权限 600)"

    # 5. 成功摘要(不含密钥)
    cat <<EOF

────────────────────────────────────────
  技能授权完成
────────────────────────────────────────
  Agent      ${agent_name} (${agent_id})
  Server     ${SETUP_SERVER}
  Config     ${config_file}
  凭据类型   子密钥(可随时在 APP「我的 → Agent → 授权密钥」吊销)

  新会话/重启 agent 后,publish / send-image 等技能自动使用该凭据。
────────────────────────────────────────
EOF
}

# ─── --setup 单跑(无技能名):只授权不装技能 ────────────────────────────────
if [[ "$SETUP_MODE" == true && ${#REQUEST[@]} -eq 0 ]]; then
    do_setup
    exit 0
fi

# ─── 可用技能集合 ──────────────────────────────────────────────────────────
declare -A MANIFEST_HASH=()   # "name/rel" -> sha256
declare -A ALL_SKILLS=()

if [[ "$IS_LOCAL" == true ]]; then
    for d in "$SCRIPT_DIR"/wanling-*/; do
        if [[ -d "$d" ]]; then
            ALL_SKILLS["$(basename "$d")"]=1
        fi
    done
else
    tmp_all="$(mktemp)"
    curl -fsSL "${RAW_GITEE}/${BRANCH}/skills/manifest.sha256" -o "$tmp_all" 2>/dev/null \
        || curl -fsSL "${RAW_GITHUB}/${BRANCH}/skills/manifest.sha256" -o "$tmp_all" \
        || die "下载 manifest.sha256 失败(gitee/github 均不可达)"
    while read -r hash path; do
        local_name="${path%%/*}"
        ALL_SKILLS["$local_name"]=1
        MANIFEST_HASH["$path"]="$hash"
    done < "$tmp_all"
    rm -f "$tmp_all"
fi
if [[ ${#ALL_SKILLS[@]} -eq 0 ]]; then
    die "未发现任何技能"
fi

# ─── 解析请求(缺省 = 全部) ────────────────────────────────────────────────
if [[ ${#REQUEST[@]} -eq 0 ]]; then
    REQUEST=("${!ALL_SKILLS[@]}")
fi
for name in "${REQUEST[@]}"; do
    if [[ -z "${ALL_SKILLS[$name]:-}" ]]; then
        die "未知技能: $name(可用: ${!ALL_SKILLS[*]})"
    fi
done

# ─── 旧目录检测:非软链的真实副本 = 重复发现风险 ───────────────────────────
legacy_check() {
    local name="$1" dir entry
    local legacy=()
    if [[ -n "$DIR_OVERRIDE" ]]; then
        return 0
    fi
    for dir in "${LEGACY_DIRS[@]}"; do
        entry="${dir}/${name}"
        if [[ ! -e "$entry" && ! -L "$entry" ]]; then
            continue
        fi
        if [[ -L "$entry" ]]; then
            continue    # 已管理软链 = OK
        fi
        legacy+=("$entry")
    done
    if [[ ${#legacy[@]} -eq 0 ]]; then
        return 0
    fi
    if [[ "$MIGRATE" != true ]]; then
        die "发现旧位置真实副本(防重复发现,默认停止):
  ${legacy[*]}
确认后加 --migrate-legacy 迁移(本体收编到 ${CANONICAL}/${name},原位置改软链)"
    fi
    local e
    for e in "${legacy[@]}"; do
        if [[ ! -e "${CANONICAL}/${name}" ]]; then
            mkdir -p "$CANONICAL"
            mv "$e" "${CANONICAL}/${name}"
            warn "已收编旧副本: ${e} → ${CANONICAL}/${name}"
        else
            rm -rf "$e"
            warn "已移除重复旧副本(canonical 已存在): ${e}"
        fi
    done
}

# ─── 载荷落位 ──────────────────────────────────────────────────────────────
install_body_local() {
    local name="$1" tmp="$2"
    cp -a "${SCRIPT_DIR}/${name}"/. "$tmp"/
}

install_body_remote() {
    local name="$1" tmp="$2"
    local path hash out computed
    local files=()
    for path in "${!MANIFEST_HASH[@]}"; do
        if [[ "$path" == "$name/"* ]]; then
            files+=("${path#${name}/}")
        fi
    done
    if [[ ${#files[@]} -eq 0 ]]; then
        die "manifest 中无 ${name} 的文件(分支 ${BRANCH} 的 manifest 是否最新?)"
    fi
    for path in "${files[@]}"; do
        mkdir -p "$tmp/$(dirname "$path")"
        out="$tmp/$path"
        curl -fsSL "${RAW_GITEE}/${BRANCH}/skills/${name}/${path}" -o "$out" 2>/dev/null \
            || curl -fsSL "${RAW_GITHUB}/${BRANCH}/skills/${name}/${path}" -o "$out" \
            || die "下载失败: ${name}/${path}"
        hash="${MANIFEST_HASH[${name}/${path}]}"
        computed="$(sha256sum "$out" | cut -d' ' -f1)"
        if [[ "$computed" != "$hash" ]]; then
            die "sha256 不匹配: ${name}/${path}
  期望 ${hash}
  实得 ${computed}"
        fi
    done
    ok "sha256 校验通过(${#files[@]} 个文件)"
}

install_skill() {
    local name="$1" body tmp target_dir t
    if [[ -n "$DIR_OVERRIDE" ]]; then
        body="$DIR_OVERRIDE"
    else
        legacy_check "$name"
        body="${CANONICAL}/${name}"
    fi
    mkdir -p "$(dirname "$body")"
    tmp="$(mktemp -d "${body}.tmp-XXXXXX")"   # 与目标同盘,保证 mv 原子
    if [[ "$IS_LOCAL" == true ]]; then
        install_body_local "$name" "$tmp"
    else
        install_body_remote "$name" "$tmp"
    fi
    if [[ -e "$body" || -L "$body" ]]; then
        mv "$body" "${body}.old-$$"
    fi
    mv "$tmp" "$body"
    rm -rf "${body}.old-$$"
    ok "本体就位: ${body}"

    if [[ -n "$DIR_OVERRIDE" ]]; then
        return 0
    fi
    IFS=',' read -ra tlist <<< "$TARGETS"
    for t in "${tlist[@]}"; do
        if [[ -z "${TARGET_DIR[$t]:-}" ]]; then
            die "未知 target: $t(可用: ${!TARGET_DIR[*]})"
        fi
        target_dir="${TARGET_DIR[$t]}"
        if [[ -z "$target_dir" ]]; then
            continue    # agents = 本体目录,无软链
        fi
        mkdir -p "$target_dir"
        ln -sfn "$body" "${target_dir}/${name}"
        ok "软链: ${target_dir}/${name} → ${body}"
    done
}

for name in "${REQUEST[@]}"; do
    install_skill "$name"
done

# --setup 与技能名共存:先装技能再扫码授权
if [[ "$SETUP_MODE" == true ]]; then
    do_setup
fi

# 装后凭据检测(与 load_config 探测同序;--setup 刚写的凭据会立即命中)
print_credential_status
echo "完成。新会话/重启 agent 后生效;验证: 让 agent 列出它发现的 skills。"
