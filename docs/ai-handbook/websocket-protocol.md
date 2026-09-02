# WebSocket 协议

万灵 WebSocket 协议规范，server / app / plugin 三方共同遵守。本文件被各子 CLAUDE.md 通过 @import 引用。

基于 Opcode 的二进制协议（参考主流 IM Bot）：

| Opcode | 名称 | 方向 | 用途 |
|--------|------|------|------|
| 0 | Dispatch | S→C | 事件推送（MESSAGE_CREATE / MESSAGE_UPDATE / MESSAGE_DELETE / AGENT_ONLINE / AGENT_OFFLINE / TYPING_START / APPROVAL_DECIDED / APPROVAL_EXPIRED） |
| 1 | Heartbeat | C→S | 心跳（仅 `{op:1}`，不再携带 seq；seq 由 Dispatch 自带，Resume 单独走 op=6） |
| 2 | Identify | C→S | 鉴权（携带 JWT token）。**握手阶段强制只接受 Identify**，其余 opcode 必须在 Identify 之后。**子密钥 token（`key_kind=sub`）identify 即拒**：回裸 JSON 错误帧 `{"error":"sub_key_ws_forbidden"}`（非 WSMessage envelope,client 按裸帧识别）后关闭连接,不进 hub,详见 [agent-subkeys.md](./agent-subkeys.md) |
| 3 | SetActiveConv | C→S | 上报当前正在看的会话（`{conv_id}`），供服务端判断要不要计未读。空 conv_id = 退出会话。仅 user 角色（agent 不计未读）。见「未读感知」节 |
| 6 | Resume | C→S | 断线恢复，携带最后收到的序列号。**必须在 Identify 之后** |
| 7 | Reconnect | S→C | 服务端要求重连 |
| 10 | Hello | S→C | 连接建立，含心跳间隔 |
| 11 | HeartbeatACK | S→C | 心跳回应 |
| 12 | PluginCall | S→C | server → plugin RPC 请求(JSON-RPC 2.0,详见 rpc-protocol.md) |
| 13 | PluginResult | C→S | plugin → server RPC 响应(JSON-RPC 2.0,详见 rpc-protocol.md) |
| 14 | Stream | plugin→server→APP | 流式输出全量快照(plugin→server),server 按 activeConvID 过滤转发给正在看该会话的 user。绕过 dispatchBuffer/不落库/不带 seq/不计未读/不补发。见「流式输出(op=14 Stream)」节 |

