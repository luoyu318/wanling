# 万灵 Wanling

> **万物有灵,唤灵即应。**

AI Agent 聊天系统。部署一套自己的万灵服务端,在 APP 里管理多个 AI Agent — 像主流 IM 一样跟它们实时对话。

## 名字的由来

「万灵」取自「**万物有灵**」——在我们看来,每一个 AI Agent 都不是冷冰冰的 API,而是一个有性格、有记忆、有专长的"灵":可能是帮你写代码的助手、陪你练口语的外教、替你整理资料的知识库管家。**万灵就是一个让你把这些"灵"装进同一个 IM 里、随时召唤的地方**。

- **万**:想接多少个 Agent 都行,不同模型、不同人设、不同用途,统一管理
- **灵**:每个 Agent 都是一个独立、有灵性的智能体,像 IM 里不同的好友

## 为什么做

- **多 Agent 统一管理**:一个 APP 管理多个 AI Agent(不同模型 / 不同人设 / 不同用途),像 IM 里多个聊天
- **接入多种 Agent 平台**:Hermes、OpenCode CLI 等 Agent 平台用标准 WebSocket 接口接入,服务端不绑定具体 LLM
- **即时通讯体验**:主流 IM 紧凑布局 + 离线推送 + 未读红点 + 多选删除

## 核心特性

- 💬 **IM 风格对话**:未读红点 / 置顶 / 撤回 / 多选删除 / Markdown · LaTeX · 代码块高亮 / 图片画廊长按保存
- 👥 **好友与群组** *(beta)*:按 username 加好友 + 多人 group_chat,群成员管理(邀请 / 踢人 / 退群)
- 🤖 **多 Agent 管理**:一个用户接多个 Agent,独立 secret_key,扫码授权覆盖
- 🔐 **审批卡片**:Agent 执行敏感操作前发卡片,user 按钮决策,5 分钟超时,双端状态同步
- 📲 **离线推送**:Android 前台服务保活 WS,APP 被杀也能收到带头像的富样式通知
- 🔌 **扫码配对**:插件终端 `--pair` → APP 扫码 → 自动配凭据,领完即焚

## 快速试玩

**Docker Compose(推荐)**:

```bash
cp docker-compose.example.yml docker-compose.yml
cp .env.example.docker .env && vim .env   # 填 POSTGRES_PASSWORD / JWT_SECRET
docker compose up -d

docker compose run --rm --entrypoint /app/wanling-admin server add-user --username=alice --password=secret123
```

**或 systemd 源码部署**:见 [docs/deployment-source.md](docs/deployment-source.md)。

## 文档

| 想了解什么 | 看哪 |
|---|---|
| 完整部署(Docker)  | [docs/deployment-docker.md](docs/deployment-docker.md) |
| 完整部署(源码/systemd) | [docs/deployment-source.md](docs/deployment-source.md) |
| 项目全貌 + 架构 + 协议 + 数据库设计 | [CLAUDE.md](CLAUDE.md) |
| Agent 平台接入插件(hermes / opencode) | [plugin/README.md](plugin/README.md) |
| 外部开发者用 SDK 接入 Agent(TS + Python) | [sdk/README.md](sdk/README.md) |
| nginx 反代模板 + certbot 续期 | [deploy/nginx/README.md](deploy/nginx/README.md) |

## License

[MIT](./LICENSE) © 2026 洛羽
