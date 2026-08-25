# REST 响应规范

万灵 REST API 响应统一 envelope。本文件被各子 CLAUDE.md 通过 @import 引用，是 server / app / plugin / SDK 四方共同契约。

## envelope 形态

所有 JSON 响应统一：

```json
{ "ok": true, "data": <T | null> }                              // 成功
{ "ok": false, "error": { "code": "...", "message": "..." } }   // 失败
```

## 规则

- HTTP 状态码按 REST 语义（200 / 201 / 4xx / 5xx）
- 4xx / 5xx body 必须 envelope（`{ok: false, error: {...}}`）
- `data: null` 用于「无业务数据」场景（如 markConversationRead）
- 文件下载（binary content-type 非 JSON）不 envelope
- error 子对象允许业务字段（如 approval conflict 的 `state`）

## 后端实现

```go
// server/internal/handler/response.go
Ok(c, payload)                       // 200 + envelope data
OkCreated(c, payload)                // 201 + envelope data
Err(c, status, code, msg, extra...)  // 4xx/5xx + envelope error
ErrMsg(c, status, msg)               // 简化版（code = CodeInternalError）
ErrCode(c, status, code, msg)
```

后端测试断言：`AssertOk` / `AssertOkList` / `AssertErr` / `AssertErrBody`（`response_test.go`）。

## 错误码表

| code | HTTP | 触发场景 |
|---|---|---|
| invalid_state | 409 | 资源状态不允许操作（如审批已决策、用户名已存在）|
| not_found | 404 | 资源不存在 |
| forbidden | 403 | 鉴权通过但无权限 |
| unauthorized | 401 | 鉴权失败 |
| bad_request | 400 | 参数错误 |
| rate_limited | 429 | 限流 |
| payload_too_large | 413 | 上传文件过大 |
| unsupported_media_type | 415 | 文件类型不支持 |
| timeout | 504 | 请求超时 |
| internal_error | 500 | 其他（用 ErrMsg 默认）|

## 集合响应

后端返 `Ok(c, list)`，data 直接是数组。**不再用** `{users: [...]}` / `{requests: [...]}` / `{friends: [...]}` / `{agents: [...]}` 这类集合 envelope（pairing scan 端点的 `{agents: [...]}` 已在 Task 4 收尾时一并剥掉）。

## Client 实现策略

- **Flutter app**：Dio 拦截器统一剥 envelope（`api_service.dart._installInterceptor`）。method 直接返 T，错误抛 `ApiException`（定义在 `api_response.dart`，含 code/message/statusCode）。调用方 try/catch `DioException`，按 `e.error as ApiException` 取 code。
- **Plugin (hermes)**：`adapter.py._safe_request` helper 返 data 或 None（错误日志含 code/message/status）。token 端点保留 raise 语义（hermes gateway retry 据此）。

## 字段命名

- envelope 字段：`ok` / `data` / `error`
- error 子对象：`code` / `message` + 业务字段
- code 用 snake_case 小写（如 `bad_request` / `invalid_state` / `internal_error`）

## 不变量

- 后端 14 个 handler 共 ~390 处 c.JSON 响应全部走 helper（JSON-RPC 2.0 envelope 例外除外；grep `c\.JSON(http\.Status` 在 internal/handler/ 应仅剩 rpc envelope 例外，排除 _test.go 和 response.go）
- 后端 middleware 鉴权 / 超时也 envelope 化（401/403/504）
- binary 响应（c.Data / c.File / c.DataFromReader）不 envelope
- 499 Client Closed Request（Nginx 约定）不 envelope，无 body

## POST /api/agents/:id/rotate-secret

重置 agent secret_key（仅此一次下发新密钥，对齐 GitHub PAT 模式）。**鉴权**: userAuth（仅 owner，IDOR 防护：GetByID → OwnerID 比对，与 Update/Delete 一致）。

**响应**: `{"ok":true,"data":{"secret_key":"新生成密钥"}}`

**状态码**: 200(重置成功，旧 secret_key 立即失效) / 403(非 owner) / 404(agent 不存在)。已签发的 agent JWT 不受影响（自然过期前仍有效，密钥仅用于换新 token）。

## GET /api/agent-types

获取 agent type 注册表全量（migration 011 表,server 统一下发类型属性）。APP 类型下拉（建/改 agent）与徽标查表数据源;新类型 INSERT 一行后 APP 零发版自动出现。

**响应**: `{"ok":true,"data":[{"type":"dsh","multi_session":true,"label":"DSH","badge_bg":"#E0F2FE","badge_bg_elevated":"#BAE6FD","badge_fg":"#075985"},...]}`

**字段语义**: `multi_session` 拓扑属性(APP 一级列表路由:二级 sessions 页 vs 直进聊天窗);`label`/`badge_*` 展示属性,badge 色为 `#RRGGBB`,空串=client 用默认配色。预置 hermes/opencode/dsh 三行。

**Client fallback**: 老 server 无此端点(404)时,client 用本地预置清单兜底(label=type 原文 + 默认紫配色为未注册类型的最终兜底)。agents 相关响应(`GET /api/agents` 等)同步注入 `multi_session` 字段,client 缺字段时 fallback `type=='opencode'` 旧口径。