**消息创建 Dispatch 事件**（opcode 同为 0）：
- `MESSAGE_CREATE` — 新消息推送。payload：`{id, conversation_id, sender_type, sender_id, sender_role, sender_name, sender_avatar_url, conversation_type, conversation_title, content, parent_msg_id?, root_msg_id?, created_at}`。`sender_name` / `sender_avatar_url` 由 server processor 在 dispatch 前查 user/agent 表填入，bg-service 直接读这两个字段渲染通知（替代原依赖 UI IPC 同步的链路，让首次接收消息也能拿到正确头像）。`conversation_type` / `conversation_title` 让 bg-service 区分单聊/群聊通知格式（群聊场景 title=群名，body=「${sender}：${内容}」），单聊场景维持 sender 作 title。dispatch 给所有 participants（含 sender 自己，多端同步 + HTTP 发送场景按 message_id 去重）。

  **子 agent 事件**(parent_msg_id / root_msg_id 字段,opencode-plugin streamer 发):
  - 含义:`parent_msg_id` = 直接父 task 卡片消息 id;`root_msg_id` = 最外层 task 卡片消息 id(一层嵌套时与 parent 相同,多层嵌套时指向最顶层)。两者同时为 null 表示主对话流消息,APP 主聊天列表用 `parent_msg_id IS NULL` 过滤,不渲染子事件
  - 发送路径:plugin streamer 子 session 事件走 `sendCardMessage` / `sendTypedMessage` 时把这两个字段塞 content;server `ExtractParentRoot` 在写库前提取为独立列(migration 006),从 content 删除避免残留
  - IDOR 校验:`validateParentRoot` 在事务前校验 parent/root 都存在 + 都属本会话 + root 是顶层(parent_msg_id IS NULL),失败 fail-fast 不写库(对称 `validateQuote` 防跨会话伪造)
  - 未读计数:`parent_msg_id != null` 的消息**强制跳过** `IncrUnreadTx`(不依赖 plugin 标 content.silent),保证主列表展示口径与未读计数口径一致
  - 查询入口:`GET /api/conversations/:id/messages?root_msg_id=X` 返 root 下所有子事件(不含根本身),供 APP 子 agent 详情页渲染(tool_card / reasoning / markdown 子树)
  - dispatch payload 顶层带这两个字段(不在 content 内),server 实时 push 不过滤让 client 决定展示;APP 端 `chat_provider._filterDisplayable` + WS MESSAGE_CREATE 守卫据 `parent_msg_id != null` 过滤,确保子事件不涌入主聊天列表(旧版 APP 需升级带此过滤)

  **content.data 字段补充**(v1.0.6,server 端 `enhanceContentFromFile` 在持久化前从 files 表填):
  - `image` 类型:补 `width` / `height`(原图尺寸,client 渲染前即知比例零跳动)
  - `file` 类型:补 `file_size`(字节数) + `mime_type`(标准 MIME,如 `application/pdf`)
  - client → server 仅带 `file_id`(可选 `filename`),其他字段 server 权威补全;client 端 FileCard / ImageThumb 直接读字段决定布局,无需额外查 files 表;乐观消息可临时用扩展名推断 mime 占位,server 真值到达后覆盖

  **content.data 字段补充**(Phase 3,plugin engine.ensureSession 读):
  - `_directory`(可选,string):用户选的工作目录绝对路径。仅由 APP 在**首条消息**塞入(发完自动清除),用于 plugin ensureSession 透传给 OC session.create。第二+条消息不发 `_directory`(已建好 session 无效)。`_directory` 缺时 plugin 用 `Config.defaultDirectory`,都缺时 OC 用 PLUGIN_DIR(现状)。

  **content.data.quote 子对象**(消息引用功能,所有 msg_type 都可带):
  - client → server 发送时只带 `{"message_id": "被引用消息id"}`,其他字段可不传(server 会权威覆盖)
  - server `enrichQuote` 在持久化前用权威值覆盖全部字段:`message_id` / `sender_type` / `sender_id` / `sender_name`(查 users/agents 表) / `msg_type`(被引用消息原 msg_type) / `preview`(按被引用 msg_type 抽取,如 text 前 50 字 / image=`[图片]` / file=`[文件] 文件名` / 撤回消息=`[消息已撤回]`)
  - 校验 `validateQuote`:`quote.message_id` 必填 + 必须属本会话(防 IDOR 伪造引用其他会话消息泄漏 sender_name / preview);失败 fail-fast 不入事务
  - 被引用消息撤回后:`quoted.DeletedAt.Valid` 命中,preview 改写为 `[消息已撤回]`,仍允许发送(fail-soft)
  - client 端乐观消息可直接写**完整 snapshot**(sender_name + preview 来自本地 pendingQuote),让气泡上方引用块立即正确呈现,server 富化后用权威值覆盖
  - 渲染端只读 snapshot,**不回查**被引用消息(列表渲染零 N 查询);点击引用块跳转才走 `GET /api/messages/:id/context`

**消息删除 Dispatch 事件**（opcode 同为 0）：
- `MESSAGE_DELETE` — 消息删除。payload：`{ids, conversation_id, scope, ...}`，`scope` 取值：
  - `hide`（默认）：单播给当前请求者（只对我消失），payload 不含 sender 信息。client 端直接从 messages 列表移除。
  - `recall`：广播给会话全员（双向不可见），payload 附加 `sender_id` / `sender_type` / `sender_name`。client 端把消息切到 isRecalled 态保留渲染占位（不删 entry），dm 场景按 `sender_id == currentUserId` 切「你/对方撤回了一条消息」，群聊场景未来用 `sender_name` 拼 `${name} 撤回了一条消息`。

