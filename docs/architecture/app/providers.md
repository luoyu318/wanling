# APP Riverpod Providers

状态管理 15 个 provider:auth / agentList / conversation / chat / settings / savedLogins / typing / agentSessions / agentStatus / fileBrowser / friend / participant / sessionDiff / userSearch / localMessageStore(connState 定义在 chat_provider 内,非独立文件)。

## authProvider

认证（含 user 信息，restoreSession 调 /me）

## agentListProvider

Agent CRUD

## agentTypesProvider

agent type 注册表(GET `/api/agent-types`,wanling_core)。FutureProvider 非 autoDispose,登录周期内缓存;失败返空列表(调用方 fallback `AgentTypeInfo.fallbackTypes` 本地预置)。类型下拉(建/改 agent)与徽标查表数据源,新类型 server INSERT 后零发版可见。`multiSessionOfType(ref, type)` helper 供只有 type 字符串的场景查拓扑(chat AppBar 徽标显隐)。

## conversationProvider

IM 列表(订阅 MESSAGE_CREATE 本地更新预览 + 未读计数 + 置顶/隐藏状态;订阅 MESSAGE_DELETE 直接 `load()` 重拉列表,让撤回 / 隐藏即时反映到摘要和未读徽章;订阅 CONVERSATION_UPDATE 本地更新 title/avatarUrl,**空串字段不覆盖**(server Update handler 把未提供字段填空串广播,client ?? 只在 null 时 fallback 不够,空串也 fallback 才不会清空本地群名导致 displayName 走 participants.first 显示「随机成员名」);订阅 **MESSAGE_READ**(多端已读同步,server 推 → `setUnreadCountLocally` 立即刷徽章,不等下拉刷新))。`createGroup({memberUsernames, title, avatarUrl})` 方法(原 memberIds 已废弃,改用 username 因 spec §4.2 client 不持 user_id + server `resolveMemberUsernames` 反查)。`setActiveConv(convId)` 方法:发 WS op=3 上报正在看的会话,同时 `FlutterBackgroundService().invoke('setActiveConv', ...)` 同步到 bg-service isolate(让后台通知逻辑也感知,避免正在看的会话误弹通知)。`load()` 拉列表采用 **cache-first + state.isEmpty 守卫**:首次加载(state=[])用 cached 立即显示,后续下拉刷新(state 非空)跳过 cached 直接走 API,**防止 `_persistList` fire-and-forget 滞后写入时旧 cached 覆盖刚更新的 state**(leaveConversation / hide / removeByAgentId 后立即下拉刷新会闪现已移除会话)。`_mergeConversation` 用 `fresh.unreadCount`(原 max(local, fresh) 在跨设备同步场景下反向 — A 设备已读 server unread=0,B 设备 local 仍是旧 N,max 保留旧值;dispatch 在 commit 后,server 的 IncrUnread 已在 fresh,本地 +1 是冗余 optimistic,直接用 fresh 永远对)。`load()` 拉列表成功后调 `syncAgentAvatarsToBgService`,把每个 agent 的 avatar_url 经 IPC 同步到 isolate(**仅作 bg-service 老 server 兜底用**,主路径走 dispatch payload 的 `sender_avatar_url`,见 `background_chat_service.dart`)。

## chatProvider

