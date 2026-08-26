# APP Pages

lib/pages/ 目录下的 27 个 page(含 `pages/chat/` 子目录)。

## SplashPage

启动闪屏，决定走登录还是主页

## LoginPage / SelectAccountPage

登录/注册 + 已保存账号选择（多账号）。`SelectAccountPage` 选中账号后触发与切换面板相同的登录注入流程

## HomePage

Scaffold + BottomNavigationBar（3 tab 容器）

## MessagesPage

消息 tab，IM 风格列表（未读小红点 + 置顶分组）

## AgentListPage

Agent tab，紧凑列表（行点击 → 聊天；头像点击 → 详情）

## AgentDetailPage

详情：密钥眼睛切换 + 复制 + 编辑/删除 + 发消息 CTA。编辑资料对话框含类型下拉（普通/OpenCode），保存时 PUT type 字段

## AgentSessionsPage

**多 session agent(opencode/dsh 等)session 群二级列表页**。从一级列表/AgentListPage 点多 session type agent 入口进入（路由判据:server 注册表 `multi_session`,普通 type 直接跳 ChatPage）。`GET /api/agents/:agentId/sessions` 拉该 agent 下所有 agent_session 群。IM 风格紧凑列表（Avatar 48px + 标题 + 相对时间 + 分割线 + 按压反馈 + RefreshIndicator），点击进对应 session 的 ChatPage

## ChatPage

聊天，入参 `(convId, agentId)` record。**2026-07-11 重构为协调者**(2497→799 行),**2026-07-31 双 sliver 改造**后 ~1255 行(CustomScrollView.center 双 sliver + 骨架屏集成)。逻辑委托给 `widgets/chat/` 下的 9 个 controller + 3 个 listener/builder(详见 [chat-components.md](./chat-components.md))。ChatPage 保留跨职责协调：`_bubbleKeys` / `_selectionKey` / `_selectedText`(选择态)、`_confirmDelete`(菜单+多选共用)、`_onScroll` / `_isTyping` / `_isChatReady`(骨架屏)/`_markChatReady()`(三信号统一 latch)。

