#!/bin/bash
# 创建数据库（仅建库，不执行 migration）
# 用法: ./scripts/init_db.sh [host] [port] [user] [password] [db-name]
#
# migration 由 cmd/migrate 统一执行（带版本表追踪），见：
#   cd server && go build -o /tmp/wanling-migrate ./cmd/migrate && /tmp/wanling-migrate --env=.env
#
# 本脚本只负责 CREATE DATABASE（幂等），不碰任何 .sql 文件。

set -euo pipefail

DB_HOST="${1:-localhost}"
DB_PORT="${2:-6333}"
DB_USER="${3:-agent}"
DB_PASS="${4:-agent123}"
DB_NAME="${5:-wanling}"

# 检测系统 psql（不依赖 docker）
if ! command -v psql >/dev/null 2>&1; then
    echo "错误: 未找到 psql 客户端" >&2
    echo "  Debian/Ubuntu: sudo apt install postgresql-client" >&2
    echo "  RHEL/CentOS:   sudo yum install postgresql" >&2
    echo "  macOS:         brew install libpq && export PATH=\"/opt/homebrew/opt/libpq/bin:\$PATH\"" >&2
    exit 1
fi

export PGPASSWORD="$DB_PASS"

echo "==> 检查数据库连接..."
psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "SELECT 1" > /dev/null

echo "==> 创建数据库 $DB_NAME（如不存在）..."
EXISTS=$(psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'")
if [[ "$EXISTS" == "1" ]]; then
    echo "    数据库 $DB_NAME 已存在，跳过创建"
else
    psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres \
        -c "CREATE DATABASE $DB_NAME"
    echo "    数据库 $DB_NAME 已创建"
fi

echo "==> 建库完成"
echo
echo "下一步：执行 migration（首次部署和升级都用这个）："
echo "  cd server"
echo "  go build -o /tmp/wanling-migrate ./cmd/migrate"
echo "  /tmp/wanling-migrate --env=.env"
echo "  # 验证：/tmp/wanling-migrate --env=.env --status"