**审批相关 Dispatch 事件**（opcode 同为 0）：
- `MESSAGE_UPDATE`（双端，user+agent）— 消息内容更新。审批决策后双写 messages.content，广播此事件让 APP 端切换卡片终态（按钮置灰 + 徽章）。payload：`{message_id, conversation_id, content}`
  - **silent 翻转语义**（聚合卡模式）:聚合卡创建时 `silent=true`（过程态不响铃/不计未读），回合结束 plugin PATCH 显式带 `silent:false` + `state:"done"` 翻转。server `mergePreservedSilent` 规则：PATCH 显式带 silent 以新值为准，未带则保留原值；原 true→新 false 翻转时对**非 sender 全员 +1 未读**（`IncrUnread`，与发消息口径一致），随后广播 MESSAGE_UPDATE
  - **翻转广播附带 `data.preview`**:set_silent 翻转(false)时 server 从聚合卡 elements 取最后 markdown 正文写入 `data.preview`（落库 merged + 注入广播 delta）。增量广播本无 elements,通知 body / 会话列表摘要直接读 preview,APP 端无 markdown 元素时 fallback `[聚合回复]`
  - **翻转广播附带 sender 三件套 + 会话元信息**(v1.6.3):翻转广播 payload 为 `{message_id, conversation_id, content, conversation_type, conversation_title, sender_id, sender_name, sender_avatar_url}`。bg-service 弹通知直接消费 sender 字段(名字/头像下载),并回填本地会话发送者缓存——不再依赖 MESSAGE_CREATE 阶段的内存回查(bg-service 重启后回查必失败,曾导致通知 title fallback 'Agent' + 头像色块)。旧 client 忽略未知字段;旧 server 不带 sender 字段时 client 走内存回查 fallback 链
  - **APP 三处消费方**（识别 `msg_type==aggregate_card && silent==false` 才响应翻转）:bg-service 弹通知+计未读（sender 信息优先取广播 payload,缺失时回查 MESSAGE_CREATE 阶段缓存的会话发送者;body 取 `data.preview`）;conversation_provider / agent_sessions_provider 徽章+1+预览更新（取 `data.preview` 或最后 markdown 元素 text）+置顶排序。generating 阶段（silent 仍 true）的 PATCH 只刷新渲染不打扰
- `APPROVAL_DECIDED`（仅 agent）— 推决策结果。payload：`{approval_id, message_id, conversation_id, session_key, confirm_id, decision, reason, decided_by, decided_at}`。agent 拿 session_key + confirm_id 路由到等待协程（exec_approval 用 session_key 调 `resolve_gateway_approval`；slash_confirm 用 confirm_id 调 `slash_confirm.resolve`）
- `APPROVAL_EXPIRED`（仅 agent）— 超时通知。payload：`{approval_id, message_id, conversation_id, session_key, expired_at}`

**已读同步 Dispatch 事件**（opcode 同为 0）：
- `MESSAGE_READ`（仅 user,同 user 多端）— 多端已读同步。某 user 在某端调 markRead 后,server 广播给该 user 全部 WS 连接(含发起端,client 按 message_ids 去重避免重复处理)。让其他端立即同步徽章归零 + 当前 ChatPage 刷 firstUnread,无需下拉刷新。不广播给其他 user / agent(已读是个人维度)。payload：`{conversation_id, message_ids, unread_count, read_at}`

**会话信息变更 Dispatch 事件**（opcode 同为 0）：
- `CONVERSATION_UPDATE`（按触发源分两种 fanout）— 会话标题/头像变更通知。payload：`{conv_id, title, avatar_url}`,空串字段 = 客户端保留原值。
  - **user 触发**(`GroupHandler.Update` 全员广播):owner/admin 改群名 → `BroadcastConversationUpdate` 发给会话全员(含 agent)。agent 收到后由插件 `engine.handleConvUpdate` → `bridge.renameSession` 同步到 OC session 标题。
  - **agent 触发**(`UpdateTitleAsAgent` 仅 user 广播):OC 端改标题 → 插件调 REST PATCH 改 server DB → `BroadcastConversationUpdateToUsers` **只发 user 不发 agent**。物理断回环:插件收不到自己触发的标题回声,避免「插件改 OC → OC 回 updated → 插件又改 OC」的死循环。
