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
- 🔐 **审批卡片**：Agent 执行敏感操作（危险命令 / 工具调用 / 文件操作 / 破坏性 slash 命令）前发卡片，user 按钮决策（允许/始终/拒绝），5 分钟超时，双端状态实时同步
- 📲 **离线推送**：Android 前台服务保活 WS，APP 被杀也能收到通知（点击直达会话）
- 🔌 **扫码配对**：hermes 终端 `--pair` → APP 扫码 → 选/建 Agent → 自动配凭据，5 分钟 TTL，领完即焚
- 🌐 **自托管**：服务端、数据库、文件、对话历史全部在自己机器，不经过第三方
- 📱 **跨端**：Linux desktop / Android / iOS，一份 Flutter 代码

## 快速开始（Docker Compose）

最快的方式跑起来整个后端栈（server + PostgreSQL + Redis）：

```bash
# 拷贝 compose 模板（用户改了不污染上游）
cp docker-compose.example.yml docker-compose.yml
cp docker-compose.prod.example.yml docker-compose.prod.yml
# 开发模式改用：cp docker-compose.dev.example.yml docker-compose.dev.yml

# 拷贝并填 .env（用 openssl rand -hex 32 生成 POSTGRES_PASSWORD / JWT_SECRET）
cp .env.example.docker .env
vim .env

# 启动（.env 里 COMPOSE_FILE 已配好模式，直接 up）
docker compose up -d
```

创建用户（万灵没有开放注册 API，用 admin-tool）：

```bash
# Linux / macOS / Windows PowerShell（直接跑）
docker compose run --rm --entrypoint /app/wanling-admin server add-user --username=alice --password=secret123
```

```bash
# Windows Git Bash（必须加 MSYS_NO_PATHCONV=1，否则路径会被破坏）
MSYS_NO_PATHCONV=1 docker compose run --rm \
    --entrypoint /app/wanling-admin server add-user --username=alice --password=secret123
```

详细见 [docs/deployment.md](docs/deployment.md) §1.5。

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
├── app/             # Flutter APP（Linux desktop / Android / iOS）
├── server/          # Go 服务端（Gin + PostgreSQL）
│   ├── cmd/             # 入口（main / migrate / admin-tool）
│   ├── internal/        # 业务代码（handler / hub / repository / ...）
│   └── migrations/      # PostgreSQL migration（001~010）
├── plugin/          # Agent 平台接入插件（hermes-plugin）
├── scripts/         # 运维脚本（部署 / 建库 / 管理）
├── deploy/          # 部署配置模板（nginx 反代示例）
└── docs/            # 文档（部署 / 设计 / 实施）
```

各模块详细职责见 [CLAUDE.md](./CLAUDE.md)。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/deployment.md](./docs/deployment.md) | **完整生产部署**：Docker Compose（§1.5）/ systemd / nginx / 多 Agent / 备份 / 监控 / 故障排查 |
| [CLAUDE.md](./CLAUDE.md) | 项目全貌：架构 / 组件职责 / WebSocket 协议 / 数据库设计 / 安全 / 配置加载 |
| [plugin/README.md](./plugin/README.md) | 插件安装 / 扫码配对 / 多 Profile 部署 |
| [deploy/nginx/README.md](./deploy/nginx/README.md) | nginx 反代模板用法 + certbot 续期 |
| [docs/superpowers/](./docs/superpowers/) | 设计与实施文档（specs / plans，开发私有） |

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
| `scripts/init_db.sh` | 一键建库 + 跑 migrations（不走 Docker 时用） |
| `scripts/deploy.sh` | 本地编译 → rsync → systemctl restart（systemd 路线） |
| `scripts/admin.sh` | 交互式管理菜单（加用户 / 重置密码 / 构建 APK / 重启服务…） |
| `scripts/publish-plugin.sh` | 把 `plugin/` 同步到公开镜像 repo |

## License

本项目暂未指定开源协议，代码公开供学习和自托管使用。如需商用或对协议有疑问，欢迎 issue 联系。