**isMe 覆盖**(v1.0.7): `MsgTypeX.fromString(msgType) == MsgType.tuiUser` 时强制 isMe=true。**agent_session 排版分支**(v1.0.9): ChatInputBar 按 convType 分流，agent_session 走 v5 样式(白底/直角/模式色 Build 蓝 `#597BFF` / Plan 橙 `#F4A742` + SessionMetaStrip 副标题条 + EnvMetaStrip 环境信息条 v1.0.10)，dm/群聊走原胶囊绿。**双 sliver**(v1.0.13): CustomScrollView.center 双 sliver(history leading / live trailing),`dualSliverBottomTarget` 统一底部目标计算,`DualSliverClampingPhysics` 阻止下滑空白,顶部分割线"下滑查看历史消息"兼空屏容错。**首屏骨架屏**(v1.0.13): ChatLoadingSkeleton 6 块 shimmer 盖住 server 就绪前空白,200ms 渐变淡出。**未读定位**：进会话 GET unread → 有未读则游标分页一次加载 → UnreadLocatorController 跨 sliver 定位 + 渲染 UnreadSeparator。**loadMore**：上滑 50% 阈值 LoadMoreController 触发(ListBefore 每次 50 条,leading 侧)。**已读追踪**：UnreadTrackerController 滚动时检测视口内未读 → 500ms debounce 批量标已读。**流式渲染**(v1.0.13): SSE STREAM 逐段推送,isStreaming 消息用 StreamingText 整段 markdown 渲染(2026-08-05 起,原逐字符渐显已废弃,见 [chat-components.md](./chat-components.md#streamingtext))。**浮标互斥**：unreadCount>0 && !isAtBottom → 绿色 UnreadNavBadge；unreadCount==0 && !isAtBottom → 白色 JumpToBottomButton。**长按菜单**：MessageMenuController 弹浮动菜单(复制/引用/删除/多选/撤回)。**多选**：MultiSelectController 管理选中态 + 顶部深色 AppBar + 底部 SelectionBottomBar。**撤回**：isRecalled 渲染 RecalledBubble。**AppBar 副标题**仅 dm_user_agent 场景渲染，不依赖 widget.agentId(通知跳转会占位 senderId)。**文件下载**(v1.0.6)：FileDownloadController 管理，详见 [chat-components.md](./chat-components.md)

## SubagentDetailPage

**子 Agent 详情页**(v1.0.10)。从 ChatPage task 卡片点击跳转,路由 `/chat/subagent/:taskCardId?convId=:convId`(必须排在 `/chat/:convId` 之前,否则 GoRouter 把 'subagent' 当成 convId)。展示某 task 卡片下挂的全部子 agent 事件流(reasoning / tool_card / markdown 子树)。数据来源:HTTP `api.getSubagentMessages(convId, taskCardId)` 拉 root 子树 + WS 双订阅(MESSAGE_CREATE 按 root_msg_id 过滤追加 / MESSAGE_UPDATE 按 message_id 替换条目内容,同步 task 卡片 running→completed 终态)。MessageRenderContext 注入 convId/messageId 让嵌套 task 卡片跳转可用,空 convId/taskCardId 时 router 直接返错误页

## ProfilePage

我的 tab 入口，展示用户信息 + 头像。设置项分组：切换账号（≥2 账号才显示，拉起 `SwitchAccountSheet`）/ 通知权限跳转 / 修改密码 / 关于 / 退出登录。**原设置内页入口已隐藏**

## ScanPairPage / PairSelectAgentPage

扫码配对两件套（见「扫码配对」节），AgentListPage 右上角 `+` 拉起

## 好友 / 群组页面（UI 未开放，代码保留）

以下 4 个页面 **UI 入口已下线**（ProfilePage 无好友入口、MessagesPage 无建群按钮、ConversationDetail 邀请成员为占位 SnackBar），但页面文件 + 路由 + provider + server handler 全部保留，互相跳转形成孤儿闭环，待重新开放时接通入口：

- **CreateGroupPage**（`/conversations/new/group`）— 多选好友建群，`conversationProvider.createGroup(memberUsernames:)` → server `resolveMemberUsernames` 反查 user_id
- **FriendsListPage**（`/friends`）— 三 Tab 好友中心（我的好友/收到请求/已发出请求），`friendListProvider` 三列表 + WS 事件同步
- **AddFriendPage**（`/friends/add`）— username 搜索加好友，`userSearchProvider` 500ms 防抖
- **UserDetailPage**（`/user/:username`）— 用户资料 + 三态加好友按钮

## EditProfilePage / CropAvatarPage / ChangePasswordPage

个人资料编辑三件套

## TextPreviewPage

**文本文件全屏预览页**(v1.0.6)。FileContentRenderer 点击 txt/md/csv 文件时 push 此页,通过 `GET /api/files/:id` 下载字节流后 UTF-8 解码(`allowMalformed: true` 防非法字节崩) → `SelectableText` 渲染(monospace + 1.5 行高)。大文件 >512KB 截断前 512KB,末尾灰色斜体提示"文件较大,仅预览前 512KB"。AppBar 显示文件名

## AboutPage

关于（用 `package_info_plus` 取版本号）。**`SettingsPage` 已移除**（服务器地址配置内页废弃），设置入口在 ProfilePage 暂时隐藏；服务器地址现在由「切换账号」流程管理（见 `savedLoginsProvider.switchTo`，切换时按账号保存的 baseUrl 同步到 `settingsProvider`）。`settingsProvider`（baseUrl）仍被 main/auth/chat/avatar 多处引用，未删

## ConversationDetailPage

**会话详情页**（v1.0.12，路由 `/conversations/:id/detail`）。N 方 participants 模型的「群资料 / 1-1 资料」统一入口，**按 `conv.type` 三分支分流**：
- `agent_session` — Session 卡片头（头像 + agent 昵称 + 创建时间相对值 + AgentBadge）+ SessionEnvGroup（环境信息：cwd/gitBranch）+ ContextCard（上下文使用进度，读 `sessionMeta.tokensTotal/contextUsed/contextLimit`）+ 置顶/隐藏/删除（走 hide 软删除）。删除后 `agentSessionsProvider.removeLocally` 即时清二级列表
- `dm_user_agent` — Agent 卡片头（头像 + 昵称 + AgentBadge + 查看资料入口）+ 头像点击放大 + 置顶/隐藏/删除
- `group_user` / `dm_user_user` / `group_mixed` — 通用群资料：可编辑群名/群头像（owner/admin 权限）+ 成员列表（`participantProvider`）+ 邀请成员（**当前占位 SnackBar「好友系统启用后将开放邀请」**）+ 置顶/隐藏 + 退出（群=退群/销群，1-1=删除会话）

权限 UI：群名/群头像编辑按钮仅 owner/admin 可见。数据源 `api.getConversation(convId)` + `participantProvider`

## FileBrowserPage `[chat/]`

**文件浏览器页**（Phase 5，路由 `/file-browser/:agentId/:convId?cwd=`）。单栏 iOS Files 风格（2026-07 重做，废弃原双栏 VSCode 布局）。`Scaffold` 灰底（`#F2F2F7`）+ `ListView` 分组渲染：文件夹卡片组（`_CardGroup` + `_EntryTile`，目录优先字母序）+ 文件卡片组，`_SectionLabel` 分节标题。AppBar 居中显示当前目录名 + 副标题「从 XX 进入」（提示从 cwd 跳来时的父目录）。RPC `file.list` 拉目录项，truncated 时尾部灰字「目录项过多,只显示前 500 项」。点击目录 → `enterDirectory` 入栈 + 切换；点击文件 → `Navigator.push` 全屏跳 `FilePreviewPage`。系统返回键 `PopScope`：子目录 `goUp`、根目录退出页面。`fileBrowserProvider`（autoDispose.family）管路径栈 + 当前预览内容。**cwd 断点修复**：`initState` postFrame 调 `_applyCwd` → `notifier.popTo(cwd)` 重算 pathStack 后定位到 cwd 子目录（避免停在根）。cwd query 参数兜底 server session_meta 无 directory 场景。entries 错误（RpcException）显示重试按钮

## FilePreviewPage `[chat/]`

**全屏文件预览页**（2026-07 新增，由 `FileBrowserPage` 点击文件条目 push 进入，非路由页）。入参 `(browserKey, entry)`。通过共享的 `fileBrowserProvider` 调 `loadFileContent` RPC `file.read` 拉文件内容，`previewContent`（`AsyncValue<FileContent>`）按类型分流：`_PreviewBody` 文本走 `code_highlight_view` 语法高亮 / `_ImageBody` 图片 / 二进制「不支持预览」占位。AppBar 显示文件名 + 体积副标题，actions 含复制（`Clipboard.setData` + SnackBar 反馈）/ 分享 / 下载菜单。`dispose` 时 `scheduleMicrotask(clearFileContent)` 清空预览状态（避免回到列表时残留上一次内容）。loading 态全屏 `CircularProgressIndicator`，error 态显示重试

## SessionDiffPage

**会话变更概览页**（路由 `/session-diff/:agentId/:convId`）。RPC `session.diff` 拉本 session 累计的文件变更列表，按文件展示 additions/deletions 统计 + status（added/modified/deleted）色标。点击单文件条目 push `SessionDiffFilePage` 看完整 patch。AppBar 标题「本次变更」+ Session 副标题（agent 昵称 + 相对时间）。数据源 `sessionDiffProvider`（autoDispose.family），错误态显示重试

## SessionDiffFilePage

**单文件 diff 全屏页**（路由 `/session-diff-file/:agentId/:convId`，idx 通过查询参数或状态传递）。展示某文件的完整 unified diff patch（`DiffPatchViewer` 语法高亮 +/- 行）。从 `sessionDiffProvider` 的文件列表按 idx 取单文件 patch。纯展示页
