# Server HTTP Handler

internal/handler/ 目录下的 15 个 HTTP handler + middleware/access_log。

## handler 总览

HTTP Handler 集合。

## auth_handler.go

登录(返 access + refresh token pair)/ Agent token 换取(secret_key 换 72h JWT)/ Refresh(rotation:删旧 refresh + 签新 pair)/ Logout(黑名单当前 access jti + 删 refresh)。`issueTokenPair` helper 统一签发逻辑。`Register` 方法存在但**未注册任何路由**（公开注册接口已关，加用户只能走 admin-tool）。Refresh 限流 10/min/IP,AgentToken 限流 10/min/IP(撞库防御 + subtle.ConstantTimeCompare 防时序攻击)。

## user_handler.go

`GET /api/users/me`（restoreSession 拉取用户信息）+ `PUT /api/users/me`（更新 nickname / bio / avatar_url）+ `PUT /api/users/me/password`（改密码,不需旧密码,改密后 INCR tokenver 使所有旧 token 立即失效 + 返新 token pair）。ChangePassword 的 IncrTokenVersion/CreateRefresh 失败时返 500(不降级,与 Refresh endpoint 语义一致)。

## agent_handler.go

Agent CRUD + type 注册表。`Update`（`PUT /api/agents/:id`）支持 type 字段更新（**type 为 `*string`:显式传空串=清空回普通 agent**,与当前不同时调 `UpdateType` 落库,让 APP 编辑资料对话框可切换类型）。响应（Create/List/Update）注入 **`multi_session`**（按 `agents.type` 查 `agent_type_registry`,未注册类型含 legacy 空串兜底 false）。**`ListAgentTypes`**（`GET /api/agent-types`,userAuth）全量下发注册表:APP 类型下拉(建/改 agent)与徽标查表数据源,新类型 INSERT 后 APP 零发版自动出现。

## conversation_handler.go（+ 5 个同包拆分文件）

ConversationHandler 是同包多文件结构（Go 同包共享 receiver），物理分布：
- `conversation_handler.go` — struct + constructor + List + Get + buildDetail。**List 的 session 聚合**(BatchLoadAgentSessionStats)按 type 注册表 `multi_session` 过滤 agent(新类型零发版;查表失败 fallback 老口径 opencode)
- `conversation_create.go` — Create + CreateConversationReq + resolveMemberUsernames
- `conversation_agent.go` — CreateAsAgent + ListAsAgent + UpdateTitleAsAgent + UpdateSessionMetaAsAgent + ListAgentSessions
- `conversation_message.go` — Messages 分页
- `conversation_read.go` — MarkRead + MarkMessagesRead + broadcastMessageRead + UnreadInfo
- `conversation_ops.go` — AbortGeneration + Pin/Unpin + Hide

