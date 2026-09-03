#!/usr/bin/env bash
#
# opencode-plugin 卸载脚本
#
set -euo pipefail

if [[ -t 1 ]]; then
    RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; BLUE="\033[34m"; NC="\033[0m"
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; NC=""
fi
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }

readonly CONFIG_DIR="${HOME}/.config/opencode-wanling"
readonly SERVICE_NAME="opencode-wanling"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "将卸载 opencode-plugin："
echo "  - systemd user service: ${SERVICE_NAME}"
echo "  - 配置目录: ${CONFIG_DIR}"
echo "  - node_modules: ${SCRIPT_DIR}/node_modules"
echo ""

read -r -p "确认卸载？[y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { info "已取消"; exit 0; }

# 1. 停用 systemd service
if systemctl --user is-active --quiet "${SERVICE_NAME}" 2>/dev/null; then
    systemctl --user stop "${SERVICE_NAME}"
    ok "服务已停止"
fi
if systemctl --user is-enabled --quiet "${SERVICE_NAME}" 2>/dev/null; then
    systemctl --user disable "${SERVICE_NAME}"
    ok "开机自启已取消"
fi

# 2. 删 service 文件
service_file="${HOME}/.config/systemd/user/${SERVICE_NAME}.service"
if [[ -f "$service_file" ]]; then
    rm -f "$service_file"
    systemctl --user daemon-reload
    ok "systemd service 文件已删除"
fi

# 3. 删配置
if [[ -d "$CONFIG_DIR" ]]; then
    rm -rf "$CONFIG_DIR"
    ok "配置目录已删除"
fi

# 4. 删 node_modules
if [[ -d "${SCRIPT_DIR}/node_modules" ]]; then
    rm -rf "${SCRIPT_DIR}/node_modules"
    ok "node_modules 已删除"
fi

# agent 技能与插件解耦,卸载插件不删用户自主安装的技能
if compgen -G "${HOME}/.opencode/skills/wanling-*" > /dev/null; then
    info "agent 技能(~/.opencode/skills/wanling-*)为独立安装,未随插件卸载;不再需要时可手动删除"
fi

echo ""
ok "卸载完成"
