# 万灵 Wanling

> **万物有灵，唤灵即应。**

自托管的 AI Agent 聊天系统。你部署一套自己的万灵服务端，在 APP 里管理多个 AI Agent。

## 名字的由来

「万灵」取自「**万物有灵**」——在我们看来，每一个 AI Agent 都不是冷冰冰的 API，而是一个有性格、有记忆、有专长的"灵"：可能是帮你写代码的助手、陪你练口语的外教、替你整理资料的知识库管家。**万灵就是一个让你把这些"灵"装进同一个 IM 里、随时召唤的地方**。

- **万**：想接多少个 Agent 都行，不同模型、不同人设、不同用途，统一管理
- **灵**：每个 Agent 都是一个独立、有灵性的智能体，像 IM 里不同的好友
- **Wanling**：拼音直译，海外用户也能念出来，不刻意造英文新词

## 项目背景

### 关于本项目

万灵是一个用 **AI 辅助开发**的个人项目，代码、设计文档、部署流程都完整公开在这里，欢迎自由使用。

作为一个个人维护的开源项目，精力相对有限 —— 你提交的 issue 和 PR 我都会认真看，但**回复可能不会很及时**，还请多包涵 😊

抛砖引玉，相信你有更好的想法或者设计，**非常欢迎直接 fork 去二开**，万灵本来就是为自托管场景设计的，改起来没什么负担。如果二开过程中做出了通用的改进，也欢迎提 PR 回馈，我会抽时间 review 合并。


### 为什么做

市面上 AI 对话产品很多，但要么是把你的对话数据托管在别人服务器（数据隐私），要么是只面向开发者的纯 API（普通用户用不了）。我们想要一个：

- **数据自己掌控**：服务端、数据库、对话历史都在自己的机器上，不经过任何第三方
- **多 Agent 统一管理**：一个 APP 管理多个 AI Agent（不同模型 / 不同人设 / 不同用途），像 IM 里多个聊天
- **接入任意 Hermes Agent**：Agent 平台用标准 WebSocket 接口接入，服务端不绑定具体 LLM
- **即时通讯体验**：主流 IM 紧凑布局 + 离线推送 + 未读红点 + 多选删除。

### 设计取舍

| 决策 | 选择 | 理由 |
|---|---|---|
| 服务端职责 | **只转发不跑模型** | 服务端是协议中介，不接管 Agent 适配层。LLM 在 Agent 平台跑，服务端零 GPU 负担 |
| Agent 接入 | **标准 WebSocket 协议** | hermes 已实现参考插件 |
| 鉴权 | **统一 JWT，role 区分** | user 和 agent 共用一套 JWT，role 字段区分身份，简单可扩展 |
| 消息可靠性 | **WS + OpResume 补发** | 断线后客户端携带最后 seq，服务端补发缺失 Dispatch，消息不丢 |
| Redis | **可选增强** | 在线状态 / 多实例限流用 Redis，单机部署可不装，自动降级 |
| APP 端 | **Flutter 单代码库** | 一份代码出 Linux desktop / Android / iOS，避免多端分裂 |
| 配对方式 | **扫码授权优先** | hermes 终端 `--pair` 生成二维码，APP 扫码选 Agent 自动下发凭据，替代手粘 user token |

### 架构

```
用户 APP (Flutter, Linux desktop / Android / iOS)
    ↕ WebSocket + HTTP REST (JWT 鉴权)
Nginx / Caddy (反向代理 + TLS 终止)
    ↕
Go 服务端 (:18008, PostgreSQL + Redis 可选)
    ↕ WebSocket (JWT: role=agent)
Hermes Gateway + Wanling 插件 (每个 agent 一个进程)
    ↕
AI 平台 (Hermes Agent, 跑实际 LLM 推理)
```

**三方角色**：
- **万灵服务端**：消息路由 + 用户/Agent 管理 + 文件存储 + 推送。不跑模型
- **万灵 APP**：用户端 IM 客户端
- **Hermes Agent 平台**：跑 LLM 推理的外部平台，通过标准 WebSocket 协议接入

