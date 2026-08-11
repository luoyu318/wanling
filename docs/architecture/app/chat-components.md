# ChatPage 抽离组件

`lib/widgets/chat/` 下从 ChatPage 抽离的 controller / listener / builder。ChatPage 重构为协调者(逻辑委托给 9 controller + 3 listener/builder),双 sliver CustomScrollView 改造后含几何配置/骨架屏集成(~1255 行)。

## 双 sliver 几何(2026-07-31)

ChatPage 用 `CustomScrollView(center: liveSliverKey)` 双 sliver 渲染:
- **history sliver**(leading, 负方向): `historyMessages` newest-first([0]=最新历史贴近锚点)
- **live sliver**(trailing/center, 正方向): `liveMessages` oldest-first(末尾=最新),index 0 = "下滑查看历史"分割线(占位,index 1+ 才是消息)
- loadMore / typing 走独立 `SliverToBoxAdapter`(leading 末尾 / trailing 末尾),不烘焙进 SliverList itemCount
- **live 首条顶部 8px 留白**(2026-08-11):itemBuilder `i==0` 时包 `Padding(top:8)`,首次进入/发消息贴底后首条消息不直接顶到视口上沿(Center 锚点对齐导致);滚动后随首条移出视口自然消失,不影响消息行距。不走 SliverPadding 包裹(会破坏 scrollview_observer 对 RenderSliverPadding 的定位支持)

底部目标 px 由 `dualSliverBottomTarget` 纯函数统一计算(live 非空→maxScrollExtent;live 空→max(minScrollExtent,-vd)),scrollToBottom / _isAtBottom / 流式跟随 / 初始定位 4 处共用。`DualSliverClampingPhysics` 重写 applyBoundaryConditions 阻止手动下滑进入空白区。

## 架构模式

统一 **方案 A**(Controller class + 依赖注入)：每个 controller 是普通 Dart class，构造函数接收 ChatPage 回调 / ref / 服务依赖，ChatPage 在 `initState` 实例化、`dispose` 释放。不用 mixin / riverpod。

## Controllers

### MessageMenuController
长按消息弹浮动菜单(OverlayEntry 绝对定位锚钉)。`MessageMenuContext` 内联闭包持有 `_copySelectedOrFull`(多选优先复制选区、fallback 全文)。菜单项：复制/引用/删除/多选/撤回(`canRecall=true` 时)。**agent_session 场景精简**(2026-08-11)：引用语义不适用 + 撤回由 StopBar 承载,`getIsAgentSession` 动态判断(convType 异步加载)后只显示复制/删除/多选 3 项;`_menuItemCount` 按会话类型算菜单宽度(agent_session 3 / 普通 4-5)。`MessageContextMenu.showQuote` 参数独立控制引用按钮显隐

### MultiSelectController
多选状态 + 行为：进入/退出/勾选切换/全选/批量复制/批量删除。2 字段(`_selectedIds` Set + `_isSelected` bool) + 8 方法。`PopScope` 拦截返回键退出多选

### FileDownloadController
聊天文件下载管理：`FileDownloadService` 实例注入 + 进度 Map + 已下载 Set + 订阅引用(dispose 全 cancel)。`onFileTap` 按状态分流(已下载→OpenFilex / 下载中→cancel / 未下载→弹 DownloadConfirmSheet)。`buildSnapshots` 打包进度 map 注入 MessageRenderContext

### JumpController
跳转引用消息 + 高亮 flash + 滚动到底部。`jumpToMessage(msgId)` 查 live/history index → `scrollToMessageIndex`(observer.jumpTo 跨 sliver 定位 + ensureVisible 精确对齐) → flash 高亮 1s。live 路径 index +1(分割线占 live[0])。`scrollToBottom()` 目标 px 由 `dualSliverBottomTarget` 计算(live 空/非空切换),已在底部(±5)跳过动画消除抖动

### InputController
消息发送入口：`send`(含 quote 合并，内部调 `ChatNotifier.sendText`) / `pickFile` / `takePhoto` / `pickAlbum`。乐观消息插入 + 清空输入框 + 清 pendingQuote

