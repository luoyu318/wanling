# wanling-sdk

万灵 AI Agent 传输层 SDK(Python)。封装 WS 连接生命周期 + 协议编解码 + REST,供外部开发者接入万灵 server 成为 agent 插件。

## 安装

PyPI 消费者:

```bash
pip install wanling-sdk
```

或用 uv:

```bash
uv add wanling-sdk
```

> 仓库开发用 `uv sync`(安装本仓库 `pyproject.toml` 依赖),仅维护 SDK 源码时使用。

## 最小示例

```python
import asyncio

from wanling_sdk import WanlingClient

SERVER_URL = "https://wanling.example.com"
AGENT_ID = "your-agent-id"
SECRET_KEY = "your-secret-key"


async def main() -> None:
    client = WanlingClient(SERVER_URL, AGENT_ID, SECRET_KEY)
    client.on("connected", lambda: print("connected"))

    async def on_message(msg: dict) -> None:
        print(f"message {msg['conversation_id']}: {msg['content']}")
        await client.send_typed(msg["conversation_id"], "markdown", {"text": "你好,我是 wanling agent"})

    client.on("message", on_message)
    client.on("approval.decided", lambda payload: print("approval", payload))
    client.register_method("echo", lambda params: {"echoed": params})

    await client.start()
    try:
        await asyncio.Future()  # 常驻运行,靠内部任务循环自动重连
    finally:
        await client.stop()


if __name__ == "__main__":
    asyncio.run(main())
```

## 高层封装示例

```python
# 审批/提问:发卡并等待用户决策(await 决议)
result = await client.approvals.ask(conv_id, {
    "card_type": "question", "title": "选择部署环境", "session_key": session_key,
    "options": [{"id": "prod", "label": "生产"}, {"id": "staging", "label": "预发"}],
})
if result["state"] == "approved":
    print(result["answers"])

# 聚合卡:一次问答一张卡
card = client.aggregate(conv_id)
await card.append("markdown", {"text": "处理中..."})
await card.finish({"duration_ms": 1200})

# 流式输出:累积全量快照,节流推送
s = client.stream(conv_id)
s.push("生成中...")
await s.end("最终全文")
```

## API

- `client.send(conversation_id, content)` / `send_typed(conversation_id, msg_type, data, *, silent=False, parent_msg_id=None, root_msg_id=None)` / `send_stream` / `send_typing` — 消息发送
- `client.report_models(models)` / `report_slash_catalog(commands)` / `report_modes(modes)` / `report_presets(presets)` / `report_capabilities(methods)` — 能力上报
- `client.approvals.ask(conv_id, opts)` / `resync()` — 审批/提问高层封装(opts 含 card_type/title/options/multi_select/preview_language/meta/allow_pattern/confirm_id)
- `client.aggregate(conv_id, opts)` — 聚合卡(`append`/`update`/`finish`/`interrupt`,degraded_self_heal/recall_empty)
- `client.stream(conv_id, opts)` — 流式会话(`push`/`end`/`abort`,aggregate 定位/throttle_ms)
- `client.session_mapping(path)` — session↔conversation 映射(`ensure_conversation`/`by_session`/`by_conversation`)
- `client.rest.send_card_message` / `update_message_content` / `create_approval` / `get_approval` / `list_agent_conversations` / `list_agent_sessions` / `create_group_as_agent` / `update_conversation_title` / `update_session_meta` / `upload_file` / `download_file`
- `client.register_method(name, handler, timeout_hint_ms=5000)` / `RPCDispatcher.register(name, handler, timeout_hint_ms=5000)` — server 侧 RPC 方法

## 事件

见 `wanling_sdk/client.py` 事件映射表(`message` / `approval.decided` / `conv_update` / `session.meta.update` / `abort` / `typing` / ...)。

协议权威源:[docs/ai-handbook/websocket-protocol.md](../../docs/ai-handbook/websocket-protocol.md)
