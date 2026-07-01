#!/bin/bash
# 在 sdk/ 下建 venv 并安装 wanling-sdk + wanling-mcp（editable）
# 用法: ./sdk/setup.sh
#
# 跨机器一键部署：clone 仓库后跑一次即可让 .mcp.json 指向的 ./sdk/.venv/bin/python 可用

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 1. 检查 uv
if ! command -v uv >/dev/null 2>&1; then
    echo "==> 错误: 未找到 uv"
    echo "    请先安装 uv: https://docs.astral.sh/uv/getting-started/installation/"
    exit 1
fi
echo "==> uv 版本: $(uv --version)"

# 2. 建 venv（已存在则复用）
echo "==> 创建 venv (.venv)..."
uv venv

# 3. 装 wanling-sdk + wanling-mcp（editable，按依赖顺序）
echo "==> 安装 wanling-sdk (editable)..."
uv pip install -e python

echo "==> 安装 wanling-mcp (editable)..."
uv pip install -e mcp

# 4. 验证 import
echo "==> 验证 import..."
./.venv/bin/python -c "import wanling; import wanling_mcp; print('import OK')"

echo ""
echo "==> 完成"
echo "    venv 路径: $SCRIPT_DIR/.venv"
echo "    下一步: 在 Claude Code 里 /mcp → Reconnect wanling"