### UnreadLocatorController
进会话定位首条未读：`scrollToFirstUnreadIfNeeded` — 游标分页加载首条未读到顶 → `observerController.jumpTo`(跨 sliver,history sliver 内定位) → `ensureVisible` 精确对齐 → `_isLocating` 标志禁 loadMore 防循环。`onLocateComplete` 回调(loadMoreHistory 预加载一页 + checkUnreadSeen + 揭开骨架屏)。`isMessageInViewport` 辅助判定

### UnreadTrackerController
未读消息已读追踪：`checkUnreadSeen` 滚动时检测视口内未读 → 新进入视口的批量加入 `pendingReadMsgIds` → 500ms debounce 后 `scheduleMarkReadSync` 调 `POST /messages/read` 批量标已读 + 重算 unread_count。`flushPendingReadMsgIds` dispose 时强制 flush

### LoadMoreController
上滑加载历史：`onScrollNotification` 检测 50% 阈值(px - minScrollExtent < vd/2,双 sliver 几何翻转,leading 侧触发) → `loadMore`(ListBefore 每次 50 条)。`distanceToTop = px - minScrollExtent`(center 几何下 maxScrollExtent 语义翻转)

### ConvSyncController
会话级同步：`markRead`(server 同步已读) + `syncParentConvUnread`(刷新上级会话列表未读数)

## Listener / Builder

### ChatStateListener
`ref.listen` 回调抽离。监听 chatState 变化驱动 4 类副作用:(0) init load 未读同步(isInitialLoading true→false + server unread=0 时刷 list 徽章);(1) 未读定位(firstUnreadMessageId null→非null,`_didLocateUnread` 守卫防重复);(2) messages 增长(prepend=新消息 vs append=loadMore,按「用户是否主动滚动离开底部」`getUserScrolledAway` 决定滚到底/增未读计数);(3) 回显消息 pendingScroll。`pendingInitialScroll`(无未读时 jumpTo 底部兜底)等 `isServerInitialized`(非 isInitialLoading,因 DB eager hit 只即时呈现但 convType/sessionMeta 未就绪)。流式跟随(`!getUserScrolledAway && liveMessages.any(isStreaming)` → postFrame jumpTo bottomTarget)。**卡片 PATCH 增高持续跟随**(2026-07-31):检测非流式消息 content 更新(卡片 running→PATCH 回写增高),贴底时启动 16ms 周期 `jumpTo` 实时底部(320ms 兜底),配合卡片渲染 AnimatedSize 平滑增高同步消化高度,避免位置失真与一次性滚动目标过时。**贴底跟随用 `getUserScrolledAway` 而非 `_isAtBottom`**(2026-07-31 修复):卡片等大高度非流式消息插入使 maxScrollExtent 跳增但 px 不变,`_isAtBottom` 不会及时更新;`scrollToBottom` 动画又会在窗口内翻 false 导致流式跟随永久失效。`_userScrolledAway` 由 ChatPage 的 `ScrollStartNotification.dragDetails != null` 置 true、`_onScroll` 回到底部复位 false。含 `_didLocateUnread` / `_loadingHideTimer` / `_cardFollowTimer` / `_pendingScroll` / `_pendingInitialScroll` 字段

### ChatMessageItemBuilder
`buildMessage` 单条消息构造(从原按 index 的 `build` 拆出,双 sliver 下每条消息独立构造不再依赖全局 index)。处理连续消息分组(showAvatar / showNickname via olderNeighbor 参数)。**入场展开动画**(2026-07-31):live sliver 传 `animateEntry=true`,对卡片/审批卡与流式 reasoning(思考消息)首次出现包 `EnterExpand`(SizeTransition 从 0 高度向下展开);历史加载与 reasoning 终态替换(isStreaming=false)不播,避免下滑历史每条都展开/终态重播闪烁。原 `build` 方法保留仅供遗留测试。

### ChatListOverlays
5 个 Stack overlay：loading 遮罩 / loadMore 指示器 / 空消息提示 / unreadNavBadge / jumpToBottomButton。按条件 `Positioned` 放置。注:首屏骨架屏(ChatLoadingSkeleton)是独立 overlay 在 ChatPage Stack 最上层,不在此组件内

## UI Widgets

