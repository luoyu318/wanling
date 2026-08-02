# 万灵 RPC 协议(server ↔ plugin 请求-响应)

万灵 RPC 通道,让 server 能主动调 plugin 执行业务后等回包。本文件被各子 CLAUDE.md 通过 @import 引用。

## 1. 触发场景 + 设计目标

server 主动调 plugin 的请求-响应需求:directory 选择、session diff、文件查看、全文搜索等。

WS Dispatch(op=0)是单向 fire-and-forget,REST 只能 plugin → server 上行,都不够。RPC 通道专门补 server → plugin 的请求-响应语义。

## 2. 新 opcode

| Opcode | 名称 | 方向 | 用途 |
|---|---|---|---|
| 12 | PluginCall | S→C | server → plugin RPC 请求 |
| 13 | PluginResult | C→S | plugin → server RPC 响应 |

**关键属性**:这两个 opcode **不进 dispatchBuffer**(`hub.bufferedSend` 仅对 `Op==OpDispatch` 进 buffer)。无需改 hub buffer 逻辑。

## 3. JSON-RPC 2.0 包络(WSMessage.D)

**请求(server → plugin,Op=12)**:
```jsonc
{"op":12,"d":{"jsonrpc":"2.0","id":"01J9...","method":"session.diff","params":{"session_id":"..."}}}
```

**响应成功(plugin → server,Op=13)**:
```jsonc
{"op":13,"d":{"jsonrpc":"2.0","id":"01J9...","result":{...}}}
```

**响应失败**:
```jsonc
{"op":13,"d":{"jsonrpc":"2.0","id":"01J9...","error":{"code":-32601,"message":"..."}}}
```

`id` 用 UUID v7(时间有序 + 全局唯一,server 端生成)。`t` / `s` 字段对 RPC opcode 无意义,省略。

## 4. method 命名

**不带 plugin_type 前缀**(server 不做适配层)。格式:`<namespace>.<verb>`

| method | 用途 | 状态 |
|---|---|---|
| `session.diff` | 拿 session 累计文件变更 | ✅ Phase 4B |
| `session.list` | 列 sessions | ⏳ |
| `project.list` | 列已知项目 | ✅ Phase 3 |
| `file.list` | 列目录 | ✅ Phase 5 |
| `file.read` | 读文件 | ✅ Phase 5 |
| `vcs.get` | 拿 branch / status | ⏳ |
| `find.text` | 全文搜索 | ⏳ |
| `find.files` | 文件名搜索 | ⏳ |

冲突处理:不同 plugin_type 实现同名 method 但 schema 不同 → server 只透传 JSON,不关心语义。capability 上报告诉 APP 隐藏不支持项。

## 5. capability 上报

### 5.1 协议(对称 AGENT_MODELS)

plugin → server 单向事件(Op=0 + `t:"PLUGIN_CAPABILITIES"`):
```jsonc
{"op":0,"t":"PLUGIN_CAPABILITIES","d":{"agent_id":"01J8...","methods":[{"name":"session.diff","timeout_hint_ms":5000}],"reported_at":"2026-07-19T10:30:00Z"}}
```

### 5.2 触发时机

plugin WebSocket 连接成功 + 完成 OpenCode SDK 探测后,**对称 AGENT_MODELS 同一触发点**(`streamer.start()` 中)。失败 silent drop,下次重连重报。

### 5.3 安全守卫(对称 AGENT_MODELS)

1. `senderType != "agent"` 拒绝(防 user 越权)
2. `payload.agent_id != senderID` 拒绝(防 plugin A 冒充)
3. 空 agent_id 一并拒绝

### 5.4 server 处理

写 `CapabilityRegistry` 内存缓存(`server/internal/agent/`),**不广播**给其他 client(APP 通过 REST 拉)。空清单合法。

### 5.5 APP 拉取

`GET /api/agents/:id/rpc-methods`(见 rest-response.md)。plugin 未上报 / server 刚重启 / plugin 不支持 RPC → 返空清单 + `updated_at: null`。

### 5.6 各 method 的 params/result/error schema

已实现的 4 个 method(project.list / session.diff / file.list / file.read)的详细 schema 见 [@./rpc-methods.md](@./rpc-methods.md)。

## 6. REST 同步代理(APP 消费)

APP 是同步 HTTP 语义,server 提供 REST 同步代理把 RPC 包成 HTTP 请求-响应。

- **`POST /api/agents/:id/rpc`** — 详见 rest-response.md
- **`GET /api/agents/:id/rpc-methods`** — 详见 rest-response.md

## 7. 错误码体系

**JSON-RPC 2.0 标准**:
| code | 含义 |
|---|---|
| -32700 | Parse error |
| -32600 | Invalid Request |
| -32601 | Method not found |
| -32602 | Invalid params |
| -32603 | Internal error |

**万灵扩展**(JSON-RPC 2.0 保留段):
| code | 含义 | 触发场景 |
|---|---|---|
| -32001 | plugin_offline | plugin WS 不在线 |
| -32002 | plugin_timeout | ctx 超时 |
| -32003 | plugin_disconnected | pending 中 plugin 断线 |
| -32604 | git_error | cwd 非 git 仓库 / git 命令失败(仅 session.diff, file.list)|
| -32605 | file_read_failed | file.read 失败(文件不存在 / 权限 / IO / 图片过大)|

## 8. 超时模型

```
实际超时 = min(
  method_capability.timeout_hint_ms,
  app_request.timeout_ms,
  GLOBAL_CAP = 60000
)
```

- 全局上限 60s,防 APP HTTP 长时间挂起
- method 级 hint 由 plugin 上报
- APP 可传 `timeout_ms` 进一步压缩

## 9. 限流

`POST /api/agents/:id/rpc`:**60/min/user**(agent 维度),防 APP bug 刷 RPC。`GET /rpc-methods` 不挂(读 + IDOR 已防)。

## 10. 安全

- **IDOR 防护**: `userID == agent.OwnerID`(对称 file 下载四档放行)
- **WS 帧上限**: 512KB,OpPluginCall params 不能超
- **result 截断**: 如果 RPC result 超大(如 find.text 返几 MB),plugin 端必须分页或截断 + 标 `truncated: true`
- **method 白名单**: server 不维护(plugin 上报什么就允许什么)

## 11. 不在范围

明确不做(YAGNI):
- plugin → server 上行 RPC(plugin 已有 REST)
- 流式 RPC 响应(长任务进度,需要再加 OpPluginProgress=14)
- 跨 agent 路由
- server 端 method 白名单
- plugin 端 method 鉴权
- 多 owner 共享 agent