## 核心特性

- 💬 **IM 风格对话**：未读红点、置顶、消息多选删除、撤回、长按菜单、Markdown / LaTeX / 代码块高亮 / 图片 / 文件渲染
- 🤖 **多 Agent 管理**：一个用户管理多个 Agent，独立 secret_key，支持扫码授权覆盖
- 📲 **离线推送**：Android 前台服务保活 WS，APP 被杀也能收到通知（点击直达会话）
- 🔌 **扫码配对**：hermes 终端 `--pair` → APP 扫码 → 选/建 Agent → 自动配凭据，5 分钟 TTL，领完即焚
- 🔐 **自托管**：服务端、数据库、文件、对话历史全部在自己机器，不经过第三方
- 🌐 **跨端**：Linux desktop / Android / iOS，一份 Flutter 代码

## 技术栈

| 层 | 技术 |
|---|---|
| 服务端 | Go 1.25 · Gin · gorilla/websocket · lib/pq · redis/go-redis · testcontainers-go |
| 数据库 | PostgreSQL 15+ |
| 缓存（可选） | Redis 7+ |
| APP | Flutter 3.44+ · Dio · go_router · Riverpod · mobile_scanner · flutter_local_notifications |
| 插件 | Python 3.11+ · WebSocket · qrencode |
| 反向代理 | Nginx / Caddy |

## 目录结构

```
.
├── app/                     # Flutter APP（Linux desktop / Android / iOS）
│   └── lib/
│       ├── pages/           # 页面（登录/消息/Agent/聊天/个人/扫码配对…）
│       ├── providers/       # Riverpod 状态管理
│       ├── services/        # dio / websocket / 后台服务 / 通知
│       ├── rendering/       # 消息内容渲染器（注册表模式，可扩展）
│       └── widgets/         # 复用组件
├── server/                  # Go 服务端（Gin + PostgreSQL）
│   ├── cmd/                 # 入口
│   ├── internal/
│   │   ├── handler/         # HTTP Handler
│   │   ├── hub/             # WebSocket 连接管理器
│   │   ├── message/         # 消息处理器（事务保证原子性）
│   │   ├── repository/      # 数据库操作层（禁止 mock，全连真 PG）
│   │   ├── auth/            # JWT 认证
│   │   ├── ratelimit/       # 限流中间件（Redis / 内存降级）
│   │   ├── pair/            # 扫码配对票据清理 goroutine
│   │   ├── presence/        # 在线状态（Redis）
│   │   ├── storage/         # 文件存储（本地 + MinIO 预留）
│   │   ├── config/          # 环境变量配置加载
│   │   └── model/           # 数据模型
│   └── migrations/          # PostgreSQL migration（001~007）
├── plugin/                  # 插件总目录
│   ├── hermes-plugin/       # hermes 接入插件
│   └── install-remote.sh    # 远程安装引导
├── scripts/                 # 运维脚本
│   ├── init_db.sh           # 一键建库 + 跑 migrations
│   ├── deploy.sh            # 编译 → rsync → systemctl restart
│   ├── admin.sh             # 交互式管理菜单
│   └── publish-plugin.sh    # 同步 plugin/ 到公开镜像 repo
└── docs/
    ├── deployment.md        # 完整生产部署文档
    └── superpowers/         # 设计与实施文档
```

## 部署流程

整个系统由 4 个独立部分组成，按依赖顺序部署：

```
PostgreSQL/Redis  →  万灵服务端  →  万灵 APP  →  Hermes 插件
   （基础设施）        （消息中介）      （用户端）      （Agent 接入）
```

### 环境要求

| 组件 | 版本 |
|---|---|
| Go | >= 1.25 |
| Flutter | >= 3.44 |
| PostgreSQL | >= 15 |
| Redis（可选） | >= 7 |
| Python（Hermes 插件） | >= 3.11 |

### 第 1 步：基础设施（PostgreSQL + Redis）

**PostgreSQL**（必填）：