- `SESSION_META_UPDATE`（仅 user,agent 触发）— agent_session 元数据(mode/model/variant/cwd/git_branch)实时刷新。plugin 调 `UpdateSessionMetaAsAgent` PATCH 写库后,server `BroadcastSessionMetaUpdateToUsers` **只发 user 不发 agent**(同 UpdateTitleAsAgent 物理断回环口径)。APP chatProvider 监听后整体替换 `chatState.sessionMeta`,SessionMetaStrip / EnvMetaStrip 实时刷新,不再依赖 agent 消息触发 2s 防抖拉取。plugin 在 `session.updated` / `vcs.branch.updated` / **`step-finish reason=stop`** 三种时机触发 PATCH(后者兜底用户在 shell 切分支场景,OC 不发 vcs 事件)。payload：`{conv_id, session_meta:{mode, model_id, provider_id, variant, model_name, provider_name, cwd, git_branch, tokens_total, context_used, context_limit}}`(后三者 v1.0.12 加,分别为会话累计 token / 当前上下文占用 / model 上下文上限)

**停止生成 Dispatch 事件**（opcode 同为 0）：
- `GENERATION_ABORT`（server→会话全员）— 停止生成信号。user 调 `POST /api/conversations/:id/abort` 后,server dispatch 给会话所有 participants。agent(plugin)收到后调 OpenCode SDK abort API 中止当前生成;user 端忽略此事件。payload：`{conversation_id}`。幂等:无生成在跑时 plugin 优雅忽略。

### 流式输出(op=14 Stream)

plugin 把 agent 生成中的 reasoning/text 按 300ms 节流推**全量快照**(累积全文,非增量碎片),让 APP 逐段渲染。server 纯透传给「正在看该会话」的 user 连接,agent 不消费。

**入站(plugin→server)**:`{op:14, d:{conversation_id, stream_id, msg_type, text, aggregate?}}`。`aggregate:{message_id, element_id}`(可选,聚合模式):帧不建独立占位气泡,而是定位 msg_type=aggregate_card 消息、全量替换 element_id 匹配元素的 data.text(终态仍由 plugin PATCH 持久化兜底,此处仅实时刷新观看端)。聚合模式流式定位细节(预留 seq / ensureStreamElement 占位)见 [aggregate-card.md](./aggregate-card.md)「流式定位」。缺 `aggregate` 字段 = 非聚合模式,走旧独立占位(兼容)。仅 agent 可发,IDOR 校验 `Hub.IsParticipant` fail-closed。server 调 `SendStreamToConvViewers`:查 participants,只推 `client.GetActiveConv()==conversation_id` 的 user 连接(op=3 SetActiveConv 上报的活跃会话)。op≠Dispatch 天然不进 dispatchBuffer,不带 seq,断线不补发。

**出站(server→APP)**:`{op:14, d:{...}}` 原样转发。APP `websocket_service` 的 `streamEvents` 流接收,不走 `_persistToStore`(不落本地 DB)。`ChatNotifier._listenStream` 按 stream_id 聚合:首块插占位(`id="stream:$streamId"`, `isStreaming=true`, client-only 内存态),后续块 copyWith 替换 text(不新增行)。

**终态替换**:part 结束后 plugin 发正常 `MESSAGE_CREATE`(op=0),content.data 附 `_stream_id`。server `persistAndDispatchOnce` **落库前从 content.data 剥离 `_stream_id`**(通用瞬态字段清理,参考 `ExtractParentRoot` 的 parent/root 剥离),广播 payload 保留。APP 收到终态 MESSAGE_CREATE 后按 `_stream_id` 同位置替换占位(清 isStreaming,剥离 `_stream_id`)。

