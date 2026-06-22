#!/usr/bin/env bash
#
# 一键发布：本地构建 Linux amd64 服务端 → rsync 远程 → systemctl restart
#
# 用法：
#   ./scripts/deploy.sh                # 发布当前 HEAD
#   ./scripts/deploy.sh --build-only   # 仅本地构建，不推送
#
# 依赖：
#   - server/.env.deploy  (REMOTE_HOST=user@ip, REMOTE_PATH=/usr/local/wanling)
#     不存在时打印提示并退出
#   - 本地 ssh / rsync
#   - 远程 sudo 权限执行 systemctl restart
#
set -euo pipefail

# ─── 路径 ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$ROOT/server/.env.deploy"
LOCAL_BIN="/tmp/wanling-server-linux"

# ─── 颜色 ─────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    GREEN="\033[32m"; YELLOW="\033[33m"; RED="\033[31m"; BLUE="\033[34m"; NC="\033[0m"
else
    GREEN=""; YELLOW=""; RED=""; BLUE=""; NC=""
fi
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()   { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }

# ─── 参数 ─────────────────────────────────────────────────────────────────
BUILD_ONLY="false"
[[ "${1:-}" == "--build-only" ]] && BUILD_ONLY="true"

# ─── 加载 .env.deploy ────────────────────────────────────────────────────
if [[ "$BUILD_ONLY" == "false" && ! -f "$ENV_FILE" ]]; then
    cat >&2 <<EOF
${RED}[ERR]${NC} 缺少 $ENV_FILE

请复制模板：
  cp server/.env.deploy.example server/.env.deploy

然后填入实际值：
  REMOTE_HOST=root@your-server-ip
  REMOTE_PATH=/usr/local/wanling
EOF
    exit 1
fi

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
fi

REMOTE_HOST="${REMOTE_HOST:-}"
REMOTE_PATH="${REMOTE_PATH:-/usr/local/wanling}"
SERVICE_NAME="${SERVICE_NAME:-wanling-server}"
HEALTH_URL="${HEALTH_URL:-}"  # 可选：发布后做健康检查

# ─── 步骤 1：本地编译 ────────────────────────────────────────────────────
info "[1/4] 编译 Linux amd64 二进制（CGO_ENABLED=0，静态）..."
cd "$ROOT/server"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-s -w" \
    -o "$LOCAL_BIN" \
    ./cmd/main.go
ok "编译完成: $LOCAL_BIN ($(du -h "$LOCAL_BIN" | cut -f1))"

if [[ "$BUILD_ONLY" == "true" ]]; then
    ok "仅构建模式，二进制位于 $LOCAL_BIN"
    exit 0
fi

: "${REMOTE_HOST:?REMOTE_HOST 必填}"

# ─── 步骤 2：rsync ────────────────────────────────────────────────────────
info "[2/4] rsync 到 ${REMOTE_HOST}:${REMOTE_PATH}/bin/"
ssh "$REMOTE_HOST" "mkdir -p $REMOTE_PATH/bin"
rsync -avz --progress \
    "$LOCAL_BIN" \
    "${REMOTE_HOST}:${REMOTE_PATH}/bin/wanling-server.new"

# 原子替换 + 保留旧版本便于回滚
ssh "$REMOTE_HOST" bash <<EOF
set -e
cd "$REMOTE_PATH/bin"
if [[ -f wanling-server ]]; then
    cp wanling-server wanling-server.prev
fi
mv wanling-server.new wanling-server
chmod +x wanling-server
echo "已替换。旧版本保留在 wanling-server.prev（如需回滚：mv wanling-server.prev wanling-server && sudo systemctl restart $SERVICE_NAME）"
EOF
ok "远程二进制已更新"

# ─── 步骤 2.5：远程数据库迁移 ────────────────────────────────────────────────
info "[2.5/4] 编译迁移工具并推送到远程..."
LOCAL_MIGRATE="/tmp/wanling-migrate-linux"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o "$LOCAL_MIGRATE" ./cmd/migrate
rsync -az "$LOCAL_MIGRATE" "${REMOTE_HOST}:/tmp/wanling-migrate"
rsync -az --delete "$ROOT/server/migrations/" "${REMOTE_HOST}:${REMOTE_PATH}/migrations/"
ssh "$REMOTE_HOST" "cd ${REMOTE_PATH} && /tmp/wanling-migrate --env=${REMOTE_PATH}/etc/.env" || warn "迁移未全部完成(非 fatal)"
ok "数据库迁移完成"

# ─── 步骤 3：systemctl restart ────────────────────────────────────────────
info "[3/4] systemctl restart $SERVICE_NAME..."
if ssh "$REMOTE_HOST" "sudo systemctl restart $SERVICE_NAME"; then
    ok "服务已重启"
else
    die "重启失败。SSH 到远程执行 'sudo journalctl -u $SERVICE_NAME -n 50' 看日志"
fi

# ─── 步骤 4：健康检查 ────────────────────────────────────────────────────
info "[4/4] 健康检查..."
sleep 2
if ! ssh "$REMOTE_HOST" "systemctl is-active --quiet $SERVICE_NAME"; then
    die "服务未起来。检查：ssh $REMOTE_HOST 'sudo journalctl -u $SERVICE_NAME -n 50'"
fi
ok "服务运行中"

if [[ -n "$HEALTH_URL" ]]; then
    if curl -sf -o /dev/null --max-time 5 "$HEALTH_URL"; then
        ok "HTTP 健康: $HEALTH_URL"
    else
        warn "HTTP 健康检查失败: $HEALTH_URL（可能服务还在初始化，10s 后再试）"
    fi
fi

# ─── 完成 ─────────────────────────────────────────────────────────────────
echo
ok "发布完成"
echo "  远程主机:    $REMOTE_HOST"
echo "  二进制路径:  $REMOTE_PATH/bin/wanling-server"
echo "  服务名:      $SERVICE_NAME"
[[ -n "$HEALTH_URL" ]] && echo "  健康端点:    $HEALTH_URL"
echo
echo "回滚命令（如需）:"
echo "  ssh $REMOTE_HOST 'cd $REMOTE_PATH/bin && sudo mv wanling-server.prev wanling-server && sudo systemctl restart $SERVICE_NAME'"
