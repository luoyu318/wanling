# APP Widgets

lib/widgets/ 组件。3 个子目录：`gallery/`(画廊 + 内化 photo_view)、`feedback/`(统一反馈组件)、`chat/`(聊天页专属 widget + controller)。`chat/` 下的 controller / listener / builder 见 [chat-components.md](./chat-components.md)。

## Avatar

首字母 + hash 色板（avatar_url 为空时降级）；有 url 时拼 baseUrl + 注入 Authorization 头（用 `cached_network_image`）。`memCacheWidth` 限显示尺寸 ×3 解码（避免大图占满 ImageCache 被淘汰，二级页返回时头像稳定命中内存不闪）。`fadeInDuration`/`fadeOutDuration` 设 zero（关闭加载淡入，对齐主流 IM 直接显示）。`cacheKey='avatar_$url'` 命名空间隔离（避免与消息图 key 冲突）

## AvatarPicker

`wechat_assets_picker` + `crop_your_image` 选图裁剪（绕开 Android ActivityResult 崩溃）。导出 `defaultAssetPickerConfig` 共享配置（简中 textDelegate + pathNameBuilder 把 Android 系统相册名 Recent 转成「最近项目」+ 品牌绿），`pickImageBytes`（头像，返回字节）和 `ChatPage._pickAlbum`（聊天发图，返回 AssetEntity）两处复用，避免配置漂移

## CopyableField

复制 + 眼睛切换

## MessageRow `[chat/]`

**单条消息行组合 widget**（ConsumerWidget），按发送方/接收方布局 [Avatar] + 昵称 + [MessageBubble] + 状态指示器：
- 接收方（非多选）：`Row([Avatar?, Col([Nickname?, Bubble])])` 靠左
- 发送方（isMe，非多选）：`Row([StatusIcon?, Bubble, Avatar?])` 靠右
- 多选模式：左侧 22px 圆形勾选框替代头像/状态

**连续消息分组**：`showAvatar` / `showNickname` 由 chat_page 计算（同一发送者连发时只在最早一条显示头像/昵称，其他保留 36px 占位维持对齐）。`isGroup` 仅是调用方表达意图的参数，渲染逻辑只看 `showNickname`。状态指示器（sending: loading 圈 / failed: 红色 ⚠ 点击弹菜单）从 MessageBubble 回迁到此。透传 `onFileTap` + `fileDownloadSnapshots` 给 MessageBubble（v1.0.6）

## MessageBubble `[chat/]`

**StatelessWidget**，纯气泡外壳（三角/选择态/勾选框/长按），内容渲染委托给 `ContentRendererRegistry`。**不处理状态指示器（sending/failed）和头像**——这两项由外层 [MessageRow] 组合。透传 `conversationMessages`（会话全部消息，供画廊收集）+ `openGallery`（点击图片回调）+ `onFileTap`（文件点击触发下载 Sheet）+ `fileDownloadSnapshots`（下载进度 map）给 renderer。长按：`onLongPressStart` → 震动（`HapticFeedback.selectionClick`）+ 进选择态（包 `SelectableRegion` 持 key + postFrame `selectAll` 显示拉杆）+ 回调弹菜单。**SelectableRegion 仅长按后挂上**（避免常态吞长按手势，绕开 markdown_widget 内置 SelectionArea 的 Bug）。菜单"复制"读当前选区（`onSelectionChanged` 缓存）降级全文。多选模式渲染左侧 22px 圆形勾选框

## MessageInputBar `[chat/]`