**关键不变量**:流式是瞬态——op=14 不落库(server+APP 两端)、不计未读、不补发、不触发离线推送。终态 MESSAGE_CREATE 是唯一真相源(落库+计未读+Resume 补发)。APP 断网期间占位靠终态兜底(占位停在断点内容,终态到达后替换)。仅主 session 流式,子 session 攒满发整条。

**连接流程**：WS 建立 → 服务端发 Hello → 客户端发 Identify → 服务端验证 → 开始双向消息 → 客户端定期 Heartbeat。断线后客户端用 OpResume 携带最后 seq，服务端补发缺失的 Dispatch。

消息格式 (`WSMessage`)：`{ op, d, t, s }`，其中 `d` 为 JSON payload，`t` 为事件类型（仅 Dispatch 用），`s` 为序列号（用于 Resume）。

### 消息发送协议(client → server)

`MESSAGE_CREATE` client → server payload:**必须含 `conversation_id`,不再支持 `user_id` / `agent_id` 路由**(双轨制已废弃)。

```
{op:0, t:"MESSAGE_CREATE", d:{conversation_id, content:{msg_type, data}}}
```

会话建立走显式路径:
- agent 创建时 `agent_handler.Create` 内部建 owner↔agent 默认 conv(主兜底)
- agent 主动跟新 user 对话:client 调 `POST /api/agents/me/conversations` 拿 conv_id
- user 主动建会话:`POST /api/conversations`

`TYPING_START` payload 同样走 `conversation_id`,server 查 participants 转发给除 sender 外的所有 user:

```
{op:0, t:"TYPING_START", d:{conversation_id}}
```

### 未读感知(op=3 SetActiveConv)

未读计数语义在 participants 模型重构后**完全下沉到 client 端**:server 端 `MessageProcessor.PersistAndDispatch` 调 `IncrUnreadTx` **无条件给非 sender 全员 +1**(不再依赖 server 端「用户是否在看会话」判断),让 IM 列表徽章实时反映 N 方未读。client 端再据「正在看该会话」决定归零时机 + 是否弹通知。

**SetActiveConv (op=3) 仍保留,职责变更为「通知过滤信号」**:

1. **APP 进入 ChatPage**:initState 发 `{op:3, d:{conv_id: X}}` → `client.SetActiveConv(X)`
2. **APP 退出 ChatPage**:dispose 发 `{op:3, d:{conv_id: ""}}`(空 = 退出) → `client.SetActiveConv("")`
3. **client 端 IPC 同步**:`conversationProvider.setActiveConv` 除发 WS 外,还通过 `FlutterBackgroundService().invoke('setActiveConv', ...)` 同步到 bg-service isolate,让后台通知逻辑也感知(用户正在看的会话不弹系统通知,见通知节)
4. **bg-service 弹通知前判断**:`_appInForeground && convId == _activeConvId` → 跳过弹通知(用户已直接看到);其他情况(前台但不在该会话 / 在别的页面 / 后台)都弹
5. **client 端归零**:ChatPage `_markRead` 在底部时立即调 `POST /messages/read` 批量标已读 + 重算 unread_count(server 端用 ParticipantRepo.MarkMessagesReadTx 同事务更新 unread_count + last_read_message_id)

**关键约束**:`Client.activeConvID` 字段读写走 `sync.Mutex`(与 `seq` 字段并发模式一致)。Resume 之后才允许发 SetActiveConv(握手阶段只接 Identify)。多端(多个 WS 连接)各自独立上报。`hub.IsUserViewingConv` 已删(processor 无条件给非 sender 全员 +1,无消费方)。

### msg_type 目录

`content.msg_type` 标识消息内容类型，APP 端按类型查渲染器注册表（`ContentRendererRegistry`）分派渲染。

**基础消息类型**（user/agent 都可发）：