### ChatAppBar
聊天页顶部 AppBar。副标题仅 dm_user_agent 场景渲染在线/离线/正在输入。群聊标题拼「群名(N)」。**白底 + 状态栏跟随**(2026-08-11)：普通模式背景白 `#FFFFFF`(对齐全局 AppBarTheme),ChatPage 包 `AnnotatedRegion<SystemUiOverlayStyle>` 让状态栏(通知栏)随模式切换——普通模式白底深色图标 / 多选模式深色底 `#2A2A2A` 白图标

### ChatInputBar
底部输入区容器。`_buildInputBar()` 按 convType 分流：agent_session 走 v5 样式(白底/直角/模式色/SessionMeta 副标题条)，dm/群聊走原胶囊绿

### FriendDeletedBanner
好友被删提示横幅

### SelectionBottomBar
多选模式底部操作栏(复制/删除纯 icon，N=0 置灰)

### SessionMetaStrip
agent_session 副标题条：Build/Plan 模式标签 + model 名 + variant，带 `toggleMode` 点击切换

### EnvMetaStrip
agent_session 环境信息条(v1.0.10)：读 `SessionMeta.cwd`/`gitBranch` 渲染「📁 basename(cwd) · ⎇ branch」。cwd 为 null 整行不渲染(SizedBox.shrink)；gitBranch 为 null 只显 cwd 段。挂在 SessionMetaStrip 下方(同一白底 Container 内,底部分割线之后)

### DownloadConfirmSheet
文件下载确认底部弹层

### RecalledBubble
撤回占位(居中灰字「你/对方撤回了一条消息」)

## Utils (`lib/utils/chat/`)

### gallery_opener
`openGallery` — 收集会话图片去重反转 + 定位初始页 + Hero 跳转画廊

### message_preview
`extractLocalPreview` / `extractMessageText` — 从 message content 提取引用预览文本 / 纯文本

### render_box_utils
`globalRectOf` / `listViewRect` — 获取 RenderBox 全局坐标，用于浮动菜单定位

### unread_tracker
`computeNewlySeenUnread` — 纯函数计算视口内新进入的未读消息 id 列表（三级过滤:未读 / 未计数过 / 在视口内），由滚动监听驱动、便于单测直接覆盖，避免依赖 ScrollController / viewport

## 双 sliver / 流式渲染组件(2026-07-31)

### ChatLoadingSkeleton
首屏加载骨架屏。6 块 shimmer 灰块左右交替模拟气泡轮廓,`ShaderMask` + `LinearGradient` 横扫高亮带(1.4s 循环)。背景透明(由父级 `ColoredBox(#EDEDED)` 给底)。不内置 opacity——淡出由 ChatPage `AnimatedOpacity`(200ms) 控制。server 就绪前全程盖消息区(只盖 Expanded,输入栏始终可见),两条揭开信号(pendingInitialScroll 无未读 / onLocateComplete 有未读) + 5s 超时兜底,经 `_markChatReady()` 统一 latch

### DualSliverClampingPhysics
自定义 ScrollPhysics(继承 ClampingScrollPhysics)。重写 `applyBoundaryConditions`,live 空(纯历史会话)时上界收紧为 `max(minScrollExtent, -vd)` 阻止手动下滑/惯性滑入空白区。`getLiveEmpty` 闭包在 ChatPage initState 创建一次(build 引用同一实例避免 rebuild 抖动)

### StreamingText `lib/widgets/`(非 chat/)
流式文本渲染(2026-08-05 改造)。`MessageRenderContext.isStreaming=true` 时 text/markdown renderer 返回此组件替代静态文本。**整段文本走一次 mdBuilder(markdown 渲染),不拆分 settled/tail、无渐显动画**。背景:原「逐字符渐显」实现中 settled/tail 两块各自独立解析 markdown,语法跨边界(如 `**加` 在 settled、`粗**abc` 在 tail)时未闭合段必然以源码示人,settle 瞬间源码→富文本突变 + 上下抖动。整段统一解析后语法始终完整,未闭合语法由解析器降级为普通文本。reasoning renderer 不接(单行省略卡片)

### EnterExpand `lib/widgets/chat/`(入场展开动画)
新消息入场动画:首次 build 从 0 高度向下展开(SizeTransition, 200ms easeOut, axisAlignment -1.0 顶部锚定)。`animate=false` 等价直接显示 child(用于历史加载/终态替换不重播)。由 ChatMessageItemBuilder 对 live 区卡片/审批卡与流式 reasoning 包装