IM 风聊天输入栏（StatefulWidget）。**v5 参数化**(v1.0.9,4 个可选参数让 agent_session / dm / 群聊共享一个组件):`backgroundColor`(背景色,dm/群聊透明 agent_session 白)、`flatInput`(去掉圆角胶囊改直角,agent_session 用)、`modeBarColor`(左侧 4px 模式竖线色 + 加号/发送按钮色,agent_session 传模式色 Build 蓝 `#597BFF` / Plan 橙 `#F4A742`,dm/群聊 null 走原绿/黑)、`middleSlot`(输入框上方的中间插槽,agent_session 传 SessionMeta 副标题条)。内聚输入文本/焦点/面板显隐/加号↔发送切换状态，对外 5 个回调（`onSend`/`onPickFile`/`onTakePhoto`/`onPickAlbum`，不依赖 Provider）。**草稿接入**(v1.6.2)：新增 `initialText`(外部草稿回填初值)与 `onTextChanged`(文本变化回调)两个可选参数,页面层接 draftProvider 实现「退出留存/重进回填/发送清除」,组件本身不感知 provider。结构：填充式输入框（`isDense` 锁 40px、`maxLines:null` 1~5 行）+ `AnimatedSwitcher`（150ms 加号 ⊕ ↔ 发送）+ `AnimatedSize`（250ms 上滑）的 `PlusPanel`（九宫格：拍照/相册/文件，去图片）。键盘↔面板互斥（FocusNode listener：输入框获焦收面板；点加号 unfocus 展面板）。**`_SendButton` + `_PlusButton` 内部组件**(v1.0.9):均加 `color` 参数,agent_session 传模式色(Build/Plan)让按钮跟随模式,dm/群聊保持原绿发送 + 黑加号。`ColoredBox` 在 `SafeArea` 外层填满底部安全区。统一字号 16/w300（与气泡一致）

## MessageContextMenu `[chat/]`

长按消息浮动菜单（绝对定位 `Positioned left/top`，三角指向消息中心）。半透明深色（`#262626` 0.91）+ 圆角 12 + 阴影，横向 icon 上文字下（删除/撤回红色）。**菜单项按场景变化**(2026-08-11)：
- 普通会话：默认 4 项 复制/引用/删除/多选；`canRecall=true` 加「撤回」= 5 项
- agent_session：3 项 复制/删除/多选（引用不适用、撤回由 StopBar 承载，`showQuote=false` + 强制 canRecall=false）
- `menuWidthFor(itemCount)` 按 item 数算总宽。外部空白用 `Listener`（pointer 层）做 tap 判定关闭，不消费拖拽 → 弹菜单时仍可上下滑动消息列表。ChatPage 滚动时重算 left/top 并重建 OverlayEntry（IM 式锚钉）。

## MessageQuoteBlock / QuotePreviewBar `[chat/]`

**引用功能组件**(2026-07-08):
- **MessageQuoteBlock** — 气泡上方独立引用块(B1 紧凑左竖线样式)。浅紫底 `#1A597BFF` + 左 2px 主题色竖线 + 3px 圆角 + 内边距 4×7。**单行样式**(2026-08-11)：`@昵称 [智能体] : preview` 一行排布(@昵称 9px 主题色 600 字重;Agent 旁紫色「智能体」小标;preview 9px 灰色单行省略)。`isRevoked=true` 时 preview 显示「原消息已撤回」(本地状态优先于 server snapshot,撤回 dispatch 可能在引用消息之后到达)。嵌入 MessageRow 的 Column 顶部(气泡上方,与气泡平级兄弟节点),点击触发 `onJumpToMessage` 跨页跳转。
- **QuotePreviewBar** — 输入框上方引用预览条(V1 卡片式)。结构与 MessageQuoteBlock 视觉一致(浅紫底 + 左竖线),略大 + 右侧 × 关闭按钮。**同步单行化**(2026-08-11)：`@昵称 [智能体] : preview` 一行,Agent 智能体标内联保留。`ChatProvider.pendingQuote` 本地状态,发送时合到 outgoing content.data.quote(完整 snapshot,本地乐观渲染立即可见),发送完清空。

## BubbleWithTail

带三角的气泡容器（text/markdown 共用），maxWidth=屏宽×0.9（留余量防 markdown 内容 sub-pixel 溢出）。v1.0.6 起 file 类型不再用此容器,改走独立 FileCard

## FileCard

