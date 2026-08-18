#!/usr/bin/env bash
#
# 构建 opencode 插件单文件可执行产物(bun compile)。
#
# 背景:opencode 插件是 TypeScript 工程,远程安装需要 NodeJS+npm+tsc。
# 用 bun compile 把源码+依赖打成单文件 ELF,目标机免 NodeJS 环境。
#
# 用法:
#   ./scripts/build-plugin-binaries.sh            # 打当前平台(linux-x64)
#   ./scripts/build-plugin-binaries.sh --out=/path  # 指定输出目录(默认 scripts/../release/)
#
# 产物命名:wanling-opencode-plugin-<os>-<arch>(如 wanling-opencode-plugin-linux-x64)
# 发布:产物不 commit 主仓库 git,等全部修复完整后上传主仓库 Gitee release。
#
# bun 获取:优先用已安装的 ~/.bun/bin/bun,没有则尝试国内镜像(npmmirror)安装。
set -euo pipefail

# ─── 路径 ──────────────────────────────────────────────────────────────────
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_DIR="$ROOT/plugin/opencode-plugin"
OUT_DIR="${ROOT}/release"
TARGET="linux-x64"

# ─── 参数 ──────────────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --out=*) OUT_DIR="${arg#*=}" ;;
        --help|-h)
            echo "用法: $0 [--out=目录]"; exit 0 ;;
        *) echo "未知参数: $arg"; exit 1 ;;
    esac
done

# ─── 找 bun ────────────────────────────────────────────────────────────────
BUN=""
for cand in "${BUN:-}" "$HOME/.bun/bin/bun" "$HOME/.local/bin/bun" "/usr/local/bin/bun"; do
    [[ -x "$cand" ]] && BUN="$cand" && break
done
if [[ -z "$BUN" ]]; then
    if command -v bun &>/dev/null; then
        BUN="$(command -v bun)"
    fi
fi

if [[ -z "$BUN" ]]; then
    echo "[INFO] 未找到 bun,尝试国内镜像安装(npmmirror)..."
    mkdir -p "$HOME/.bun/bin"
    # npmmirror bun 二进制镜像(https://npmmirror.com/mirrors/bun/)
    BUN_VERSION="1.3.14"
    BUN_URL="https://cdn.npmmirror.com/binaries/bun/bun-v${BUN_VERSION}/bun-linux-x64.zip"
    TMP_ZIP="$(mktemp /tmp/bun-XXXXXX.zip)"
    TMP_EX="$(mktemp -d /tmp/bun-XXXXXX)"
    curl -fsSL "$BUN_URL" -o "$TMP_ZIP"
    python3 -c "import zipfile; zipfile.ZipFile('$TMP_ZIP').extractall('$TMP_EX')"
    find "$TMP_EX" -name bun -type f -exec cp {} "$HOME/.bun/bin/bun" \;
    chmod +x "$HOME/.bun/bin/bun"
    rm -rf "$TMP_ZIP" "$TMP_EX"
    BUN="$HOME/.bun/bin/bun"
fi
echo "[INFO] 使用 bun: $BUN ($("$BUN" --version))"

# ─── 前置:依赖已安装(tsc/esbuild 不需要,但 bun compile 需 node_modules) ─────
if [[ ! -d "$PLUGIN_DIR/node_modules" ]]; then
    echo "[INFO] node_modules 缺失,安装依赖..."
    (cd "$PLUGIN_DIR" && npm install --include=dev) || die "npm install 失败"
fi

# ─── 编译 ──────────────────────────────────────────────────────────────────
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/wanling-opencode-plugin-$TARGET"
echo "[INFO] 编译 $TARGET → $OUT ..."
# --compile 单文件可执行;默认打当前平台。
# arm64 产物已停发(v1.4.1 起仅 linux-x64):无 arm 部署场景,省 90MB 附件体积。
# 如需恢复:加 --arm64 参数 + BUN_TARGET_ARGS=(--target=bun-linux-arm64) 交叉编译。
BUN_TARGET_ARGS=()
(cd "$PLUGIN_DIR" && "$BUN" build --compile "${BUN_TARGET_ARGS[@]}" --outfile "$OUT" src/index.ts)
chmod +x "$OUT"

echo "[OK] 产物: $OUT ($(du -h "$OUT" | cut -f1))"
echo "    发布时上传主仓库 Gitee release,install-remote.sh 按平台下载。"
