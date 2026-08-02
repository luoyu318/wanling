#!/usr/bin/env bash
#
# 把主库 plugin/ 同步到公开镜像 repo（gitee.com/luoyu318/wanling-plugin）。
#
# 用法：
#   # 首次：clone 镜像 repo 到本地（只需一次；SSH/HTTPS 任选）
#   git clone git@gitee.com:luoyu318/wanling-plugin.git ~/wanling-plugin
#   # 或：git clone https://gitee.com/luoyu318/wanling-plugin.git ~/wanling-plugin
#
#   # 每次主库改完插件后同步（整个 plugin/ → 镜像 repo 根）
#   PUBLISH_REPO_DIR=~/wanling-plugin ./scripts/publish-plugin.sh --dry-run   # 先预览
#   PUBLISH_REPO_DIR=~/wanling-plugin ./scripts/publish-plugin.sh             # 实跑
#
# 做的事：
#   1. rsync 整个 plugin/ 到镜像 repo 根（含 install-remote.sh + README.md + 各插件子目录）
#      - hermes-plugin/ 子目录：adapter.py / __init__.py / plugin.yaml / install.sh
#   2. 从 hermes-plugin/plugin.yaml 读 version，作为 git tag
#   3. 在镜像 repo commit（message 含主库来源 hash）+ push + 打 tag
#
# 镜像 repo 必须已 git clone 到本地（PUBLISH_REPO_DIR 指向）。
# 脚本不自动 clone，避免误操作。
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

# ─── 参数 ──────────────────────────────────────────────────────────────────
DRY_RUN="false"
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN="true"

# ─── 路径解析 ──────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGIN_SRC="$ROOT/plugin"

# 镜像 repo 本地路径（必须已 clone）
PUBLISH_REPO_DIR="${PUBLISH_REPO_DIR:-}"
[[ -n "$PUBLISH_REPO_DIR" ]] || die "请设置 PUBLISH_REPO_DIR 指向已 clone 的镜像 repo：
  PUBLISH_REPO_DIR=/path/to/wanling-plugin ./scripts/publish-plugin.sh"
[[ -d "$PUBLISH_REPO_DIR/.git" ]] || die "$PUBLISH_REPO_DIR 不是 git 仓库（缺少 .git）"

# 主插件（用于读 version 打 tag）。多插件时取主插件版本，
# 其他插件跟随发布但不单独打 tag。
PRIMARY_PLUGIN="hermes-plugin"
[[ -d "$PLUGIN_SRC/$PRIMARY_PLUGIN" ]] || die "主插件目录不存在: $PLUGIN_SRC/$PRIMARY_PLUGIN"

