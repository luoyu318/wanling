#!/usr/bin/env bash
#
# 万灵 agent 技能独立安装器(与 opencode-plugin 解耦,按需自主安装)
#
# 用法:
#   ./install.sh              # 列出可用技能
#   ./install.sh all          # 安装全部
#   ./install.sh <name>...    # 安装指定技能
#
# 目标:
#   技能本体 → ~/.opencode/skills/<name>/      (新会话/重启 opencode 生效)
#   技能附带 opencode-plugins/ → ~/.config/opencode/plugins/  (tool 注册挂件)
set -euo pipefail

if [[ -t 1 ]]; then
    GREEN="\033[32m"; RED="\033[31m"; NC="\033[0m"
else
    GREEN=""; RED=""; NC=""
fi
ok()  { echo -e "${GREEN}[OK]${NC} $*"; }
die() { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SKILLS_DST="${HOME}/.opencode/skills"
readonly PLUGINS_DST="${HOME}/.config/opencode/plugins"

available() {
    local dir
    for dir in "$SCRIPT_DIR"/wanling-*/; do
        [[ -d "$dir" ]] && basename "$dir"
    done
}

install_one() {
    local name="$1" src="$SCRIPT_DIR/$1"
    [[ -d "$src" ]] || die "未知技能: $name(可用: $(available | tr '\n' ' '))"
    mkdir -p "$SKILLS_DST/$name"
    cp -a "$src"/. "$SKILLS_DST/$name"/
    if [[ -d "$src/opencode-plugins" ]]; then
        mkdir -p "$PLUGINS_DST"
        cp -a "$src"/opencode-plugins/. "$PLUGINS_DST"/
        ok "$name 已安装(tool 注册挂件 → $PLUGINS_DST)"
    else
        ok "$name 已安装"
    fi
}

main() {
    if [[ $# -eq 0 ]]; then
        echo "用法: $(basename "$0") all | <技能名>..."
        echo "可用技能:"
        available | sed 's/^/  - /'
        exit 0
    fi
    if [[ "$1" == "all" ]]; then
        set -- $(available)
    fi
    local name
    for name in "$@"; do
        install_one "$name"
    done
    echo "新会话/重启 opencode 后生效"
}

main "$@"
