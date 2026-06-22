#!/bin/bash
# 创建 agent_chat 数据库并执行迁移
# 用法: ./scripts/init_db.sh [host] [port] [user] [password]

set -euo pipefail

DB_HOST="${1:-localhost}"
DB_PORT="${2:-6333}"
DB_USER="${3:-agent}"
DB_PASS="${4:-agent123}"
DB_NAME="agent_chat"

echo "==> 检查数据库连接..."
docker run --rm --network host -e PGPASSWORD="$DB_PASS" postgres:16-alpine \
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres -c "SELECT 1" > /dev/null 2>&1

echo "==> 创建数据库 $DB_NAME（如不存在）..."
docker run --rm --network host -e PGPASSWORD="$DB_PASS" postgres:16-alpine \
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d postgres \
  -c "SELECT 'CREATE DATABASE $DB_NAME' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '$DB_NAME')\\gexec"

echo "==> 执行迁移..."
docker run --rm --network host -e PGPASSWORD="$DB_PASS" -v "$(pwd)/server/migrations:/migrations" postgres:16-alpine \
  psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -f /migrations/001_init.sql

echo "==> 初始化完成"
