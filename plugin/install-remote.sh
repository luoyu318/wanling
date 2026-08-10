#!/usr/bin/env bash
#
# Wanling 插件远程安装引导脚本（两段式安装的第一段）。
#
# 主仓库(镜像 repo 已废弃):插件代码在 gitee.com/luoyu318/wanling 的 plugin/,
# 插件二进制产物(如 opencode-plugin 单文件)在主仓库 Gitee release 附件。
#
# 用户用法：
#   curl -fsSL https://gitee.com/luoyu318/wanling/raw/main/plugin/install-remote.sh | \
#     bash -s -- --plugin=hermes-plugin --server=URL --agent-id=ID --secret-key=KEY
#
# 扫码配对（推荐，无需 agent-id/secret-key；必须显式传 --server，管道下无交互输入）：
#   curl -fsSL https://gitee.com/luoyu318/wanling/raw/main/plugin/install-remote.sh | \
#     bash -s -- --plugin=hermes-plugin --pair --server=URL
#
# opencode 插件（免 NodeJS，下载单文件二进制产物，需指定版本 tag）：
#   curl -fsSL https://gitee.com/luoyu318/wanling/raw/main/plugin/install-remote.sh | \
#     bash -s -- --plugin=opencode-plugin --version=v1.4.0 --pair --server=URL
#
# 做两件事：
#   1. 从主仓库下载插件文件到临时目录
#   2. exec 调用该插件的 install.sh（透传所有参数），由它完成实际安装
#
# 各插件下载内容：
#   hermes-plugin:   hermes-plugin/{adapter.py, __init__.py, plugin.yaml, install.sh}
#   opencode-plugin: opencode-plugin/install.sh + 从主仓库 release 下载单文件二进制
#                    (附件名 wanling-opencode-plugin-<os>-<arch>,由 --version 指定 tag)
#
# 所有参数透传给插件的 install.sh（--plugin / --version 除外，本脚本消费）。
#
set -euo pipefail

# 主仓库 raw 根 URL（repo 地址已固化）
RAW_BASE="https://gitee.com/luoyu318/wanling/raw/main/plugin"
# 主仓库 Gitee release 附件 base URL
RELEASE_BASE="https://gitee.com/luoyu318/wanling/releases/download"

# 默认插件名
PLUGIN_NAME="hermes-plugin"
# opencode 插件二进制产物版本(对应主仓库 release tag,默认最新 v 前缀 tag 由 --version 指定)
BIN_VERSION=""

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

# 解析参数：--plugin / --version 本脚本消费，--dry-run 本脚本也用，其余透传
REMOTE_DRY_RUN="false"
PASSTHROUGH_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --plugin=*)
            PLUGIN_NAME="${arg#*=}"
            ;;
        --version=*)
            BIN_VERSION="${arg#*=}"
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

# 创建临时目录，退出时清理
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ─── 下载插件文件 ──────────────────────────────────────────────────────────
download() {
    local url="$1" out="$2"
    if [[ "$REMOTE_DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY]${NC} curl -fsSL $url -o $out"
        return
    fi
    curl -fsSL "$url" -o "$out" || die "下载失败: $url（检查网络/插件名/版本是否可访问）"
    ok "已下载: $(basename "$out")"
}

info "插件: $PLUGIN_NAME"
info "下载到 $TMP_DIR"

if [[ "$PLUGIN_NAME" == "opencode-plugin" ]]; then
    # opencode 插件:install.sh + 单文件二进制产物(免 NodeJS) + ocwl 快捷命令脚本
    download "$RAW_BASE/opencode-plugin/install.sh" "$TMP_DIR/install.sh"

    # ocwl / ocwl-restart / ocwl-logs 快捷命令(install.sh setup_shell_aliases 从
    # SCRIPT_DIR/scripts 安装到 ~/.local/bin,远程场景需一并下载到同目录)
    mkdir -p "$TMP_DIR/scripts"
    for script in ocwl ocwl-restart ocwl-logs; do
        download "$RAW_BASE/opencode-plugin/scripts/$script" "$TMP_DIR/scripts/$script"
    done

    # 平台推导(uname -m):x86_64 → x64, aarch64 → arm64
    local_arch="$(uname -m)"
    case "$local_arch" in
        x86_64|amd64) arch="x64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) die "不支持的平台: $local_arch（当前仅提供 linux-x64 / linux-arm64 产物）" ;;
    esac
    bin_name="wanling-opencode-plugin-linux-$arch"
    if [[ -z "$BIN_VERSION" ]]; then
        # 未指定版本:从主仓库最新 v* tag 派生(release 名与 tag 一致)
        # 简单方案:用户必须显式传 --version(避免网络探测 tag),否则报错提示
        die "opencode 插件需显式传 --version=<tag>(如 --version=v1.4.0) 指定 release 版本"
    fi
    download "$RELEASE_BASE/$BIN_VERSION/$bin_name" "$TMP_DIR/$bin_name"
    if [[ "$REMOTE_DRY_RUN" != "true" ]]; then
        chmod +x "$TMP_DIR/$bin_name"
    fi
else
    # hermes 插件(默认):4 个文件
    PLUGIN_FILES=(adapter.py __init__.py plugin.yaml install.sh)
    for f in "${PLUGIN_FILES[@]}"; do
        download "$RAW_BASE/hermes-plugin/$f" "$TMP_DIR/$f"
    done
fi

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
