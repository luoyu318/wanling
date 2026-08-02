# @wanling/sdk

万灵 AI Agent 传输层 SDK(TypeScript)。封装 WS 连接生命周期 + 协议编解码 + REST,供外部开发者接入万灵 server 成为 agent 插件。

## 安装

```bash
npm install @wanling/sdk
```

## 最小示例

```ts
import { WanlingClient, RPCDispatcher } from "@wanling/sdk"

const client = new WanlingClient({
  serverUrl: "https://wanling.example.com",
  agentId: "your-agent-id",
  secretKey: "your-secret-key",
})

const dispatcher = new RPCDispatcher()
dispatcher.register("echo", async (params) => ({ echoed: params }))
client.attachDispatcher(dispatcher)

client.on("connected", () => console.log("connected"))
client.on("message", async (msg) => {
  await client.sendTypedMessage(msg.conversation_id, "markdown", { text: "收到!" })
})
client.on("approval.decided", (payload) => console.log("approval", payload))

await client.connect()
```

## API

- `client.sendMessage(conversationId, content)` / `sendTypedMessage(convId, msgType, data, opts)` / `sendStream` / `sendTyping`
- `client.sendAgentModels` / `sendAgentSlashCatalog` / `sendPluginCapabilities` — 能力上报
- `client.rest.sendCardMessage` / `updateMessageContent` / `createGroupAsAgent` / `updateConversationTitle` / `updateSessionMeta` / `uploadFile` / `downloadFile`
- `RPCDispatcher.register(name, handler, {timeoutHintMs})` — server 侧 RPC 方法

## 事件

见 `src/client.ts` 事件映射表(`message` / `approval.decided` / `conv_update` / `session.meta.update` / `abort` / `typing` / ...)。

协议权威源:[docs/ai-handbook/websocket-protocol.md](../../docs/ai-handbook/websocket-protocol.md)