family，key 是 record `({convId, agentId})`。**双 list 数据流**(2026-07-31):`ChatState` 拆 `historyMessages`(newest-first,[0]=最新贴近锚点) + `liveMessages`(oldest-first,末尾=最新),双 sliver CustomScrollView 各渲染一 list。`displayMessages` getter 合并两 list 全局降序去重供消费方(浮标/定位)。`isInitialLoading` 仅即时呈现(DB eager hit 提前置 false),`isServerInitialized` 等 server 三分支(getConversation+getUnreadInfo+getMessages)全完成才置 true——pendingInitialScroll 等底部输入区稳定(convType/sessionMeta 就绪)的定位逻辑以此为据。订阅 MESSAGE_DELETE：`scope=recall` 时把消息切到 `isRecalled=true` 保留占位（不删 entry）+ 缓存 `recalledByName` 供群聊场景显示；`scope=hide` 时直接从 messages 列表移除。订阅 **MESSAGE_READ**(多端已读同步:其他端 markRead → server 推 → 刷本会话 `unreadCount` + `clearFirstUnread` 标志位清 `firstUnreadMessageId`,让当前 ChatPage 立即切已读样式,不需退出再进重拉 UnreadInfo;仅处理本会话事件,其他会话由 conversationProvider 处理徽章)。**session meta 双向同步**(v1.0.9,仅 agent_session):`ChatState` 加 `sessionMeta` + `modeOverride` 字段,`_initialize` 拉服务端权威 sessionMeta 初始化;`toggleMode()` 在 Build↔Plan 之间切换,写入 `modeOverride` 让 UI 立即响应(不等 server 回包);`sendText(text, _mode)` 把当前 mode 随消息 content.data._mode 一起发,plugin engine 透传给 OC SDK 切 agent 处理本条消息;`_refreshSessionMeta()` agent 回复到达后 2s 防抖拉服务端最新 sessionMeta(让 OC 端真实切换的 mode 反向同步回 APP);**`_listenSessionMetaUpdate()`**(v1.0.11)订阅 WS `SESSION_META_UPDATE` 事件,plugin PATCH session-meta 后 server 广播给 user 端,直接整体替换 `chatState.sessionMeta`,SessionMetaStrip / EnvMetaStrip 即时刷新(不再依赖 2s 防抖,原路径只能拉到 plugin 上次写入的快照);**override 与 server 冲突时清除 override**(说明 OC 端已切到其他 mode,本地 override 失效)。**mode/model 是消息级属性**(SDK Session 无此字段),靠 sessionMeta + modeOverride 本地状态 + 服务端权威值兜底。同文件还有 `wsProvider`（仅 watch `authProvider.token`，token 变化才重建 WS，避免 updateProfile 刷新 user 触发误断连）和 `connStateProvider`（StreamProvider 桥接 `wsProvider.connectionStateStream`，订阅期先同步推一次 currentConnState 防 banner 误判）和 `localStoreHealthProvider`(订阅 ws.localStoreHealthStream,LocalStoreBanner 据此显示)。banner 必须订阅 connStateProvider 而非直接 read wsProvider——切换账号时 wsProvider 重建，直接订阅会监听到已 dispose 的旧实例。

## settingsProvider

服务器地址（baseUrl，默认 `http://localhost:18008`）。被 main/auth/chat/avatar 多处引用。**设置 UI 入口已隐藏**，baseUrl 现由切换账号流程按账号保存值同步覆盖。

## savedLoginsProvider

多账号管理（`secure_storage` 加密存储历史登录）。`switchTo(index)` 是核心编排：`setSwitching(true)` → `logout(silent:true)`（保留 isSwitching）→ `select(index)` → `onLogin` 注入（invalidate apiProvider + `settingsProvider.setBaseUrl` + login）→ finally `setSwitching(false)`。AuthState 的 `isSwitching` 标志让路由守卫和 banner 在过渡期不误判（见 router.dart 和 ConnectionBanner）。

## typingProvider

输入指示器（"对方正在输入..."）。**双重订阅**：`ws.typingStream`（TYPING_START）→ startTyping 标记；`ws.messages`（agent 的 MESSAGE_CREATE）→ clearTyping 清掉。clearTyping 放全局 provider 而非 ChatPage 内订阅，是为了「用户已离开 ChatPage / 切到别的会话」时 typing 也能被清掉（否则「正在输入」会卡住不消失）。

## localMessageStoreProvider

