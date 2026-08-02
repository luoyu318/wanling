# Wanling SDK

万灵 AI Agent 传输层 SDK。外部开发者用它把自家 Agent 平台接入万灵 server,成为 APP 里可对话的 Agent 插件。

## 安装

| 语言 | 包 | 命令 |
|---|---|---|
| TypeScript | [`@wanling/sdk`](./ts/README.md) | `npm install @wanling/sdk` |
| Python | [`wanling-sdk`](./python/README.md) | `pip install wanling-sdk` |

## 快速开始

SDK 封装了 WS 连接生命周期 + 协议编解码 + REST,收到消息后回 markdown 只需几行:

```ts
import { WanlingClient } from "@wanling/sdk"

const client = new WanlingClient({ serverUrl, agentId, secretKey })
client.on("message", async (msg) => {
  await client.sendTypedMessage(msg.conversation_id, "markdown", { text: "收到!" })
})
await client.connect()
```

Python 用法见 [python/README.md](./python/README.md),更完整的脚手架见 `templates/template-ts` 与 `templates/template-py`(复制即跑)。

## 能力清单

- **连接**:agent token 换取 + 自动续期、WS 心跳、断线 Resume 补发、指数退避重连
- **事件**:14 项 Dispatch 事件(消息 / 审批 / 会话 / 停止生成 / 状态)
- **发送**:消息 / 流式(op=14)/ 正在输入 / 能力上报(MODELS / SLASH_CATALOG / CAPABILITIES)
- **RPC**:`register`(TS) / `register_method`(Python) 注册,server 经 PluginCall 同步调用
- **REST**:会话创建 / 标题 / session-meta / 卡片消息 / 文件上传下载

SDK 只做传输层,消息路由 / 审批状态机等业务逻辑由开发者自己实现。

## 文档

- 架构与事件映射:docs/architecture/sdk.md
- SDK 开发与发布规则:sdk/CLAUDE.md
- 协议权威源:docs/ai-handbook/websocket-protocol.md
- 发布:`scripts/publish-sdk.sh`(npm publish + uv publish,不进 gitee 镜像 repo)