## GET /api/agents/:id/models

获取某 agent 的可选模型清单（plugin 上报，server 内存缓存）。供 APP 切换 model（`SessionMetaStrip` 弹底部 sheet 选择）。

**鉴权**: userAuth（仅 owner 可查，IDOR 防护）

**响应**:
```jsonc
{
  "ok": true,
  "data": {
    "agent_id": "uuid",
    "models": [
      {
        "provider_id": "zhipuai-coding-plan",
        "provider_name": "智谱编码计划",
        "model_id": "glm-4.6",
        "model_name": "GLM-4.6"
      }
    ],
    "updated_at": "2026-07-18T12:34:56.789Z"   // 或 null（未上报）
  }
}
```

**状态码**:
- 200: owner 查询成功（空清单也返 200，`models: []`）
- 403: 非 owner
- 404: agent 不存在

**`updated_at` 语义**:
- 非空 RFC3339 时间戳: 最近一次 plugin 上报时间
- `null`: 从未上报（plugin 离线 / server 刚重启 / opencode 未就绪）

## GET /api/agents/:id/slash-catalog

获取某 agent 的命令/技能清单（plugin 上报，server 内存缓存）。与 `GET /api/agents/:id/models` 同构。APP 据每项 `source` 字段分组渲染（命令组在上、技能组在下）。

**鉴权**: userAuth（仅 owner 可查，IDOR 防护）

**响应**:
```jsonc
{
  "ok": true,
  "data": {
    "agent_id": "uuid",
    "commands": [
      {"name":"compact",      "template":"/compact",      "description":"压缩上下文", "source":"command"},
      {"name":"agently-mail", "template":"/agently-mail", "description":"邮件操作",   "source":"skill"}
    ],
    "updated_at": "2026-07-18T12:34:56.789Z"   // 或 null（未上报）
  }
}
```

**状态码**:
- 200: owner 查询成功（空清单也返 200，`commands: []`）
- 403: 非 owner
- 404: agent 不存在

**字段说明**:
- `source`: `"command"`(OC 命令) | `"skill"`(OC 技能)；plugin 自推的 `/compact` 也归 `source="command"`
- `description`: 可选（omitempty，OC 命令/技能无描述时省略，APP 端需防御空值）

**`updated_at` 语义**:
- 非空 RFC3339 时间戳: 最近一次 plugin 上报时间
- `null`: 从未上报（plugin 离线 / server 刚重启 / opencode 未就绪）

## POST /api/agents/:id/rpc

> **RPC 协议权威源**:见 [rpc-protocol.md](./rpc-protocol.md)

调用 plugin RPC method,同步等待结果。**JSON-RPC 2.0 envelope 例外**:成功返 `{"result": <T>}` 而非 `{ok, data}`,失败返 `{"error": {code, message}}`(无 ok 字段)。

**鉴权**: userAuth(仅 owner,IDOR 防护) + ratelimit 60/min/user

**请求体**: `{"method":"session.diff","params":{...},"timeout_ms":10000}`

**状态码**:
- 200: RPC 成功(返 `{"result": <T>}`)
- 400: bad_request(method 缺 / params 解析失败) / 401: unauthorized / 403: forbidden(非 owner) / 404: not_found(agent 不存在)
- 429: rate_limited(超 60/min)
- 503: plugin_offline(-32001) / plugin_disconnected(-32003)
- 504: plugin_timeout(-32002) / plugin 返回的其它任意错误码

**错误码**:
| code | HTTP | 触发 |
|---|---|---|
| -32001 | 503 | plugin WS 未连接 |
| -32002 | 504 | RPC 超时 |
| -32003 | 503 | pending 中 plugin 断线 |
| 其它(-32601/-32602/-32603/-32604/-32605 等) | 504 | plugin 端返回的错误(一律按网关错误透传) |

## GET /api/agents/:id/rpc-methods

获取 plugin 上报的 RPC method 清单。APP 据此 UI 隐藏不支持项。**鉴权**: userAuth(仅 owner,IDOR 防护)。

**响应**:
```jsonc
{"ok":true,"data":{"agent_id":"uuid","methods":[{"name":"echo","timeout_hint_ms":3000}],"updated_at":"2026-07-19T12:34:56.789Z"}}
```

**状态码**: 200(owner 查询成功,空清单也返 200,`methods: []` + `updated_at: null`) / 403(非 owner) / 404(agent 不存在)

**`updated_at` 语义**: 同 `GET /api/agents/:id/models`(非空 RFC3339 = 最近上报时间;`null` = 从未上报)

## POST /api/conversations/:id/abort

中断会话当前生成。**鉴权**: userAuth（participant 校验：`ParticipantRepo.Exists` 不通过返 403）。server dispatch `GENERATION_ABORT` 给会话所有 participants，agent(plugin) 收到后调 OpenCode SDK abort API 中止当前生成；user 端忽略此事件（无对应 UI）。幂等：无生成在跑时 plugin 优雅忽略。

**响应**: `{"ok":true,"data":null}`

**状态码**: 200(已 dispatch) / 403(非 participant)。事件 payload 与触发链路详见 websocket-protocol.md 的 `GENERATION_ABORT`。