`FutureProvider.autoDispose<LocalMessageStore>`（实为 `LocalMessageDatabase`，业务侧用 extension 接口）。依赖 `authProvider.user.id`，open 是 async（SQLCipher 密钥 IO + DB 文件 IO），拿到 store 后供 `chatProvider` / `conversationProvider` 订阅消息流和列表，供 `websocket_service` hello 分支读 `getGlobalLastSeq` 作 Resume `last_seq`。账号切换 / 登出时 autoDispose 自动 `close()` 释放句柄。

## agentSessionsProvider

agent_session 二级列表状态管理（对齐 conversationProvider 模式，family by agentId）。`StateNotifier<List<Conversation>?>`，null = 首次加载中。监听 WS MESSAGE_CREATE / MESSAGE_UPDATE / MESSAGE_READ 本地 copyWith 更新 last_message + unread + pendingCount + **lastAgentReplyContent**（0 延迟，不调 API）。lastAgentReplyContent 实时派生规则（2026-08-05 起，原 lastUserMessageContent「最后一条用户指令」废弃）：仅 agent 发的**非 silent** text/markdown 更新,与 server SQL 的 `msg_type IN ('text','markdown') AND silent IS DISTINCT FROM 'true'` 对齐,过程消息(reasoning/step_finish/tool_card)不覆盖简介;**2026-08-10 起聚合卡回合结束翻转也更新**(取 `data.preview`,对齐 server SQL 对 aggregate_card 的摘要口径;增量 set_silent 翻转走 load() 拉 server 全量)。新 session（agent 发消息）自动 `load()` 拉入。`createSession({directory})` user 主动建 agent_session 群（directory 透传 server conversations.directory 一级列）。二级列表目录面板（DirectoryPanel）+ pendingCount 实时增减靠本 provider

## agentStatusProvider

Agent 状态聚合（`StateNotifier<Map<String, AgentStatus>>`，key=agentId）。聚合 typing + pending approval 数 → 三态（idle/busy/retry）供二级列表 SessionTile 三体指示器 + 目录面板 busyCount + chat_page 状态文案。监听 `wsProvider.messages`（agent MESSAGE_CREATE 清 busy）+ `typingProvider`（typing → busy）+ `chatProvider` 的 pending approval 数

## fileBrowserProvider

文件浏览器状态（`StateNotifierProvider.autoDispose.family` by `(agentId, convId)`）。`FileBrowserState` 含 currentPath（当前目录）+ pathStack（路径回溯栈）+ entries（`AsyncValue<List<FileEntry>>`，truncated 标记 >500 项）+ previewContent（`AsyncValue<FileContent>?`，全屏预览态）。Notifier 方法：`loadDirectory`（RPC `file.list`）/ `enterDirectory` / `goUp` / `popTo`（按路径重算 pathStack，cwd 断点修复用）/ `loadFileContent`（RPC `file.read`，FilePreviewPage 触发）/ `clearFileContent`（FilePreviewPage dispose 时清空）。autoDispose 离开 FileBrowserPage 自动释放

## participantProvider

单会话参与者列表（`StateNotifierProvider.family` by convId）。供 ConversationDetailPage 渲染群成员 / 踢人（邀请成员当前为占位，待好友系统开放）。`kick` 调 server 后靠 CONVERSATION_PARTICIPANT_JOIN/LEAVE 事件触发 `refresh()` 重拉。单独 provider（非复用 conversationProvider.list[convId].participants）避免每次 list 变化重建

## sessionDiffProvider

会话变更列表（`StateNotifierProvider.autoDispose.family` by `(agentId, convId)`）。`AsyncValue<List<SessionDiffFile>>`，调 RPC `session.diff` 拉本 session 累计文件变更。供 SessionDiffPage 渲染，SessionDiffFilePage 按 idx 取单文件 patch。autoDispose 离开页面释放

## 好友 / 用户搜索 provider（UI 未开放，代码保留）

`friendProvider`（好友聚合三列表 + WS 事件同步）+ `userSearchProvider`（username 模糊搜索 500ms 防抖）代码完整保留，但好友/群组 UI 入口已下线，当前无页面可达。详见 [pages.md](./pages.md)「好友 / 群组页面」节
