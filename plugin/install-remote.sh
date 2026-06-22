#!/usr/bin/env bash
#
# Wanling 插件远程安装引导脚本（两段式安装的第一段）。
#
# 用户用法：
#   curl -fsSL https://gitee.com/luoyu318/wanling-plugin/raw/main/install-remote.sh | \
#     bash -s -- --server=URL --agent-id=ID --secret-key=KEY
#
# 扫码配对（推荐，无需 agent-id/secret-key；必须显式传 --server，管道下无交互输入）：
#   curl -fsSL https://gitee.com/luoyu318/wanling-plugin/raw/main/install-remote.sh | \
#     bash -s -- --pair --server=URL
#
# 多插件场景指定插件名（默认 hermes-plugin）：
#   curl -fsSL .../install-remote.sh | bash -s -- --plugin=openclaw-plugin ...
#
# 做两件事：
#   1. 从镜像 repo 的 raw URL 下载指定插件的文件到临时目录
#   2. exec 调用该插件的 install.sh（透传所有参数），由它完成实际安装
#
# install-remote.sh 本身在镜像 repo 根目录，插件文件在各插件子目录下：
#   镜像 repo 根/
#   ├── install-remote.sh      ← 本文件（总入口）
#   ├── README.md
#   └── hermes-plugin/         ← 插件子目录
#       ├── install.sh
#       ├── adapter.py
#       └── ...
#
# 所有参数透传给插件的 install.sh（--plugin 除外，本脚本消费）。
#
set -euo pipefail

# 镜像 repo 的 raw 根 URL（repo 地址已固化）
RAW_BASE="https://gitee.com/luoyu318/wanling-plugin/raw/main"

# 默认插件名（多插件时用 --plugin=xxx 覆盖）
PLUGIN_NAME="hermes-plugin"

# 颜色
if [[ -t 1 ]]; then
    GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[34m"; NC="\033[0m"
else
    GREEN=""; YELLOW=""; RED=""; BLUE=""; NC=""
fi
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
die()   { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }

# 检查前置依赖
command -v curl >/dev/null 2>&1 || die "未找到 curl，请先安装"

# 解析参数：--plugin 本脚本消费，--dry-run 本脚本也用，其余透传给 install.sh
REMOTE_DRY_RUN="false"
PASSTHROUGH_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --plugin=*)
            PLUGIN_NAME="${arg#*=}"
            ;;
        --dry-run)
            REMOTE_DRY_RUN="true"
            PASSTHROUGH_ARGS+=("$arg")
            ;;
        *)
            PASSTHROUGH_ARGS+=("$arg")
            ;;
    esac
done

# 要下载的插件文件（与各插件 install.sh 的 SCRIPT_DIR 解析对应，需在同一目录）
PLUGIN_FILES=(adapter.py __init__.py plugin.yaml install.sh)

# 创建临时目录，退出时清理
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

info "插件: $PLUGIN_NAME"
info "下载到 $TMP_DIR"
for f in "${PLUGIN_FILES[@]}"; do
    url="$RAW_BASE/$PLUGIN_NAME/$f"
    if [[ "$REMOTE_DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY]${NC} curl -fsSL $url -o $TMP_DIR/$f"
    else
        curl -fsSL "$url" -o "$TMP_DIR/$f" || die "下载失败: $url（检查网络/插件名/镜像 repo 是否可访问）"
        info "已下载: $f"
    fi
done

if [[ "$REMOTE_DRY_RUN" == "true" ]]; then
    echo
    echo -e "${YELLOW}[DRY]${NC} 会调用: $TMP_DIR/install.sh ${PASSTHROUGH_ARGS[*]}"
    echo -e "${YELLOW}[DRY]${NC} install.sh 自身也会 --dry-run，实际不会安装"
    echo -e "${YELLOW}[DRY]${NC} install-remote.sh 在此退出，不实际下载/执行"
    exit 0
fi

# exec 让 install.sh 接管进程，透传所有参数
chmod +x "$TMP_DIR/install.sh"
exec "$TMP_DIR/install.sh" "${PASSTHROUGH_ARGS[@]}"