# ─── 前置检查 ──────────────────────────────────────────────────────────────
# plugin/ 下每个子目录都应有 plugin.yaml（插件元数据）
for plugin_dir in "$PLUGIN_SRC"/*/; do
    pname=$(basename "$plugin_dir")
    [[ -f "$plugin_dir/plugin.yaml" ]] || die "插件 $pname 缺少 plugin.yaml"
done

# 从主插件 plugin.yaml 读 version（用于 tag）
VERSION=$(grep -E "^version:" "$PLUGIN_SRC/$PRIMARY_PLUGIN/plugin.yaml" | head -1 | awk '{print $2}')
[[ -n "$VERSION" ]] || die "$PRIMARY_PLUGIN/plugin.yaml 未找到 version 字段"

# 主库当前 commit hash（写进镜像 repo 的 commit message，便于追溯）
SRC_HASH=$(cd "$ROOT" && git rev-parse --short HEAD)

info "同步源: $PLUGIN_SRC"
info "镜像 repo: $PUBLISH_REPO_DIR"
info "版本: $VERSION（将作为 tag）"
info "来源 commit: $SRC_HASH"
info "模式: $([[ "$DRY_RUN" == "true" ]] && echo 'DRY-RUN' || echo 'EXECUTE')"
echo

# ─── 复制文件：整个 plugin/ 目录同步到镜像 repo 根 ────────────────────────
# 镜像 repo 根 = 主库 plugin/ 的内容（install-remote.sh + 各插件子目录）
# 用 rsync 保留目录结构，排除：
#   .git/  ← 镜像 repo 自身的 git 仓库，绝不能动（--delete 会删它！）
#   __pycache__/*.pyc  ← Python 缓存
# --delete 清掉镜像 repo 里主库已删的文件（保持镜像与主库 plugin/ 一致）
if ! command -v rsync >/dev/null 2>&1; then
    die "未找到 rsync（同步目录结构需要，请先安装）"
fi

info "同步 plugin/ → 镜像 repo 根（rsync）"
if [[ "$DRY_RUN" == "true" ]]; then
    rsync -av --delete --dry-run \
        --exclude='.git/' \
        --exclude='__pycache__/' --exclude='*.pyc' \
        "$PLUGIN_SRC/" "$PUBLISH_REPO_DIR/"
else
    rsync -a --delete \
        --exclude='.git/' \
        --exclude='__pycache__/' --exclude='*.pyc' \
        "$PLUGIN_SRC/" "$PUBLISH_REPO_DIR/"
    ok "已同步"
fi
echo

# ─── 镜像 repo git 操作 ────────────────────────────────────────────────────
cd "$PUBLISH_REPO_DIR"

# 确保在 main 分支（RAW_BASE URL 用的是 /raw/main/，分支必须是 main）。
# 首次发布到空仓库时，git 默认可能建 master，会导致 raw URL 404。
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[DRY]${NC} git checkout -b main（当前分支: $CURRENT_BRANCH）"
    else
        # 若 main 分支已存在则切过去，否则从当前分支建
        if git show-ref --verify --quiet refs/heads/main; then
            git checkout main
        else
            git checkout -b main
        fi
        # 删旧的 master 分支（本地，远程的让用户在 gitee 网页处理默认分支后删）
        git branch -D master 2>/dev/null || true
        ok "已切到 main 分支"
    fi
fi

info "检查改动..."
if [[ "$DRY_RUN" != "true" ]]; then
    git add -A
    if git diff --cached --quiet; then
        warn "镜像 repo 无改动（内容已是最新），跳过 commit/push"
        exit 0
    fi
fi

info "commit（message 含来源 hash $SRC_HASH）"
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY]${NC} git commit -m \"sync from main ${SRC_HASH}\""
else
    git commit -m "sync from main ${SRC_HASH}"
    ok "已 commit"
fi

info "打 tag v$VERSION"
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY]${NC} git tag v$VERSION"
else
    # tag 已存在则跳过（不强推，version 没变就不打新 tag）
    if git rev-parse -q --verify "v$VERSION" >/dev/null; then
        warn "tag v$VERSION 已存在，跳过（version 未变）"
    else
        git tag "v$VERSION"
        ok "已打 tag v$VERSION"
    fi
fi

info "push"
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[DRY]${NC} git push && git push --tags"
else
    git push
    git push --tags 2>/dev/null || warn "push tags 失败（可能 tag 已在远程）"
    ok "已 push"
fi

echo
if [[ "$DRY_RUN" == "true" ]]; then
    warn "DRY-RUN 完成（未实际执行）"
else
    ok "✓ 发布完成"
    echo
    echo "用户安装命令："
    echo "  # 扫码配对（推荐）"
    echo "  curl -fsSL https://gitee.com/luoyu318/wanling-plugin/raw/main/install-remote.sh | \\"
    echo "    bash -s -- --pair --server=URL"
    echo
    echo "  # 传统安装（已有 agent_id + secret_key）"
    echo "  curl -fsSL https://gitee.com/luoyu318/wanling-plugin/raw/main/install-remote.sh | \\"
    echo "    bash -s -- --server=URL --agent-id=ID --secret-key=KEY"
fi