```bash
# 创建数据库和用户
sudo -u postgres psql <<EOF
CREATE USER agent WITH PASSWORD '<strong-password>';
CREATE DATABASE wanling OWNER agent;
EOF

# 跑 migrations（001~007）
for m in server/migrations/00*.sql; do
  psql -U agent -d wanling -h localhost -f "$m"
done

# 或一键脚本
./scripts/init_db.sh
```

migration 清单：
- `001_init.sql` — 基础表（users / agents / conversations / messages / files）
- `002_conversation_last_message.sql` — IM 列表 last_message_content 缓存
- `003_unread_count.sql` — 未读数 + 已读回执
- `004_pin_hide.sql` — 置顶 + 软删除
- `005_profile_fields.sql` — 个人资料扩展
- `006_message_soft_delete.sql` — 消息软删除
- `007_pairing_tickets.sql` — 扫码配对票据表（5min TTL，领完即焚）

**Redis**（可选，用于在线状态 + 多实例限流）：

```bash
docker run -d --name wanling-redis -p 6379:6379 redis:7-alpine
# 或
systemctl enable --now redis
```

> 💡 不装 Redis 也能跑：限流降级为单进程内存计数，在线状态恒返回离线。

### 第 2 步：部署服务端

**配置环境变量**：

```bash
cp server/.env.example server/.env
```

编辑 `server/.env`，关键字段：

```ini
SERVER_PORT=18008

DB_HOST=localhost
DB_PORT=5432
DB_USER=agent
DB_PASSWORD=<你的数据库密码>
DB_NAME=wanling
DB_SSLMODE=disable

REDIS_HOST=localhost        # 留空则禁用 Redis，自动降级
REDIS_PORT=6379

JWT_SECRET=<openssl rand -hex 32 生成>
STORAGE_PATH=/var/lib/wanling/uploads
CORS_ALLOWED_ORIGINS=*      # 生产建议改成具体域名
```

生成 JWT 密钥：

```bash
openssl rand -hex 32
```

**本地开发**（热调试）：

```bash
cd server
go run cmd/main.go           # 监听 :18008
```

**生产部署**（systemd 服务）：

```bash
# 编译
cd server
CGO_ENABLED=0 go build -ldflags="-s -w" -o wanling-server ./cmd/main.go

# 或用现成脚本：编译 → rsync 到生产 → systemctl restart
./scripts/deploy.sh
```

创建 systemd 服务 `/etc/systemd/system/wanling-server.service`：

```ini
[Unit]
Description=Wanling Server
After=network.target postgresql.service redis.service

[Service]
Type=simple
User=wanling
WorkingDirectory=/usr/local/wanling
EnvironmentFile=/usr/local/wanling/etc/.env
ExecStart=/usr/local/wanling/bin/wanling-server
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
```

启动并验证：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now wanling-server
curl http://localhost:18008/health    # OK
```

**Nginx 反向代理 + TLS**（生产必备，APP 走 HTTPS）：

```nginx
server {
    listen 443 ssl http2;
    server_name chat.example.com;

    ssl_certificate     /etc/ssl/chat.example.com.pem;
    ssl_certificate_key /etc/ssl/chat.example.com.key;

    # WebSocket 长连接
    location /ws {
        proxy_pass http://127.0.0.1:18008;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 3600s;
    }

    # HTTP API（含文件上传，记得 client_max_body_size）
    location / {
        proxy_pass http://127.0.0.1:18008;
        client_max_body_size 20m;
    }
}
```

### 第 3 步：构建 APP

```bash
cd app

# 国内必须设镜像源
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn

flutter pub get

# Linux desktop
flutter build linux --release
# 输出：build/linux/x64/release/bundle/

# Android APK
flutter build apk --release
# 输出：build/app/outputs/flutter-apk/app-release.apk

# iOS（需 macOS + Xcode）
flutter build ios --release
```

装到设备后，APP 首次启动会让你填服务器地址，填第 2 步的 HTTPS 域名（如 `https://chat.example.com`）。

> 📌 若服务端没上 TLS（开发环境用 HTTP），Android 需在 `network_security_config.xml` 配 `cleartextTrafficPermitted`。

