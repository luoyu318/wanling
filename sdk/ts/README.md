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

## 高层封装示例

```ts
// 审批/提问:发卡并等待用户决策(Promise 决议)
const result = await client.approvals.ask(convId, {
  cardType: "question", title: "选择部署环境", sessionKey,
  options: [{ id: "prod", label: "生产" }, { id: "staging", label: "预发" }],
})
if (result.state === "approved") console.log(result.answers)

// 聚合卡:一次问答一张卡
const card = client.aggregate(convId)
await card.append("markdown", { text: "处理中..." })
await card.finish({ durationMs: 1200 })

// 流式输出:累积全量快照,节流推送
const s = client.stream(convId)
s.push("生成中...")
await s.end("最终全文")
```

## API

- `client.sendMessage(conversationId, content)` / `sendTypedMessage(convId, msgType, data, opts)` / `sendStream` / `sendTyping`
- `client.sendAgentModels` / `sendAgentSlashCatalog` / `sendAgentModes` / `sendAgentPresets` / `sendPluginCapabilities` — 能力上报
- `client.approvals.ask(convId, opts)` / `resync()` — 审批/提问高层封装(AskOptions 含 cardType/title/options/multiSelect/previewLanguage/meta/allowPattern/confirmId)
- `client.aggregate(convId, opts)` — 聚合卡(`append`/`update`/`finish`/`interrupt`,degradedSelfHeal/recallEmpty)
- `client.stream(convId, opts)` — 流式会话(`push`/`end`/`abort`,aggregate 定位/throttleMs)
- `client.sessionMapping(path)` — session↔conversation 映射(`ensureConversation`/`bySession`/`byConversation`)
- `client.rest.sendCardMessage` / `updateMessageContent` / `createApproval` / `getApproval` / `listAgentConversations` / `listAgentSessions` / `createGroupAsAgent` / `updateConversationTitle` / `updateSessionMeta` / `uploadFile` / `downloadFile`
- `RPCDispatcher.register(name, handler, {timeoutHintMs})` — server 侧 RPC 方法

## 事件

见 `src/client.ts` 事件映射表(`message` / `approval.decided` / `conv_update` / `session.meta.update` / `abort` / `typing` / ...)。

协议权威源:[docs/ai-handbook/websocket-protocol.md](../../docs/ai-handbook/websocket-protocol.md)