| msg_type | data 字段 | 用途 |
|---|---|---|
| `text` | `{text}` | 纯文本 |
| `markdown` | `{text}` | Markdown 富文本 |
| `image` | `{file_id, width?, height?}` | 图片消息（width/height 由 server 补全） |
| `file` | `{file_id, filename?, file_size?, mime_type?}` | 文件消息（file_size/mime_type 由 server 补全） |
| `mixed` | `{text?, items: [{type:'image'\|'file', file_id, filename?, mime_type?, file_size?}]}` | 图文/文件混排（text 为顶层字段；items 至少 1 个条目，file_id 必填；server 不富化 items，filename/mime_type/file_size 由发送端写入；dsh/hermes/opencode 消费） |
| `card` | `{card_type, ...}` | 审批卡片（见 approval-card.md） |
| `mini_program_card` | `{appid, title, params?}` | 小程序分享卡片（spec §8，APP shareToChat 发出）：点击冷启动/打开容器页 `/mini-program/:appid?conv=&launch=`，conv 携带来源会话供 getChatContext，params 为可选启动参数（URL 编码 JSON 透传入口 query） |
| `recalled` | — | 撤回占位（server 端写，client 识别后置 isRecalled） |

**Agent 过程消息类型**（仅 opencode-plugin streamer 发，展示 AI 思考/工具/步骤过程）：

| msg_type | data 字段 | 来源 | 用途 |
|---|---|---|---|
| `tui_user` | `{text}` | proxy syncPrompt | 用户在 TUI 输入的消息，APP 端归位为「我」侧气泡（紫色，带 📟 标记） |
| `reasoning` | `{text}` | streamer reasoning part.ended | AI 思考过程全文，APP 折叠为 1 行摘要 + 点击抽屉看全文 |
| `tool_call` | `{name, input}` | streamer tool part running | 工具调用入参。name 见下表，APP 按工具名分派图标和 body 渲染 |
| `tool_result` | `{name, output}` | streamer tool part completed | 工具执行结果。短输出直显，长输出截断 + 点击抽屉 |
| `tool_error` | `{name, error}` | streamer tool part error | 工具执行失败，红底 + 左红边框 |
| `step_finish` | `{reason, cost, tokens, duration}` | streamer step-finish part | 步骤完成元信息（耗时/token/费用），APP 渲染为元信息行 |
| `file_diff` | `{file, additions, deletions, diff}` | streamer tool completed (edit/write) | 文件变更卡片，header（文件名+统计）+ 点击抽屉看完整 diff。`diff` 为多行文本,行前缀协议:`+ ` 增 / `- ` 删(plugin `buildDiff` 生成,APP `tool_card_renderer` 按 `startsWith('+ '/'- ')` 染色,两端自洽) |
| `tool_card` | `{name, input, output?, error?, status, sub_session_id?, duration?, file_diff?}` | streamer tool part running/completed/error + PATCH 状态变更 | 工具调用统一卡片。`status`: `running`/`starting`/`working`/`completed`/`error`。task 工具特化:`status=starting/working/completed/error` + 带 `sub_session_id` 用于 APP 子 agent 详情页跳转,详见下方 task 子 Agent 章节 |
| `compact_divider` | `{phase}` | streamer compaction part | 对话压缩分割线。`phase`: `running`(正在压缩,3 点呼吸动画)/`done`(完成)/`failed`(失败,红字)。plugin 在 `/compact` 触发后通过 compaction part 事件插入并 PATCH 切态。重进会话可见(持久化)。 |

**tool_call 的 name 值**（APP 端按 name 分派图标：bash⚡/edit✏️/read📖/grep🔍/glob📂/todowrite📋/write📝/task🤖/question❓/默认🔧）：

- `task` — 子 Agent 调用，APP 在 tool_call 内部渲染 SubagentBody（紫色子 Agent 标签）
- `question` — 选择题工具，APP 在 tool_call 内部渲染 QuestionBody（选项列表）
- 其他工具名按图标表分派，body 统一渲染 JSON 入参预览

> `subagent` / `question` 在 APP `MsgType` 枚举中存在但 **streamer 不发为独立 msg_type**，它们是 `tool_call` 内 name=task/question 时 APP 端的渲染分派，不是 wire 协议类型。

