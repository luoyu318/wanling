#!/usr/bin/env bash
# 检测 server/internal/repository 包内不准使用非 Context 变体的 db 调用
# (所有 repo 必须通过 queryExecutor 封装,不允许直接 r.db.QueryRow/Exec/Query)
#
# 用法: ./scripts/check-repo-ctx.sh
# CI 集成: 在 test 步骤前先跑此脚本
set -euo pipefail

cd "$(dirname "$0")/.."

violations=$(grep -rnE '\br\.db\.(QueryRow|Exec|Query)\(' server/internal/repository/ \
  --include='*.go' --exclude='*_test.go' 2>/dev/null || true)

if [[ -n "$violations" ]]; then
  echo "❌ repository 包内禁止使用 r.db.QueryRow/Exec/Query 非 Context 变体(必须走 queryExecutor 封装):"
  echo "$violations"
  echo ""
  echo "修复: 把 r.db.QueryRow(query, args...) 改成 r.queryRow(ctx, query, args...)"
  echo "      把 r.db.Exec(query, args...)      改成 r.exec(ctx, query, args...)"
  echo "      把 r.db.Query(query, args...)     改成 r.query(ctx, query, args...)"
  exit 1
fi

echo "✅ repository 包所有 db 调用均通过 queryExecutor 封装(ctx 强制消费)"
