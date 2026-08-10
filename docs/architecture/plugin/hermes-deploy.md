# Hermes Plugin 部署运维

> OpenCode Plugin（TypeScript）的部署见 `docs/deployment-source.md` §12，本文件专讲 Hermes Plugin（Python，主流 IM 适配）的部署与运维。

> **插件分发**：插件源码与安装脚本在主仓库 `plugin/` 下，第三方用户用主仓库 raw URL 一键安装（镜像 repo 已废弃）。

## 前置条件

- Hermes Agent 已安装（`hermes --version`）
- Wanling 服务端已有 Agent 账号（`agent_id` + `secret_key`）

## 安装插件（单个 Agent）

**推荐：一键安装（第三方用户，无需主库权限）**

```bash
# 交互式安装（已有 agent_id 和 secret_key）
curl -fsSL https://gitee.com/luoyu318/wanling/raw/main/plugin/install-remote.sh | bash

# 或参数式安装
curl -fsSL https://gitee.com/luoyu318/wanling/raw/main/plugin/install-remote.sh | \
  bash -s -- --server=https://chat.example.com --agent-id=<uuid> --secret-key=<key>

# 或一键注册新 Agent + 安装插件
curl -fsSL https://gitee.com/luoyu318/wanling/raw/main/plugin/install-remote.sh | \
  bash -s -- --register --server=https://chat.example.com \
    --user-token=<user-jwt> --agent-name="我的 Agent"
```

**扫码配对（推荐，无需 user token）**：

```bash
curl -fsSL https://gitee.com/luoyu318/wanling/raw/main/plugin/install-remote.sh | \
  bash -s -- --pair --server=https://chat.example.com
```

终端打印二维码 → 万灵 APP「万灵」tab 右上角 `+` → 扫一扫 → 选已有 Agent 或新建 → hermes 终端自动拿凭据完成配置。

**内部开发：从主库源码安装**

```bash
cd plugin/hermes-plugin && ./install.sh
# 多 profile 场景见 plugin/install-remote.sh --help（--profile / --update / --config）
```

插件安装到 `~/.hermes/plugins/wanling/`，配置写入 `~/.hermes/.env` 和 `~/.hermes/config.yaml`。
install.sh 用 marker 包裹 .env 的 wanling 段（`# >>> wanling-plugin >>>` / `<<<`），清理时按 marker 删，不碰用户其他配置。

## 启动 Gateway

```bash
# systemd user 模式
systemctl --user restart hermes-gateway

# 或前台运行
hermes gateway start
```

验证：

```bash
hermes gateway status              # 看 wanling 是否 connected
tail -f ~/.hermes/logs/gateway.log # 看连接日志
```

## 多 Agent 部署

Hermes 单进程只支持一个 Wanling agent。多 Agent 需要多 Profile —— 每个 Profile 独立运行一个 Gateway 进程。

### Step 1: 创建 Agent

在 Wanling APP 或 API 上创建新 Agent：

```bash
curl -X POST https://chat.example.com/api/agents \
  -H "Authorization: Bearer <user-jwt>" \
  -H "Content-Type: application/json" \
  -d '{"name":"Agent 名称"}'
```

返回 `id`（agent_id）和 `secret_key`。

### Step 2: 创建 Profile

```bash
# 创建 profile 目录
mkdir -p ~/.hermes/profiles/<profile-name>/{plugins,logs,cron}

# 复制基础配置（可选，从主 profile 拷或手动写）
cp ~/.hermes/config.yaml ~/.hermes/profiles/<profile-name>/

# 修改 config.yaml：
#   model: 改成目标模型
#   plugins.enabled: [wanling-platform]
#   加 wanling 段：
#     wanling:
#       enabled: true
#       extra:
#         server_url: https://chat.example.com
#         agent_id: <新-agent-uuid>
#         secret_key: <新-agent-secret-key>
#         home_conv: <conv-id>    # install.sh 通常自动写入;多 profile 手填场景需自己 find_or_create_conv 拿 conv_id

# 复制插件
cp -r ~/.hermes/plugins/wanling ~/.hermes/profiles/<profile-name>/plugins/wanling

# 配置 .env
cat >> ~/.hermes/profiles/<profile-name>/.env <<'EOF'
WANLING_SERVER_URL=https://chat.example.com
WANLING_AGENT_ID=<新-agent-uuid>
WANLING_SECRET_KEY=<新-agent-secret-key>
WANLING_HOME_CONV=<conv-id>
WANLING_ALLOW_ALL_USERS=true
EOF
```

### Step 3: 启动第二个 Gateway

```bash
HERMES_HOME=~/.hermes/profiles/<profile-name> hermes gateway start
```

**生产环境推荐**：每个 Profile 一个 systemd user service：

`~/.config/systemd/user/hermes-gateway-<profile-name>.service`：

```ini
[Unit]
Description=Hermes Gateway - <profile-name>

[Service]
Type=simple
Environment=HERMES_HOME=%h/.hermes/profiles/<profile-name>
ExecStart=%h/.hermes/hermes-agent/hermes_cli/main.py gateway run
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
```

启用：

```bash
systemctl --user enable --now hermes-gateway-<profile-name>
```

## 扫码配对运维要点

- 票据表 `pairing_tickets` 自动清理：server 启动时起后台 goroutine，每 10 分钟删 1 小时前的记录（`internal/pair/cleanup.go`）。**无需手动维护**。
- 限流：`GET /api/pair/tickets/:id` 按 IP 60/min（防 ticket_id 枚举）；`POST /complete` 按 user 10/min。Redis 可用时走 Redis，否则内存降级（`internal/ratelimit/`）。
- 凭据领完即焚：hermes 端第一次 GET completed 拿到 `secret_key` 后，server 立即清空该字段。同 ticket 再查只返 `{status:"completed"}` 不带凭据。
- 排查："配对码已失效"= ticket 过期或已被领过，让用户重新跑 `--pair`。

## 生产环境安全检查

```ini
# 关闭全用户允许，改为白名单
# 删除：WANLING_ALLOW_ALL_USERS=true
# 添加：
WANLING_ALLOWED_USERS=<user-id-1>,<user-id-2>
```
