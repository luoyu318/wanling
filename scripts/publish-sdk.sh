#!/usr/bin/env bash
# 发布万灵 SDK:TS 走 npm,Python 走 uv publish。版本独立演进。
# 用法: scripts/publish-sdk.sh [ts|py|all]
set -euo pipefail

TS_DIR="$(cd "$(dirname "$0")/../sdk/ts" && pwd)"
PY_DIR="$(cd "$(dirname "$0")/../sdk/python" && pwd)"
UV="${UV:-/home/k/.local/bin/uv}"

target="${1:-all}"

publish_ts() {
  echo "🔧 [TS] 构建 + 测试 + lint..."
  (cd "$TS_DIR" && npm install --include=dev && npx tsc && npx vitest run && npx eslint src/ test/)
  echo "🚀 [TS] npm publish wanling-sdk..."
  (cd "$TS_DIR" && npm publish)
}

publish_py() {
  echo "🔧 [Py] sync + 测试 + lint..."
  (cd "$PY_DIR" && "$UV" sync && "$UV" run pytest && "$UV" run ruff check wanling_sdk tests)
  echo "🚀 [Py] uv publish wanling-sdk..."
  (cd "$PY_DIR" && "$UV" build && "$UV" publish)
}

case "$target" in
  ts)  publish_ts ;;
  py)  publish_py ;;
  all) publish_ts; publish_py ;;
  *) echo "用法: $0 [ts|py|all]" >&2; exit 1 ;;
esac
