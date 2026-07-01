# 万灵 SDK

万灵服务端的双层接入组件：

- **`python/`** — `wanling-sdk`：Python SDK，以 agent 身份连接万灵服务端，提供 WS 收发消息 + HTTP REST 操作（会话 / 审批 / 文件 / 消息删除）
- **`mcp/`** — `wanling-mcp`：MCP Server，把 SDK 能力包装成 8 个 MCP 工具，供 Claude Code / OpenCode / ZCode / Cursor 等 AI 终端直接调用
- **`setup.sh`** — 跨机器一键部署脚本（建 venv + 装两个包）

## 快速开始

### 前置依赖

- Python ≥ 3.10
- [uv](https://docs.astral.sh/uv/)（用于管理 venv 和包安装）

### 一键安装

在仓库根目录执行：

```bash
./sdk/setup.sh
```

脚本会在 `sdk/.venv` 建 venv，并以 editable 模式安装 `wanling-sdk` + `wanling-mcp`。脚本幂等，可重复执行。

### 配置 MCP

仓库根目录有 `.mcp.json.example` 模板（`.mcp.json` 本身因含凭证被 `.gitignore` 排除）。新机器 clone 后：

```bash
cp .mcp.json.example .mcp.json
# 编辑 .mcp.json，填入实际凭证
```

模板内容：

```json
{
  "mcpServers": {
    "wanling": {
      "command": "./sdk/.venv/bin/python",
      "args": ["-m", "wanling_mcp"],
      "env": {
        "WANLING_AGENT_ID": "<your-agent-id>",
        "WANLING_SECRET_KEY": "<your-secret-key>",
        "WANLING_USER_ID": "<default-target-user-id>",
        "WANLING_SERVER": "https://your-wanling-host:10008"
      }
    }
  }
}
```
```

**环境变量**（在 `.mcp.json` 的 `env` 里配置，或运行前 export）：

| 变量 | 必填 | 说明 |
|---|---|---|
| `WANLING_AGENT_ID` | ✅ | agent ID |
| `WANLING_SECRET_KEY` | ✅ | agent 密钥（在万灵 app 里创建 agent 后获得） |
| `WANLING_SERVER` | ❌ | 服务端地址，默认 `http://localhost:18008` |
| `WANLING_USER_ID` | ❌ | 默认推送目标 user_id，所有工具的 `user_id` 参数不传时用它兜底 |

配置完在 Claude Code 里执行 `/mcp` → `Reconnect wanling` 加载。

---

## wanling-mcp 工具参考

8 个工具，对外语义统一用 `user_id`（不暴露 conv_id）。所有 `user_id` 参数都可选，未传时取 `WANLING_USER_ID` 环境变量。

### `wanling_list_conversations`

列出本地缓存的会话。WS 在线事件累积，进程重启后清空。

- **参数**：无
- **返回**：`[{user_id, user_name, last_message_at}, ...]`（按 last_message_at 倒序）

### `wanling_send_message`

发文本消息（非阻塞）。

- **参数**：`text` (必填), `user_id` (可选)
- **返回**：`{"ok": true}`

### `wanling_report_progress`

语义糖：发进度更新，等价于 `send_message`，仅描述不同。

- **参数**：`text` (必填), `user_id` (可选)
- **返回**：`{"ok": true}`

### `wanling_get_messages`

取本地缓存的消息历史（仅缓存到的不全，要拉完整历史需调 SDK HTTP 接口）。

- **参数**：`user_id` (可选), `limit` (默认 50), `before` (RFC3339 游标)
- **返回**：`[{id, sender_type, sender_id, text_preview, created_at}, ...]`

### `wanling_check_new`

检查未读消息（非阻塞，**读完即清**）。

- **参数**：`user_id` (可选，不传=全部用户)
- **返回**：`{user_id: [msg, ...], ...}`

### `wanling_wait_reply`

发消息后阻塞等用户回复（默认超时 300 秒）。

- **参数**：`text` (必填), `user_id` (可选), `timeout_sec` (默认 300)
- **返回**：`{reply, user_id, timed_out}`

### `wanling_ask_confirmation`

发二选一确认到万灵，阻塞等回复并解析是/否。回复匹配前缀 `是 / y / Y / ok / 确认 / yes` 视为 confirmed。

- **参数**：`question` (必填), `user_id` (可选), `timeout_sec` (默认 300)
- **返回**：`{reply, confirmed, user_id, timed_out}`

### `wanling_upload_file`

上传文件（**当前未实现，预留**）。

- **参数**：`file_path`
- **返回**：`{id, filename}`（实现后）

---

## wanling-sdk Python API

### 安装

`sdk/setup.sh` 已包含。单独使用：

```bash
uv pip install -e sdk/python
# 或
pip install -e sdk/python
```

### 最小 demo

```python
import asyncio
from wanling import WanlingAgentClient

async def main():
    # 凭证从环境变量读，或显式传 (agent_id, secret_key, base_url)
    client = WanlingAgentClient.from_env()
    await client.connect()

    # 监听服务端推送事件
    def on_event(event_type, payload):
        print(f"[{event_type}] {payload.get('content', '')}")
    client.on_dispatch = on_event

    # 发消息（agent → user）
    await client.send_message(user_id="u_xxx", text="hello from sdk")

    # 查/建会话
    conv = client.find_or_create_conv("u_xxx")
    print(conv["id"], conv.get("user", {}))

    await client.close()

asyncio.run(main())
```

### `WanlingAgentClient`

**构造**：

```python
client = WanlingAgentClient(agent_id, secret_key, base_url="http://localhost:18008")
# 或
client = WanlingAgentClient.from_env()  # 从 WANLING_AGENT_ID / WANLING_SECRET_KEY / WANLING_SERVER 读
```

**连接管理**：

| 方法 | 说明 |
|---|---|
| `await client.connect()` | 建 WS + 完成 Hello→Identify 握手 + 启动心跳 |
| `await client.close()` | 关闭 WS + 取消后台任务 |
| `client.on_dispatch = cb` | 注册事件回调，签名为 `(event_type: str, payload: dict) -> None` |

**on_dispatch 事件类型**（`event_type` 取值）：

- `MESSAGE_CREATE` — 新消息（payload 含 conversation_id / sender_type / sender_id / content / created_at）
- `MESSAGE_UPDATE` — 消息内容更新（审批决策后双写 content）
- `MESSAGE_DELETE` — 消息删除（payload 含 ids / conversation_id）
- `AGENT_ONLINE` / `AGENT_OFFLINE` — 其他 agent 上下线
- `TYPING_START` — 用户正在输入
- `APPROVAL_DECIDED` — 审批被决策（含 session_key / confirm_id，用于唤醒 hermes 等待队列）
- `APPROVAL_EXPIRED` — 审批超时

**消息**：

```python
await client.send_message(user_id="u_xxx", text="hello")
```

**会话**：

```python
conv = client.find_or_create_conv(user_id="u_xxx")
# 返回 dict，含 id / user / agent / created_at / last_message_at 等
```

**审批**：

```python
result = client.create_approval(
    conv_id="c_xxx",
    card_type="command",  # command / tool / file / slash_confirm
    title="执行 rm -rf /tmp/old",
    preview="rm -rf /tmp/old",
    session_key="sess_xxx",
    actions=[{"id": "allow_once", "label": "允许"}, {"id": "deny", "label": "拒绝"}],
    expires_in=300,
)
approval = client.get_approval("ap_xxx")
```

**消息删除**：

```python
client.delete_message("m_xxx")
client.batch_delete(["m_1", "m_2", "m_3"])  # 必须同一会话，上限 100
```

**文件**：

> ⚠️ `upload_file` / `download_file` 当前是 **NotImplementedError 占位**（http.py 用 stdlib urllib，未做 multipart / 流式）。需要时改用 httpx 重写或直接调 REST 接口。

---

## 已知限制

1. **MCP 进程内 store**：`list_conversations` / `get_messages` / `check_new` 走的是 MCP 进程内存缓存（WS 事件累积），重启丢失。要拉完整历史需直接调 SDK 的 HTTP 接口（未来可在 store 加 SQLite 持久化）。
2. **`upload_file` / `download_file` 未实现**：SDK 当前用 stdlib urllib，缺 multipart / 流式支持。需要时切到 httpx。
3. **`create_approval` 参数透传**：kwargs 直接进 payload，参数合法性看服务端 `internal/model/approval.go` 的 `CardContent` 定义。

---

## 开发

改 SDK 或 MCP 后，因为 editable install，代码改动即时生效。但 Claude Code 跑的 MCP 进程是独立子进程，需要 `/mcp` → `Reconnect wanling` 才会拉起新代码。