**独立文件卡片气泡**(v1.0.6,替代原骨架 FileContentRenderer)。**4 状态机**:`notDownloaded`(显示下载按钮 + "点击下载"提示) / `downloading`(底部紫色进度条 + 取消按钮) / `downloaded`(绿色"已下载"文案 + 文件夹打开按钮) / `uploading`(发送方橙色进度条)。设计参数:白底卡片 + 描边按 isMe 区分(发送方紫晕 `#E0D6F7` / 接收方灰 `#E8E8E8`) + 圆角 16 + 阴影 + 最小宽 220 / 最大屏宽 75%。文件图标用 [FileTypeIcon],操作按钮统一圆形 34×34。`onTap` 在所有状态下都触发(由 ChatPage 按当前状态决定弹 Sheet / 取消下载 / 打开文件),不再单独 `onCancel` 字段

## FileTypeIcon

**彩色文件类型图标**(v1.0.6)。44×44(可配 size) 圆角 10 方块,背景色 + 文字缩写按 `mime_type` 映射:PDF 红 `PDF` / Word 蓝 `W` / Excel 绿 `X` / PPT 橙 `P` / ZIP 紫 `Z` / 文本 灰 `T` / 其他 灰 `?`。设计上"一眼可辨"文件类型,匹配主流 IM 视觉

## MarkdownView

**自控 markdown 渲染**，不用 `MarkdownWidget`（它内部固定包 `SelectionArea`+`ListView`+`VisibilityDetector`，吞长按手势且不必要）。用 markdown_widget 底层 API：`m.Document.parseLines` → `WidgetVisitor.visit`（AST→SpanNode，config/generator 钩子照常生效）→ `SpanNode.build()`（→InlineSpan）→ `Column[Text.rich]`。**不包 SelectionArea**（选择由 MessageBubble 外层统一管）。样式/LaTeX/代码高亮 100% 保留

## markdown_config

`markdownStyle({isDark, baseUrl, token})` 极简墨白样式预设。**图片渲染安全策略**：只放行内部 server 图片（`/api/files/xxx`，adapter `_rewrite_remote_images` 已把 agent 回复里可下载的远程图下载上传替换为此内部链接），带 JWT 渲染成 `CachedNetworkImage`；其余 http(s) URL（追踪图/SSRF/LLM 幻觉）一律文字占位，不发网络请求。内部图片用 `thumbUrl` 加载缩略图 + `memCacheWidth:600` + `cacheKey=thumbCacheKey`（与 image 类型共享内存缓存），包 Hero（tag='gallery_$fileId'，与 image 类型同口径）+ 点击进会话级画廊（`openGallery`，与 image 类型完全对称）。**注意 markdown_widget 2.3.2+8 bug**：表内容 `TBodyNode` 实际读 `headerStyle` 而非 `bodyStyle`，故表头表内容共用 `headerStyle`；且 `PConfig.textStyle.height` 必须 ≥ 1.6（否则任务列表 checkbox WidgetSpan 算出负 padding，debug 模式崩溃）

## markdown_latex

`LatexSyntax`（`$...$`/`$$...$$` 匹配）+ `latexGenerator`（`SpanNodeGeneratorWithTag`，走 `flutter_math_fork` 的 `Math.tex`），通过 `MarkdownGenerator.inlineSyntaxList`/`generators` 注入。块级 `$$...$$` 的 WidgetSpan child 包 `SelectAllOrNoneContainer`（fallbackText=latex 源码），行内 `$...$` 不包

## markdown_code_wrapper

代码块复制按钮（右上角，✓ 回弹 2 秒，无语言标签），签名对齐 `markdown_widget` 的 `CodeWrapper` typedef，注入 `PreConfig.wrapper`。**外层包 `SelectAllOrNoneContainer`（fallbackText=代码源码）实现整块选中**

## markdown_strong

自定义 Bold 节点，覆盖 markdown_widget 默认的 `FontWeight.bold`（w700）改用 w500（medium），对齐 IM 简洁风格、与 H1 标题字重一致。通过 `MarkdownGenerator.generators` 注入

