# 万灵 Wanling

> **万物有灵,唤灵即应。**

一个**自托管的 AI Agent 聊天系统**——像主流 IM 一样,把代码助手、陪练外教、知识库管家……多个 AI 同时装进同一个 APP 里,随时召唤,实时对话。

**自托管 · 不绑定具体 LLM · 标准 WS 协议接入 Agent**

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE)

![消息会话列表](docs/images/消息会话列表主界面_small.jpg)

---

## 这是什么

现在市面上每个 AI 都是孤岛:写代码用一个、练口语用一个、查资料用一个,开一堆 APP、切一堆账号。

万灵让你**只装一个 APP,像添加好友一样把不同 AI Agent 加进来**,统一对话、统一管理:

- **万**:想接多少个 Agent 都行,不同模型、不同人设、不同用途,统一管理
- **灵**:每个 Agent 都是一个独立、有灵性的智能体,像 IM 里不同的好友

## 核心特性

**💬 对话体验**
IM 风格对话界面,流式输出、未读红点、置顶、撤回、多选删除、Markdown · LaTeX · 代码高亮、图片画廊长按保存。

**🤖 Agent 管理**
一个用户接多个 Agent,各自独立 secret_key;扫码授权即配对,过期自动失效。

**🔐 安全治理**
Agent 执行敏感操作(危险命令 / 工具调用 / 文件访问)前,先发**审批卡片**给你决策——APP 与终端双端状态同步。

**🔌 开放生态**
Agent 平台走标准 WebSocket 协议接入,服务端不绑定具体 LLM;内置 hermes / OpenCode 插件,双语言 SDK(TS + Python)让外部开发者一键接入自家 Agent。

## 一览

| 审批通知 | 问答 | 安全审批 | OpenCode 项目 | OpenCode 会话列表 | 文件预览 | 聊天执行中 | 命令面板 |
|---|---|---|---|---|---|---|---|
| <img src="docs/images/权限审批通知_small.jpg" width="170" alt="权限审批通知"/> | <img src="docs/images/问答抽屉_small.jpg" width="170" alt="问答抽屉"/> | <img src="docs/images/权限审批抽屉_small.jpg" width="170" alt="权限审批抽屉"/> | <img src="docs/images/opencode项目列表_small.jpg" width="170" alt="opencode 项目列表"/> | <img src="docs/images/opencode会话列表_small.jpg" width="170" alt="opencode 会话列表"/> | <img src="docs/images/文件资源管理器-文件预览_small.jpg" width="170" alt="文件预览"/> | <img src="docs/images/聊天页面执行中_small.jpg" width="170" alt="聊天执行中"/> | <img src="docs/images/命令面板_small.jpg" width="170" alt="命令面板"/> |

## 架构

```mermaid
graph LR
    APP[Flutter APP] <--> SERVER[Wanling Server]
    SERVER <--> PLUGIN[Agent Plugin hermes opencode]
    SERVER <--> DB[(PostgreSQL)]
    DEV[外部开发者] --> SDK[SDK TS Python]
    SDK --> SERVER
```

- 服务端仅做消息转发与用户/Agent 管理,不含 Agent 适配层
- 详细架构、协议、数据库设计见 [CLAUDE.md](CLAUDE.md)

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