**交互事件消息类型**（v1.0.8，opencode-plugin streamer 收到 SSE 后通过 REST POST 发，APP 底部抽屉处理）：

| msg_type | data 字段 | 来源 | 用途 |
|---|---|---|---|
| `permission_card` | `{oc_request_id, action, resources, status, save?}` | streamer `permission.v2.asked` → POST /api/conversations/:id/messages | 权限审批卡片，APP 渲染 pending 暖色 + 底部抽屉三选项 |
| `permission_reply` | `{oc_request_id, reply}` | APP 底部抽屉提交 → PATCH /api/messages/:id | 权限决策回传（once/always/reject），silent（APP 过滤不展示） |
| `question_card` | `{oc_request_id, questions: [{question, header, options?, multiple?, custom?}], status}` | streamer `question_asked` → POST /api/conversations/:id/messages | 选择题卡片，APP 渲染 TabBar 横向切换 + radio/checkbox/custom |
| `question_reply` | `{oc_request_id, answers: [string[]], rejected?: true}` | APP 底部抽屉提交 → PATCH /api/messages/:id | 选择题答案回传，silent（APP 过滤不展示） |

**聚合消息（aggregate_card）**（opencode-plugin，默认开启）— 一次问答一条聚合卡消息，elements[] 按时序承载全部步骤。协议结构、增量 PATCH、元素类型表、finished 标记、流式定位、跨轮瞬态清理、停止收尾、消息边界分段、状态呈现、工具卡折叠、样式、滚动补偿全部见 **[aggregate-card.md](./aggregate-card.md)**。

### AGENT_MODELS

plugin → server 单向事件。plugin 启动/重连时拉取 opencode `config.providers` 上报可选模型清单。**payload**: `{op:0, t:"AGENT_MODELS", d:{agent_id, models:[{provider_id, provider_name, model_id, model_name}], reported_at}}`。`provider_id`/`model_id` 为 opencode 全局约定标识（拼接为 `providerID/modelID`），`provider_name`/`model_name` 为可读名（plugin fallback 用 id 兜底）。无 status 字段（opencode connected 不可信）；空清单合法（plugin 未就绪）。

**安全守卫**: `senderType != "agent"` 拒绝（防 user 越权）；`payload.agent_id != senderID` 拒绝（防 plugin A 冒充上报 plugin B 的清单），空 agent_id 一并拒绝。**server 处理**: 写 `AgentRegistry` 内存缓存不广播（APP 走 REST 拉取）。**APP 拉取**: `GET /api/agents/:id/models`（见 rest-response.md）。

### AGENT_SLASH_CATALOG

plugin → server 单向事件。plugin 启动/重连时拉取 opencode `command.list` + `skill.list` 上报命令/技能清单（与 AGENT_MODELS 同期，均在 streamer.start() 触发）。**payload**: `{op:0, t:"AGENT_SLASH_CATALOG", d:{agent_id, commands:[{name, template, description?, source}], reported_at}}`。`source`: `"command"`（OC 命令）/`"skill"`（OC 技能），APP 据此分组渲染（命令组上、技能组下），plugin 自推的 `/compact` 也归 `source="command"`；`description` 可选（omitempty，APP 防空值）；空清单合法（plugin 未就绪）。

**commands 示例**（一项命令 + 一项技能）:
```jsonc
[
  {"name":"compact",      "template":"/compact",      "description":"压缩上下文", "source":"command"},
  {"name":"agently-mail", "template":"/agently-mail", "description":"邮件操作",   "source":"skill"}
]
```

**安全守卫**（对称 AGENT_MODELS）: `senderType != "agent"` 拒绝；`payload.agent_id != senderID` 拒绝，空 agent_id 一并拒绝。**server 处理**: 写 `SlashCatalogRegistry` 内存缓存不广播（APP 走 REST 拉取）。**APP 拉取**: `GET /api/agents/:id/slash-catalog`（见 rest-response.md）。
