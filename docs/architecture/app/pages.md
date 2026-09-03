# APP Pages

lib/pages/ 目录下的 31 个 page(含 `pages/chat/` 子目录;TextPreviewPage 实现在 wanling_core/widgets)。

## SplashPage

启动闪屏，决定走登录还是主页

## LoginPage / SelectAccountPage

登录/注册 + 已保存账号选择（多账号）。`SelectAccountPage` 选中账号后触发与切换面板相同的登录注入流程

## HomePage

主容器：动态底部导航(NavTabBar：消息/万灵/小程序固定槽 + pinned agent 头像槽 + conv: 会话槽 + mp: 小程序槽 + 可选「更多」槽) + NestedPageView 多页(页 0 = 消息+万灵 A 组合页,页 1..N = pinned agent sessions 页,小程序固定槽平铺内嵌小程序列表页)。槽位溢出(≥4 个 pinned)收进「更多」底部抽屉点选切换;pin 收缩时页码越界自动回 A 组页。conv: 会话槽点击按消息列表逻辑路由(与消息列表一致:multi_session→sessions 页,其余→聊天页),不占平铺页

## NavEditPage

底栏编辑页(`/nav-edit`,更多抽屉「编辑」/抽屉项长按/底栏槽长按兜底进入)：上半溢出项网格池 + 底部白条主排序区(底栏实时预览)。支持会话槽渲染与减号 unpin,白条整条拖拽换位/拖出收进更多,拖拽 move 语义实时持久化;固定项无减号不可移除

## MessagesPage

消息 tab，IM 风格列表（未读小红点 + 置顶分组）

## AgentListPage

Agent tab，紧凑列表（行点击 → 聊天；头像点击 → 详情）

## AgentDetailPage

详情：密钥眼睛切换 + 复制 + 编辑/删除 + 发消息 CTA。编辑资料对话框含类型下拉（普通/OpenCode），保存时 PUT type 字段。SettingsGroup 含「授权密钥」入口（Icons.key_outlined,置于「重置密钥」前,轻量操作优先破坏性垫底）→ `subKeysRoute()` 跳 AgentSubKeysPage

## AgentSubKeysPage

**授权密钥管理页**（路由 `/agent/:agentId/subkeys`,与 `/agent/:agentId/sessions` 相邻注册）。顶部说明文案（「授权密钥仅供 REST 调用,不能建立长连接;重置主密钥将同时吊销全部授权密钥」）+ FutureBuilder 列表：名称/创建于/最后使用（`formatRelativeTime`,无记录「从未使用」）/状态「生效中·已吊销」,已吊销整行置灰无吊销按钮。吊销 `showAppDialog` 确认（「吊销后该密钥不能再换新 token,已签发 token 过期前仍有效」）→ `revokeSubKey` → snackbar + 重拉列表。数据源 wanling_core `listSubKeys`/`revokeSubKey`（协议见 [agent-subkeys.md](../../ai-handbook/agent-subkeys.md)）;`AgentSubKeyInfo` model 对 last_used_at/revoked_at **字段缺席与显式 null 均容忍**

## AgentSessionsPage

**多 session agent(opencode/dsh 等)session 群二级列表页**,双模式:路由页(`embedded=false`,从一级列表/AgentListPage 点多 session type agent 进入,AppBar 带 pin 按钮（支持新账号首次 pin）)与底栏 embedded 模式(`embedded=true`,HomePage PageView 页挂载:无返回键 + AppBar 带实心 pin 按钮固定/取消固定底栏(仅 multiSession agent 渲染,防御门控) + AutomaticKeepAliveClientMixin 保活)。`GET /api/agents/:agentId/sessions` 拉该 agent 下所有 agent_session 群。IM 风格紧凑列表（Avatar 48px + 标题 + 相对时间 + 分割线 + 按压反馈 + RefreshIndicator），点击进对应 session 的 ChatPage

## ChatPage

聊天，入参 `(convId, agentId)` record。**2026-07-11 重构为协调者**(2497→799 行),**2026-07-31 双 sliver 改造**后 ~1255 行(CustomScrollView.center 双 sliver + 骨架屏集成)。逻辑委托给 `widgets/chat/` 下的 9 个 controller + 3 个 listener/builder(详见 [chat-components.md](./chat-components.md))。ChatPage 保留跨职责协调：`_bubbleKeys` / `_selectionKey` / `_selectedText`(选择态)、`_confirmDelete`(菜单+多选共用)、`_onScroll` / `_isTyping` / `_isChatReady`(骨架屏)/`_markChatReady()`(三信号统一 latch)。