### 第 4 步：接入 Hermes Agent

Agent 平台通过插件接入万灵服务端。两种方式：

**方式一：扫码配对（推荐，无需 user token）**

hermes 终端跑：

```bash
curl -fsSL https://gitee.com/luoyu318/wanling-plugin/raw/main/install-remote.sh | \
  bash -s -- --pair --server=https://chat.example.com
```

终端打印二维码 → 万灵 APP「万灵」tab 右上角 `+` → 扫一扫 → 选已有 Agent 或新建 → hermes 终端自动拿凭据完成配置。

**方式二：手动配凭据**

先在 APP 或 API 创建 Agent，拿到 `agent_id` + `secret_key`：

```bash
curl -X POST https://chat.example.com/api/agents \
  -H "Authorization: Bearer <user-jwt>" \
  -H "Content-Type: application/json" \
  -d '{"name":"我的 Agent"}'
```

然后 hermes 终端：

```bash
curl -fsSL https://gitee.com/luoyu318/wanling-plugin/raw/main/install-remote.sh | \
  bash -s -- --server=https://chat.example.com \
    --agent-id=<uuid> --secret-key=<key>
```

装完重启 hermes gateway：

```bash
hermes gateway restart
hermes gateway status    # 看 wanling 是否 connected
```

详见 [`plugin/README.md`](./plugin/README.md) 和 [`docs/deployment.md`](./docs/deployment.md) 第 6 节。

## 开发

### 测试

```bash
# 服务端（testcontainers 起 PG 容器，禁止 mock DB，需 docker）
cd server && go test ./...

# APP
cd app && flutter test
```

### 运维脚本

| 脚本 | 用途 |
|---|---|
| `scripts/init_db.sh` | 一键建库 + 跑 migrations |
| `scripts/deploy.sh` | 本地编译 → rsync → systemctl restart |
| `scripts/admin.sh` | 交互式管理菜单（加用户 / 重置密码 / 构建 APK / 重启服务…） |
| `scripts/publish-plugin.sh` | 把 `plugin/` 同步到公开镜像 repo（`gitee.com/luoyu318/wanling-plugin`） |

### 配置说明

服务端配置走环境变量或 `server/.env`，加载逻辑在 `internal/config/config.go`。完整字段见 `server/.env.example`。必填项（`JWT_SECRET`、`DB_PASSWORD`）缺失直接报错退出（fail fast）。

## 文档

- [`CLAUDE.md`](./CLAUDE.md) — 项目全貌：架构 / 组件 / WebSocket 协议 / 数据库 / 安全
- [`docs/deployment.md`](./docs/deployment.md) — **完整生产部署文档**（含多 Agent 部署、备份、监控、故障排查）
- [`plugin/README.md`](./plugin/README.md) — 插件安装与扫码配对
- [`docs/superpowers/`](./docs/superpowers/) — 设计与实施文档（specs / plans）

## WebSocket 协议

基于 Opcode 的二进制协议（参考主流 IM Bot 架构）：

| Opcode | 名称 | 方向 | 用途 |
|---|---|---|---|
| 0 | Dispatch | S→C | 事件推送（MESSAGE_CREATE / MESSAGE_DELETE / AGENT_ONLINE / TYPING_START） |
| 1 | Heartbeat | C→S | 心跳 |
| 2 | Identify | C→S | 鉴权（携带 JWT） |
| 6 | Resume | C→S | 断线恢复，携带最后 seq |
| 7 | Reconnect | S→C | 服务端要求重连 |
| 10 | Hello | S→C | 连接建立，含心跳间隔 |
| 11 | HeartbeatACK | S→C | 心跳回应 |

连接流程：WS 建立 → Hello → Identify → 双向消息 → 定期 Heartbeat。断线用 OpResume 携带最后 seq，服务端补发缺失的 Dispatch，消息不丢。

## License

本项目暂未指定开源协议，代码公开供学习和自托管使用。如需商用或对协议有疑问，欢迎 issue 联系。
