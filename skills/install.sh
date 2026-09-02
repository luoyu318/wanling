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
#   --remote          强制远程模式(默认按 SCRIPT_DIR 自动判定)
#   -h                帮助;技能名缺省 = 全部
#
# 远程(推荐,无需克隆仓库):
#   bash <(curl -fsSL https://gitee.com/luoyu318/wanling/raw/main/skills/install.sh) [选项] [技能名...]
# 本地(仓库内):
#   ./install.sh [选项] [技能名...]
#
# 技能: wanling-miniprogram-publish / wanling-send-image
set -euo pipefail

if [[ -t 1 ]]; then
    GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; NC="\033[0m"
else
    GREEN=""; YELLOW=""; RED=""; NC=""
fi
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }

usage() {
    grep '^#' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' | sed -n '2,$p'
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
REQUEST=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGETS="$2"; shift 2 ;;
        --dir) DIR_OVERRIDE="$2"; shift 2 ;;
        --migrate-legacy) MIGRATE=true; shift ;;
        --gen-manifest) GEN_MANIFEST=true; shift ;;
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
    ( cd "$SCRIPT_DIR" && find wanling-* -type f -not -name 'manifest.sha256' | sort |
      xargs -r sha256sum > manifest.sha256 )
    ok "manifest.sha256 已生成($(( $(wc -l < "$SCRIPT_DIR/manifest.sha256") )) 个文件)"
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
echo "完成。新会话/重启 agent 后生效;验证: 让 agent 列出它发现的 skills。"