**isMe 覆盖**(v1.0.7): `MsgTypeX.fromString(msgType) == MsgType.tuiUser` 时强制 isMe=true。**agent_session 排版分支**(v1.0.9): ChatInputBar 按 convType 分流，agent_session 走 v5 样式(白底/直角/模式色 Build 蓝 `#597BFF` / Plan 橙 `#F4A742` + SessionMetaStrip 副标题条 + EnvMetaStrip 环境信息条 v1.0.10)，dm/群聊走原胶囊绿。**双 sliver**(v1.0.13): CustomScrollView.center 双 sliver(history leading / live trailing),`dualSliverBottomTarget` 统一底部目标计算,`DualSliverClampingPhysics` 阻止下滑空白,顶部分割线"下滑查看历史消息"兼空屏容错。**首屏骨架屏**(v1.0.13): ChatLoadingSkeleton 6 块 shimmer 盖住 server 就绪前空白,200ms 渐变淡出。**未读定位**：进会话 GET unread → 有未读则游标分页一次加载 → UnreadLocatorController 跨 sliver 定位 + 渲染 UnreadSeparator。**loadMore**：上滑 50% 阈值 LoadMoreController 触发(ListBefore 每次 50 条,leading 侧)。**已读追踪**：UnreadTrackerController 滚动时检测视口内未读 → 500ms debounce 批量标已读。**流式渲染**(v1.0.13): SSE STREAM 逐段推送,isStreaming 消息用 StreamingText 整段 markdown 渲染(2026-08-05 起,原逐字符渐显已废弃,见 [chat-components.md](./chat-components.md#streamingtext))。**浮标互斥**：unreadCount>0 && !isAtBottom → 绿色 UnreadNavBadge；unreadCount==0 && !isAtBottom → 白色 JumpToBottomButton。**长按菜单**：MessageMenuController 弹浮动菜单(复制/引用/删除/多选/撤回)。**多选**：MultiSelectController 管理选中态 + 顶部深色 AppBar + 底部 SelectionBottomBar。**撤回**：isRecalled 渲染 RecalledBubble。**AppBar 副标题**仅 dm_user_agent 场景渲染，不依赖 widget.agentId(通知跳转会占位 senderId)。**文件下载**(v1.0.6)：FileDownloadController 管理，详见 [chat-components.md](./chat-components.md)

## SubagentDetailPage

**子 Agent 详情页**(v1.0.10)。从 ChatPage task 卡片点击跳转,路由 `/chat/subagent/:taskCardId?convId=:convId`(必须排在 `/chat/:convId` 之前,否则 GoRouter 把 'subagent' 当成 convId)。展示某 task 卡片下挂的全部子 agent 事件流(reasoning / tool_card / markdown 子树)。数据来源:HTTP `api.getSubagentMessages(convId, taskCardId)` 拉 root 子树 + WS 双订阅(MESSAGE_CREATE 按 root_msg_id 过滤追加 / MESSAGE_UPDATE 按 message_id 替换条目内容,同步 task 卡片 running→completed 终态)。MessageRenderContext 注入 convId/messageId 让嵌套 task 卡片跳转可用,空 convId/taskCardId 时 router 直接返错误页

## ScanPairPage / PairSelectAgentPage / PairAgentActionSheet

扫码配对两件套 + 三选弹窗（见「扫码配对」节），AgentListPage 右上角 `+` 拉起。选已有 agent 由 `pair_agent_action_sheet.dart` 弹**三选**：授权（发子密钥不碰主密钥,备注输入 placeholder「技能授权」,直接 `pairComplete(action:'authorize', note)`）/ 接管绑定（红字「重置主密钥,原绑定将失效」,保留既有二次确认,显式传 `action:'bind'`）/ 取消。sheet 独立文件（`showPairAgentActionSheet()` 返回 `(action, note)?` record）便于独立单测

## 好友 / 群组页面（UI 未开放，代码保留）

以下 4 个页面 **UI 入口已下线**（侧滑栏无好友入口、MessagesPage 无建群按钮、ConversationDetail 邀请成员为占位 SnackBar），但页面文件 + 路由 + provider + server handler 全部保留，互相跳转形成孤儿闭环，待重新开放时接通入口：

- **CreateGroupPage**（`/conversations/new/group`）— 多选好友建群，`conversationProvider.createGroup(memberUsernames:)` → server `resolveMemberUsernames` 反查 user_id
- **FriendsListPage**（`/friends`）— 三 Tab 好友中心（我的好友/收到请求/已发出请求），`friendListProvider` 三列表 + WS 事件同步
- **AddFriendPage**（`/friends/add`）— username 搜索加好友，`userSearchProvider` 500ms 防抖
- **UserDetailPage**（`/user/:username`）— 用户资料 + 三态加好友按钮

## EditProfilePage / CropAvatarPage / ChangePasswordPage

个人资料编辑三件套

## TextPreviewPage

**文本文件全屏预览页**(v1.0.6)。FileContentRenderer 点击 txt/md/csv 文件时 push 此页,通过 `GET /api/files/:id` 下载字节流后 UTF-8 解码(`allowMalformed: true` 防非法字节崩) → `SelectableText` 渲染(monospace + 1.5 行高)。大文件 >512KB 截断前 512KB,末尾灰色斜体提示"文件较大,仅预览前 512KB"。AppBar 显示文件名

## AboutPage

关于（用 `package_info_plus` 取版本号）。**`SettingsPage` 已移除**（服务器地址配置内页废弃），设置入口在侧滑栏主面板(SidebarProfilePanel)；服务器地址现在由「切换账号」流程管理（见 `savedLoginsProvider.switchTo`，切换时按账号保存的 baseUrl 同步到 `settingsProvider`）。`settingsProvider`（baseUrl）仍被 main/auth/chat/avatar 多处引用，未删

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

## MiniProgramListPage

**小程序列表页**（路由 `/mini-programs`，设置侧滑栏入口，见 sidebar_profile_panel）。数据源 `miniProgramsProvider`，按 status 分两组渲染：公共库（published）+ 我的（private/disabled，带删除按钮）。上传按钮 → file_picker 选 zip → `MiniProgramService.uploadPackage` 建私有 → invalidate 刷新。删除不可逆（远端 + 本地包 + WebView storage + **KVS `deleteMpPerms` 清授权**（M2，重装后重新弹权限申请））先弹确认框。点击条目 `context.push('/mini-program/${mp.appid}')` 进容器页

## MiniProgramPage

**小程序 WebView 容器页**（路由 `/mini-program/:appid`，M2 起可选 query `conv`（来源会话）与 `launch`（卡片 params，URL 编码 JSON））。origin 隔离：每小程序独立虚拟域名 `https://<appid>.<user_id>.mini.wanling.local`（host 含账号段，隔离多账号 storage）。启动流程：TokenVault 取 token → `MiniProgramService.installedDir` 命中即用 / 未装或版本旧则 `install`（下载 → sha256 校验 fail-fast → 解压到 `documents/miniprograms/<appid>/<version>/` 原子替换）→ **`_ensurePermissions` chat 权限授权流程**：KVS `getMpPerms` 读已授权集 → 未决 `wanling.chat.*` 逐个弹权限确认框（拒绝/点遮罩视为拒绝）→ `putMpPerms` 持久化增量 → `effectivePermissions(declared, granted)` 算有效权限集（非 chat 权限不弹窗直接生效）；拒绝项不进 granted，bridge 持续拒绝。`shouldInterceptRequest`：`/api/` 路径经 `proxyApiResource` 用宿主 ApiService 带登录态代理回源（仅 GET，非 GET 405 / 上游失败 502 / 点段归一化防路径混淆），其余从本地包读文件（`resolveLocalFile` 包根越界 403 / 缺失 404 + MIME 映射）；`shouldOverrideUrlLoading` 仅放行本 appid 虚拟 origin，外链一律拦截。JS 侧经注入的 `window.wanling.request/close/getChatContext/shareToChat` 四桥 → `MiniProgramBridge` 门禁（token 不进 JS，权限/`/api/` 路径白名单）→ `apiProvider.proxyRequest` 原生代理；**conv/launch 注入**：conv 经 `onChatContext` 回调供 getChatContext，launch 透传入口 URL query（H5 URLSearchParams 自取，不进 bridge）；**shareToChat** 校验仅 published 可分享 → 弹会话选择器 → `mini_program_card` 发消息。disabled 状态渲染「已被管理员停用」，appid 不存在/已下架返提示

## AdminMiniProgramPage

**小程序审核页**(admin 专属,路由 `/admin/mini-programs`,侧栏 isAdmin 显隐入口,server 端 adminAuth 二次校验)。数据源 `adminMiniProgramsProvider`(autoDispose,失败上抛:**错误视图先 `_asApiError` 解包拦截器包装的 ApiException 再判 403**,403 渲染「无权限查看」,其余错误给重试入口)。按 status 三 Tab 分组:待审(private)/已发布(published)/已下架(disabled),行内发布/下架/上架操作 `showAppDialog` 二次确认后调 `setMiniProgramStatus`(admin 新路径)流转 → invalidate 刷新(下拉/操作后 invalidate 保旧数据静默换新,不闪 loading);操作失败 403 提示「无权限操作」,其余 Snackbar 提示且不触发 invalidate
