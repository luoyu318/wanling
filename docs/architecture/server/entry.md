# Server 入口与认证

应用入口 + JWT 双角色认证。

## cmd/main.go

入口，组装所有依赖，注册路由。修改路由或新增 Handler 在此接入。**注意路由组角色限制**：
`userAuth` 组（仅 user role）管 `/api/users/me*`、`/api/conversations*`（含 `/read`、`/messages/read`、`/unread`、`/pin`、`/unpin`、`/abort` 中断生成、hide 等子路由）、`/api/agents`（CRUD + `/:id/rotate-secret` 重置密钥 + `/:id/models` 拉可选模型 + `/:id/slash-catalog` 拉命令清单，均仅 owner）、`/api/agents/:id/rpc` + `/rpc-methods`（RPC 同步代理，60/min 限流）、`/api/agents/:agentId/sessions`（user 视角查某 agent 的 agent_session 群,APP 二级列表页用）、`POST /api/messages`（user 同步发消息走 HTTP，返 message_id + created_at；agent 仍走 WS）、`/api/mini-programs`（小程序 4 接口：`POST` 上传建私有/换版本 + `GET` 列表 + `GET /:id/package` 下载包 + `DELETE /:id` 删自己私有）。**好友/群组/用户搜索路由**（`/api/users/search`、`/api/users/by-username/:username`、`/api/users/me/friend-requests*`、`/api/users/me/friends`、`/api/friend-requests/*`、`/api/conversations/:id/participants`、`/leave`）也在本组注册且 server 正常运行，但 APP UI 入口已下线，当前无 APP 流量（详见 handlers.md）
`adminAuth` 组（仅 admin role）管 `PUT /api/mini-programs/:id/status`（小程序状态机流转 private→published⇄disabled，管理员 publish/停用）
`msgAuth` 组（user + agent role）管 `DELETE/PATCH /api/messages/:id`（撤回 / 改内容）+ `POST /api/messages/batch-delete`（多选删除），撤回/删除需广播会话全员故双角色挂同一组
`agentAuth` 组（仅 agent role）管 `/api/agents/me/conversations`（agent 视角 findOrCreate，跟 user 版 `/api/conversations` 对称）+ `PATCH /api/agents/me/conversations/:id/title`（agent 改会话标题，opencode-plugin ensureConversation 异步改名用）+ `PATCH /api/agents/me/conversations/:id/session-meta`（同步 session 元数据，plugin `session.updated` 事件触发,落 mode/model/variant/modelName/providerName）
审批 API 分挂三组：`POST /api/conversations/:id/approvals`（agent 创建审批卡片）挂 `agentAuth`（仅 agent role，限流 20/min/会话）；`GET /api/approvals/:id`（查详情）挂 `fileAuth`（user+agent 双角色）；`POST /api/approvals/:id/decide`（user 决策）挂 `userAuth`（仅 user）。限流实现见 `internal/ratelimit/`
`fileAuth` 组（user + agent role）管 `/api/upload`（带可选 `?conversation_id=` query，有值时落 file_conv_links 授权）、`/api/files/:id`，因为 agent 也要上传/下载文件
`/api/pair/*` 扫码配对：`POST /tickets` + `GET /tickets/:id` 匿名（凭 256-bit ticket_id）；`POST /tickets/:id/scan` + `POST /tickets/:id/complete` 走 `pairAuth` 组（user JWT）。GET 按 IP 60/min、complete 按 user 10/min 限流（`internal/ratelimit/`）
`/ws`、`/health`、`/ready` 单独挂,不走 gin AuthMiddleware。
- `/ws` 握手不验 JWT,连接后首条 Identify 消息带 token,由 ws_handler 调 auth.ParseToken 接受 user+agent 双角色
- `/health` 轻量进程存活检查,返 `{"status":"ok"}`,**不验依赖**(DB/Redis 挂了仍 200),供 load balancer / 反向代理快速判断进程在
- `/ready` 深度依赖就绪检查,验 DB Ping + Redis Ping(Redis 可选,启动时降级为 nil 则跳过),供 docker / k8s healthcheck 区分「进程在但依赖挂了」

## auth/jwt.go

JWT 认证，通过 `role` 字段区分 user 和 agent 两种身份。claims 含 `jti`(UUID,黑名单精确拉黑单 token)+ `ver`(tokenver 快照,AuthMiddleware 比对 Redis 最新值)。user access TTL 2h,agent 72h。

## auth/token_store.go

Redis token store,JWT 安全加固的核心存储层。三个 Redis key schema:
- `refresh:<sha256(token)>` → `{user_id, role, ver}` TTL 30d — refresh token 存储(rotation:每次 refresh 删旧建新)
- `blacklist:<jti>` → `1` TTL = access 剩余 TTL — 拉黑单个 access token(logout 时写)
- `tokenver:<user_id>` → 整数(持久)— user 当前 token 版本号(改密时 INCR,所有旧 token 立即失效)

**降级策略**:黑名单/tokenver Redis 故障 → fail-open(放行,退回无黑名单状态);refresh → 503(强依赖 Redis,不降级)。