会话列表 + 详情 + FindOrCreate。`List` 返 IM 风格列表(`ListForUser` 拿会话本身 + 调 `BatchLoadParticipantSummaries` 批量补 participants 摘要,让 client 拼群人数 / 群头像不依赖进会话详情)。`ListForUser` JOIN conversation_participants 取个人维度 unread_count/pinned_at/hidden_at + subquery 取 dm_user_agent 的对端 agent 摘要 + subquery 取 dm_user_user 的对端 user 摘要 + `last_message_*` 子查询实时算;**无消息会话也返**(让新建群/DM 立即在所有 participant 列表出现,不再等首条消息触发);`last_message_at` 子查询 COALESCE fallback 到 `c.created_at`(避免零值显示 0001 年)。`buildDetail` 用 BatchLoadParticipantSummaries 批量查 participants 摘要 + GetLastVisibleMessage 取个人维度最新可见消息(含撤回改写 + sender 字段) + **带出 `session_meta`**(agent_session 的 mode/model/variant,modelName/providerName 由 plugin streamer.loadProviderNames 缓存后随 session-meta 一起写);`lastAt` 零值时 fallback 到 `conv.CreatedAt`(同 ListForUser 口径)。`FindOrCreate` 1-1 dm 走 type+双方 member 去重;group_* 走 CreateTx + AddParticipantsTx。**`resolveMemberUsernames` helper** 把 `member_usernames` 反查成 user_id(dm_user_user / group_user 通用,spec §4.2 client 不持 user_id),任一 username 查不到 → 404,MemberIDs+MemberUsernames 同时传 / 重复 username fail-fast 返 400。`POST /:id/read`(标记已读)+ `POST /:id/messages/read`(**按 messageId 批量标记已读**,body `{message_ids:[...]}`,调 `ParticipantRepo.MarkMessagesReadTx` 重算 unread_count)两接口 commit 后都 `broadcastMessageRead` → `hub.SendToUser` 广播 **MESSAGE_READ** 给该 user 全部 WS 连接(多端同步:同账号 B 设备立即刷徽章 + 当前 ChatPage 的 firstUnread,不需下拉刷新;含 sender echo,client 按 message_ids 去重)+ `GET /:id/unread`(**未读信息查询**,返 `{unread_count, first_unread_id, first_unread_created_at}`,APP 据此定位首条未读并按 created_at 游标分页加载历史)+ `POST/DELETE /:id/pin`(置顶/取消)+ `DELETE /:id`(隐藏)。**`CreateAsAgent`** 是 agent 视角的对称版(`POST /api/agents/me/conversations`,body `{user_id}`)。**`ListAgentSessions`**(`GET /api/agents/:agentId/sessions`,userAuth)user 视角查某 agent 的 agent_session 群(APP 二级列表页:点 opencode agent 入口 → 列出该 agent 下所有 session 实例),调 `ListAgentSessionsForUser` 双 JOIN(user+agent)过滤 `type=agent_session`,排除 dm_user_agent + 其他 agent 的 session(隔离)。**`UpdateTitleAsAgent`**(`PATCH /api/agents/me/conversations/:id/title`,agentAuth) + **`UpdateSessionMetaAsAgent`**(`PATCH /api/agents/me/conversations/:id/session-meta`,agentAuth)是 agent 视角的两个 PATCH,前者让 plugin ensureConversation 异步改名(走 agentAuth 避免 user-only 路由的 403),后者接收 plugin 同步来的 mode/modelId/providerId/variant/modelName/providerName/cwd/gitBranch/**tokensTotal/contextUsed/contextLimit** 写入 `conversations.session_meta` JSONB(校验 agent 是 participant 后调 `ConversationRepo.UpdateSessionMeta`,schemaless 透传;后三者 int64,plugin 拉的 Session.tokens 累计 + 本次 step_finish 窗口占用 + model.limit.context 上限),写完库后调 `BroadcastSessionMetaUpdateToUsers` 广播 **SESSION_META_UPDATE** 给本会话 user 端(仅 user,断 plugin→OC 回环;APP chatProvider 监听后整体替换 `chatState.sessionMeta`,SessionMetaStrip / EnvMetaStrip 实时刷新)。**`AbortGeneration`**(`POST /:id/abort`,userAuth)中断当前生成:participant 校验通过后 `hub.SendToConv` dispatch **GENERATION_ABORT** 给会话全员(plugin 收到调 OC SDK abort,user 端忽略),幂等(无生成在跑 plugin 优雅忽略)。

## approval_handler.go

审批卡片 3 接口。`CreateApproval`（agent，事务内创建 msg_type=card 消息，事务外创建 approval 记录，广播 MESSAGE_CREATE；不再维护 last_message_content 缓存字段（017 合并进 001_init 已删）；command + allow_pattern 时先查会话级白名单匹配（含 decided_action='allow_always' 条件），命中返 auto_approved 不发卡片；card_type=question 时校验 options 非空/id 唯一，options/multi_select 双写 content）、`Decide`（user，body 含 action_id/reason/answers，调 approval.Service 推进状态机）、`Get`（双角色兜底查询，返回 decided_answers）。**WS payload 必须含 conversation_id/sender_type/sender_id/created_at**（APP chatProvider 按 conversation_id 过滤 + ChatMessage.fromJson 必填校验，缺字段会被丢弃）

## rpc_handler.go

RPC 同步代理 2 接口（userAuth，仅 owner，IDOR 防护）。`Call`（`POST /api/agents/:id/rpc`，限流 60/min/user）：把 APP 的 HTTP 请求 `{method, params, timeout_ms}` 包成 JSON-RPC 2.0，经 `hub` 转 OpPluginCall WS 给 plugin，等回包（OpPluginResult）后返 HTTP 响应。**JSON-RPC 2.0 envelope 例外**：成功返 `{"result": <T>}`，失败返 `{"error": {code, message}}`（不走 REST {ok, data}）。超时模型 `min(method_hint, app_timeout_ms, 60s 全局上限)`。万灵扩展错误码：-32001 plugin_offline（503）/ -32002 plugin_timeout（504）/ -32003 plugin_disconnected（503，pending 中 plugin 断线）。`Methods`（`GET /api/agents/:id/rpc-methods`）：读 `CapabilityRegistry` 返 plugin 上报的 method 清单（空清单合法，`updated_at: null`）。协议权威源见 [rpc-protocol.md](../../ai-handbook/rpc-protocol.md)

## 好友 / 群组 / 用户搜索 handler（APP UI 未开放，代码保留）

`friendship_handler.go`（好友请求 6 接口：创建/列表/接受/拒绝/取消/删除）+ `group_handler.go`（群管理 4 接口：Update/Pin/InviteMember/KickMember/Leave）+ `user_search_handler.go`（用户搜索 + 按 username 查）。server 路由 + handler + repo 全部在跑，但 APP 端好友/群组入口已下线（详见 [app/pages.md](../../app/pages.md)「好友 / 群组页面」节），当前无 APP 流量。

## ws_handler.go

WebSocket 协议（Hello → Identify → Heartbeat → Dispatch）

## send_handler.go

**HTTP 同步发消息**（`POST /api/messages`，仅 user）。body `{conversation_id, content}` → 校验 participant → 调 `MessageProcessor.HandleIncoming` → 返 `{message_id, created_at}`。dispatch 不过滤 sender（让 sender 自己也收 MESSAGE_CREATE echo，多端同步）。

## message_handler.go

**消息删除双轨制**。`DELETE /api/messages/:id?scope=hide|recall`（单删）+ `POST /api/messages/batch-delete`（仅 hide 批量，必须同一会话，上限 100）。**scope=hide**（默认）：单向隐藏（per-participant），`MessageRepo.HideForUser` 写 `message_hidden` 表，单播 MESSAGE_DELETE 给当前请求者。**scope=recall**：双向软删（deleted_at = NOW()），仅自己发的 + 5min 内；走事务 `SoftDeleteTx + RecomputeUnreadForConvTx` 保证 unread_count 同步剔除（修复对方未读场景撤回后徽章永久偏高 bug）；广播 MESSAGE_DELETE 给会话全员，payload 含 `scope=recall` + `sender_id/type/name`，client 据此切「你/对方撤回了一条消息」。撤回占位靠 server 端 SanitizeForClient（`Messages` handler 出口把撤回消息 content 改写为 `{msg_type:recalled,data:{}}`）+ ListForUser/GetLastVisibleMessage 子查询同步改写。

**`GET /api/messages/:id/context?before=10&after=10`**（引用块跨页跳转用）：返 target + 前 N 条 + 后 N 条。404 场景：(1) target_id 不存在；(2) target 已撤回（DeletedAt.Valid，撤回语义下跳转无意义）；(3) **target 被当前 user 隐藏**（`IsHidden` 命中 message_hidden，对自己不可见，跳转应 404 符合 hide 意图——别人 hide 不影响本判断）。403：非 participant。before/after 内部已过滤软删除消息（撤回消息不参与跳转上下文渲染），上限 50 防滥用。

**聚合卡增量 PATCH**（`PATCH /api/messages/:id`，agent 更新聚合卡）：`content.data` 带 `op` 走增量合并（`append`/`update`/`remove`/`reorder`/`set_state`/`set_silent`），`applyContentOp` 在原 content 上按 op 合并、DB 存全量、广播**带增量**的 MESSAGE_UPDATE；无 `op` 带 `elements` 仍全量替换兼容旧 plugin（保留原 silent）。**silent 翻转计未读**：原消息 `silent=true` 且 PATCH 后翻转为 `false` 时（聚合卡回合结束，plugin 显式 `{op:"set_silent",silent:false}`），对**非 sender 全员 +1 unread**（`IncrUnread`，与发消息口径一致）——计数放在 `UpdateContent` 成功之后（失败则 content 仍 silent=true 不产生假未读）。仅 sender 可更新（role+id 双校验，防 IDOR）。详见 [websocket-protocol.md](../ai-handbook/websocket-protocol.md) 聚合卡协议。

**消息列表分页**（`GET /api/conversations/:id/messages`）：`limit` 默认 50、上限 200（游标分页按消息条数返回，无法按消息类型区分）。聚合卡分卡后（单卡 ≤20 元素）APP 端 `pageSize` 实际请求 10 条/页，约束单页 content 体积（server 默认值不变）。

## file_handler.go

文件上传/下载。**Agent role 上传**时 `owner_id` 落地为 `agent.owner_id`（在 handler 内查 owner），满足 `files.owner_id` 外键到 `users(id)` 约束。**上传加 `?conversation_id=` query 参数**：有值时调 `FileRepo.AddConvLink` 落 `file_conv_links` 授权记录（让会话内其他 participant 可下载;群头像 / 群文件 / 头像替换等场景都需要)。client `uploadFile` / `uploadBytes` 两个 API 都支持 `convId` 参数。**下载走四档放行**（`FileRepo.CheckAccess`，替代原 owner 单一校验）：(1) `f.OwnerID == claimerID` owner 直接放行；(2) 头像白名单(`users.avatar_url` / `agents.avatar_url` / **`conversations.avatar_url`** 命中,社交公开属性),让 dm_user_user 场景对方头像 + 群成员加载群头像均可正常;(3) `file_conv_links` JOIN `conversation_participants` 校验是否同会话 participant。四档任一命中即放行，否则 403。file_handler 的错误日志都带 `[upload]`/`[download]` 前缀走 stderr。**图片缩略图**：上传时 `isImageUpload`（mime 或扩展名双重判定）命中则同步调 `imaging.GenerateThumbnail` 生成 600px 长边 JPEG 缩略图落盘（`{原fileID}_thumb.jpg`，fail-soft 失败降级原图不阻断上传）；图片 mime 按 `resolveImageMime` 矫正（客户端传 octet-stream 时按扩展名补正）。**下载支持 `?thumb=1`**：返回缩略图（消息列表场景），无缩略图自动降级原图。**响应带缓存头** `Cache-Control: immutable, max-age=2592000` + `ETag`（fileId 与内容 1:1 不可变，客户端 HTTP 层命中本地缓存根治重复下载）

## pairing_handler.go

扫码配对 4 接口（`CreateTicket`/`GetTicket`/`ScanTicket`/`CompleteTicket`）。GET completed 返回凭据后**领完即焚**（清空 `pairing_tickets.secret_key`）；scan 幂等（同 user 重扫 OK，跨 user 403）；complete 选已有 agent 重置 secret_key、新建 agent 走 `AgentRepo.Create`。响应统一返 `{status}` 字段串（pending/scanned/completed/expired/not_found）。**agent type 透传**：`CreateTicket` body 可选 `{type}` 声明 agent 类型(opencode 等,默认空串),存入 `pairing_tickets.type`;`CompleteTicket` 新建分支读 `ticket.type` 传给 `AgentRepo.Create`(替代原硬编码空串),实现扫码配对的 opencode agent 全链路 type 透传(APP 可识别 agent 类型)。

## mini_program_handler.go

小程序容器 6 接口，按角色分三个路由组：**mpAuth（user+agent 双角色，M2 Agent 直传）**承载 `Upload`（`POST /api/mini-programs`）与 `DownloadPackage`（`GET /api/mini-programs/:id/package`），**handler 内 owner 换算**（role=agent 时 userID 换成 `ownerID`，照 file_handler 先例规避 users 外键约束，agent_id 不落 users 表）；userAuth 组承载 `List`（`GET /api/mini-programs`，published 全量 + 自己的，DTO 带 signature）、`GetSigningKey`（`GET /api/mini-programs/signing-key`，下发 ed25519 公钥，私钥永不出 server）与 `Delete`（`DELETE /api/mini-programs/:id`，仅 owner 删 private，其余 409）；adminAuth 组承载 `ListAdmin`（`GET /api/admin/mini-programs`，审核全量列表，三状态全含，JOIN owner username 回填 `owner_username`，updated_at 倒序；鉴权由 adminAuth 组中间件保证，handler 不自检 role）与 `UpdateStatus`（`PUT /api/admin/mini-programs/:id/status`，状态机白名单 private→published⇄disabled，非法流转 409，published 自动签名；旧路径 `PUT /api/mini-programs/:id/status` 保留为兼容别名挂同一 handler）。`Upload` multipart zip：`http.MaxBytesReader` 限体 413 + `.zip` 扩展名校验 + `miniprogram.ValidatePackage` 结构校验 fail-fast → appid 归属判定（他人占用 403 / 自己占用 `ReplaceVersion` 换版本，重置 private + signature=NULL / 否则新建，sha256 + `storage.Save` + files 落库）。`DownloadPackage` 非 owner 仅 published 放行防 IDOR，带 `X-Mini-Program-Sha256` 响应头供 APP 安装校验。**包签名（M3）**：`UpdateStatus` 流转到 published 时 `signPackage` 用 ed25519 私钥对包字节签名落 `signature` 列（失败记日志不阻断 publish，由补签兜底）；`BackfillSignatures` 启动补签历史 published 缺签包（循环 LIMIT 256 消费，单包失败继续，整轮零进展终止）。构造 `NewMiniProgramHandler(repo, signingKeyRepo, fileRepo, storage, maxZipBytes)`。

## middleware.go

`AuthMiddlewareWithStore` — JWT 验签 + 黑名单 jti 检查 + tokenver 版本号检查(role=user 时)。黑名单/tokenver Redis 故障 fail-open(放行,不踢全量用户)。旧 `AuthMiddleware` 委托给 WithStore(tokenStore=nil 时退回纯验签)。WS 握手仍走 `AuthMiddleware`(不查黑名单/tokenver,长连接不重新验 token)。

## access_log.go

`BusinessAccessLog()` 自定义 access log 中间件，只记录命中注册路由的请求（`c.FullPath()` 非空），扫描器探测的 NoRoute 404 静默。main.go 用 `gin.New() + Recovery + BusinessAccessLog` 替代 `gin.Default()`
