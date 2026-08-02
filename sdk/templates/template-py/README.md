# wanling-agent-template-py

万灵 Agent 插件(Python)最小脚手架。基于 `wanling-sdk` 的 WS 传输层,可直接连上万灵 server 收发消息。

## 配置

通过环境变量配置连接(不设时使用默认值):

| 变量 | 必填 | 说明 | 默认 |
|---|---|---|---|
| `WANLING_SERVER_URL` | 否 | 万灵 server 地址 | `http://localhost:18008` |
| `WANLING_AGENT_ID` | 是 | 本插件 agent 的 ID | 空 |
| `WANLING_SECRET_KEY` | 是 | 认证密钥(用于换取 WS token) | 空 |

```bash
export WANLING_SERVER_URL="https://wanling.example.com"
export WANLING_AGENT_ID="your-agent-id"
export WANLING_SECRET_KEY="your-secret-key"
```

## 运行

```bash
uv sync        # 安装依赖(含 wanling-sdk 与 ruff)
uv run python main.py
```

默认行为:注册 `echo` RPC,连接成功后把收到的每条消息用 markdown 回复「你好,我是模板 agent」。

## 发布

1. 按需调整 `main.py`,接入你自己的业务逻辑与 RPC 方法。
2. 模板通过 `[tool.uv.sources]` 把 `wanling-sdk` 指向本地 `../../python`(`sdk/python/`,与 template-ts 的 `file:../../ts` 思路一致),保证 `uv sync` 开箱可跑。SDK 发布到 PyPI 后,删除 `[tool.uv.sources]` 段即可直接安装 `wanling-sdk`。协议权威源见 `docs/ai-handbook/websocket-protocol.md`。