## markdown_block_spacing

自定义块级元素（标题/分割线）的上下间距。markdown_widget 2.3.2+8 默认无法直接配置这两类元素 margin，用 `SpanNodeGeneratorWithTag` 注入自定义节点重写 padding

## SelectAllOrNoneContainer

块级整体选中（主流 IM 式）。`SelectionContainer` + `SelectAllOrNoneContainerDelegate`（照搬 Flutter 官方示例，落块即全选）。`fallbackText` 兜底非文本块（如 LaTeX 图形）的复制。注入到代码块 wrapper / 块级 LaTeX / 表格 wrapper

## TypingBubble `[chat/]`

对方"正在输入"动画气泡(dots 循环)。**agent_session 会话不显示**(2026-08-11)：busy/typing 气泡整体移除,运行时状态由 AppBar subtitle「灵光涌动...」+ StopBar + 聚合卡 footer 承载;普通会话(dm_user_agent 等)仍显示

## StreamingText

流式文本渲染(2026-08-05 改造)。`MessageRenderContext.isStreaming=true` 时 text/markdown renderer 返回此组件替代静态文本。流式期间**整段文本走一次 mdBuilder(markdown 渲染),不拆分 settled/tail、无渐显动画**——拆分会令 markdown 语法跨边界断裂(如 `**加` 在 settled、`粗**abc` 在 tail),未闭合段以源码示人导致形态突变+上下抖动。整段统一解析后语法始终完整,未闭合语法由解析器降级为普通文本,闭合后自然变标题/粗体。reasoning renderer 不接(单行省略卡片)。详见 [chat-components.md](./chat-components.md#streamingtext)

## AgentBadge

Agent 类型标签胶囊（ConsumerWidget）。文案/配色来自 server type 注册表（`agentTypesProvider` 查表,server 值优先;本地 `AgentTypeInfo.fallbackTypes` 兜老 server;未注册类型显示 type 原文 + 默认紫配色;legacy 空串「智能体」紫色系 bg `#EDE9FE`/`#DDD6FE`，fg `#6D28D9`）。`elevated` 参数切灰底 AppBar 对比度。用于消息列表 / Agent 列表项 / Agent 详情页昵称右侧

## UnreadBadge

未读数红点（IM 列表用）

## UnreadNavBadge `[chat/]`

**聊天页内未读浮标**（绿色胶囊样式，带数字）。仅当 `unreadCount > 0 && !isAtBottom` 时显示。点击跳到最新消息并标记已读。合并历史未读 + 会话内新消息计数（按 messageId 批量调 `/messages/read` 一次性标已读，避免逐条闪烁）

## JumpToBottomButton `[chat/]`

**跳转底部浮标**（白色圆形，与未读胶囊视觉区分）。仅当 `unreadCount == 0 && !isAtBottom` 时显示。主流 IM 同款

## UnreadSeparator `[chat/]`

首条未读消息上方的分隔条（"以下是新消息"），普通非粘性，随列表滚动

## LoadMoreIndicator `[chat/]`

顶部加载更多指示器（细进度条样式），仅在 `isLoading` 时显示

## ImageThumb

**图片消息显示组件**。按宽高比缩放显示（宽固定 200px，高 clamp 120~280px 防极宽图变扁条 / 极高图占满屏）。用 `thumbUrl` 走服务端 600px 缩略图 + `memCacheWidth:600` + `cacheKey=thumbCacheKey`，与 markdown 内嵌图、Avatar 共享内存缓存口径。点击进画廊（与 image 类型一致）

## ConnectionBanner

WS 断线时顶部条幅提示。ConsumerStatefulWidget，订阅 `connStateProvider` + `authProvider`（用 `ref.listenManual` + `fireImmediately`）。**3 秒防抖**：disconnected 不立即显示，先启 Timer，期间恢复（connected/connecting）则 cancel；超时才显示。认证过渡期（isSwitching/isRestoring/isLoading）和 connecting/loading 态都静默，消除切换/登录时的闪烁。

## gallery/zoomable_gallery

会话级图片画廊（PageView 翻页 + Hero 共享元素过渡）。点击聊天图片（image 类型 / markdown 内嵌图）打开全屏画廊，可左右滑动切换会话内所有图片。`_openGallery`（ChatPage）收集会话图片去重反转成正序 + 定位初始页。放大态下图片平移到边缘后跟随手指翻页（photo_view 原版 shouldMove 协调：到边让 PageView drag 赢得手势）；翻页时离开页完全滑出屏幕外（监听 `_pageController` 连续 page 值，`|page-oldIndex|>=1.0`）才重置 position/scaleState，避免半屏可见时缩回原大小的突兀感。单击/下拉关闭。**ImageProvider 用原图（高清，支持 4× 缩放）+ `cacheKey=originCacheKey`** 与缩略图场景隔离（避免缩略图小 bitmap 把原图大 bitmap 从内存 LRU 顶掉；同图重复打开画廊命中内存免重解码）。**长按弹 BottomSheet**（外包 `LongPressDetector`，pointer 层不与缩放冲突）→ 复用 `PanelItem` 菜单项样式（顶部圆角 12）→ 点保存调 `saveToGallery`（鉴权下载 + gal 写相册）+ SnackBar 反馈

## gallery/photo_view/

**内化的 photo_view 0.15.0 源码**（脱离 pub 依赖作内部组件，package 自引用改为 `package:app/widgets/gallery/photo_view/`）。提供缩放/平移/fling 惯性。关键改动点：`photo_view_core.dart` 的 fling 用 `velocity/drag`（drag=0.018）替代原版写死 100px；`clampPosition` 拆严格版与 overscroll 版；`photo_view_gesture_detector.dart` 移除 DoubleTapGestureRecognizer 的 pointer 层方案（已废弃，现恢复竞技场仲裁）；`_blindScaleListener` 不钳制 position（避免双指缩放频闪）。photo_view 源码既有大量 info/warning 是内化时自带的，非本次引入

## CardButton / CardStateBadge / CountdownTimer

**审批卡片组件三件套**。`CardButton` 三色实心按钮（primary 绿/info 蓝/danger 红）+ Material Icons（check/shield/close）+ 三态（active/selected/disabled）；`CardStateBadge` 右上角终态徽章（✓已批准/✗已拒绝/⏰已超时）；`CountdownTimer` 倒计时（按 expires_at 自算，每秒刷新）

## long_press_detector

**长按检测器（pointer 层）**。用 `Listener`（不进 gesture arena）实现，500ms 不动触发 `onLongPressStart`，移动超 18px 阈值取消。不与内部手势识别器（SelectableRegion 长按选词 / PhotoViewGallery 缩放）抢手势。message_bubble 长按弹菜单 + gallery 长按保存共用（从 message_bubble 提取）

## panel_item

**加号面板/画廊菜单共用菜单项**。52×52 白底圆角 12 容器 + 30px 黑色 outlined 图标 + 11px #6B7280 灰字（图标上文字下）。MessageInputBar 加号面板（拍照/相册/文件）+ gallery 长按保存菜单共用（从 message_input_bar 提取）

## PasswordTextField

密码输入框组件（StatefulWidget），内置 obscure 显隐状态 + 右侧 `IconButton`（visibility / visibility_off）。替代 login_page / select_account_page / switch_account_sheet / change_password_page 四处原本各写一份的密码框，统一显隐交互

## DraftAwarePreview

会话列表行草稿预览（v1.6.2，无状态组件）。watch `draftProvider(ownerId, convId)`：草稿非空时显示红色书写图标（`drive_file_rename_outline` #FA5151）+ 草稿文本单行省略替换 fallback 摘要，否则渲染 `fallback`；草稿清空后自动恢复原摘要。messages_page 一级列表 + agent_sessions_page 二级列表行摘要共用（状态行 pending/灵光涌动/重试中优先级不变，草稿只覆盖普通摘要分支）

## NavTabBar

自绘底部导航(替换 BottomNavigationBar)：消息/万灵固定图标槽 + pinned agent 头像槽 + `NavConvSlot` 会话槽(好友/群会话,关联 agent 在线时也渲染绿点) + 可选「更多」槽，槽位由 HomePage 从有效序列派生纯展示(无拖拽,点按 onSlotTap/更多 onMoreTap/长按 onSlotLongPress 进编辑页),label 超 5 字符截断加省略号；「更多」槽未激活显示格子图标,激活显示溢出 agent 头像+名字；头像含在线绿点(agent 槽恒看 status,conv 槽经 conv.agent.id 查 agentByIdProvider 同源联动,无 agent 恒不显示) + 未读角标。构造断言可见槽 ≤(showMore?4:5) 个

## AccountSidebar

左侧双层侧滑栏(HomePage 常驻挂载,进出动画/遮罩由 HomePage 控制)：左竖条(88px,账号头像竖排,当前项绿框高亮,点按切换/长按弹编辑·复制·删除菜单/底部「添加」钉底) + 右主面板(`SidebarProfilePanel` 承接原「我的」页菜单)。切换中防抖 + 失败 SnackBar,成功回调 `onClose` 收面板。迁移自旧「切换账号」底部弹层(`SwitchAccountSheet` 已删除)

## SidebarProfilePanel

双层侧滑栏右侧主面板：头部大头像 + 名字 + server 副标题 + 签名 pill(点击进编辑资料)，下方 SettingsGroup 菜单——编辑资料 / 通知与后台 / 修改密码 / 关于(版本号) / 退出登录(确认弹窗)。原 ProfilePage「我的」页菜单整段迁移至此;极小屏防溢出整体可滚动

## AccountMarkEditor

账号标记编辑对话框，给已保存登录起别名（如「工作号」「测试号」），存回 savedLogins，让切换面板和登录选择页更易辨认

## settings_group / settings_tile

**通用列表项组件**。`SettingsGroup` 白底卡片容器（顶部默认 8px margin，与侧滑栏主面板/AgentDetailPage 卡片间距一致）包裹一组 `SettingsTile`；`SettingsTile` 通用行（左 icon + label + 右 trailing 默认 chevron，带按下反馈），从原 ProfilePage 的 `_ProfileTile` 升格为公共组件，SidebarProfilePanel/AgentDetailPage 复用，避免两处列表样式漂移

## feedback/

**统一反馈组件子目录**（commit 939a804 引入，收拢此前散落各处的弹窗/提示实现）：

### app_dialog

统一风格全局 Dialog helper（圆角 12 / 标题 17·w500 / 内容 14·w300 / 品牌绿确认按钮）。替代各页 showDialog + AlertDialog 拼装

### app_snackbar

统一位置轻量提示条。位置策略用 SafeArea bottom 80px（不再依赖 inputBarKey），覆盖输入栏但不遮挡。替代 utils/snackbar.dart 的旧实现

### app_text_selection_toolbar

文字级系统选区菜单（commit e51366b）。覆写 Flutter 系统 `TextSelectionToolbar`，深色配色对齐 `app_menu_style`，让长按文字选词后的系统菜单与消息级浮动菜单视觉统一。估算菜单宽度（4 中文按钮 + 分隔线）对齐 anchor

## v1.0.9+ 新增组件

二级会话目录面板(DirectoryPanel/Tile/PickerSheet + directory_utils)、三体状态指示器(ThreeBodyPhysics/Indicator + ShimmerText)、文件浏览套件(FileEntryIcon + DiffPatchViewer,双栏时代的 SplitView/Breadcrumb/FileListAside/FileViewer 等已废弃)、命令面板(SlashHandle + SlashCommandSheet + ModelPickerSheet)、LocalStoreBanner / ConvActionMenu。详见 [chat-extras.md](./chat-extras.md)
