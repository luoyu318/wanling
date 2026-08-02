# wanling-agent-template-ts

万灵 Agent 插件(TypeScript)最小脚手架。基于 `@wanling/sdk` 的 WS 传输层,可直接连上万灵 server 收发消息。

## 配置

通过环境变量配置连接(不设时使用默认值):

| 变量 | 必填 | 说明 | 默认 |
|---|---|---|---|
| `WANLING_SERVER_URL` | 否 | 万灵 server 地址 | `http://localhost:18008` |
| `WANLING_AGENT_ID` | 是 | 本插件 agent 的 ID | 空 |
| `WANLING_SECRET_KEY` | 是 | 认证密钥(用于换取 WS token) | 空 |

可复制 `.env.example` 或直接在 shell 里导出:

```bash
export WANLING_SERVER_URL="https://wanling.example.com"
export WANLING_AGENT_ID="your-agent-id"
export WANLING_SECRET_KEY="your-secret-key"
```

## 运行

```bash
npm install
npm run dev        # tsx 直接跑 src/index.ts
```

构建并生产运行:

```bash
npm run build
npm start          # node dist/index.js
```

默认行为:注册 `echo` RPC,连接成功后把收到的每条消息用 markdown 回复「你好,我是模板 agent」。

## 发布

1. 按需调整 `src/index.ts`,接入你自己的业务逻辑与 RPC 方法。
2. 构建产物在 `dist/`,发布时随包带上(或按插件平台要求上传)。
3. SDK 发布到 npm 后,把 package.json 的 `@wanling/sdk` 依赖从 `file:../../ts` 改回 `^0.1.0` 即可独立安装。协议权威源见 `docs/ai-handbook/websocket-protocol.md`。
