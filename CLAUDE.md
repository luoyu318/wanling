# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

**万灵（Wanling）** — AI Agent 聊天系统，类似主流 IM Bot 架构。用户通过 Flutter APP 与 Agent 实时对话，Agent 平台通过标准 WebSocket 接口接入。服务端仅做消息转发和用户/Agent 管理，不包含 Agent 适配层。

APP 端为底部 3-tab 结构（消息 / Agent / 我的），主流 IM 紧凑风格。

**项目身份（2026-06-19 改名）**：
- Go module：`github.com/wanling/server`
- Android applicationId：`com.wanling.app`
- 生产部署：`/usr/local/wanling/`，systemd 服务 `wanling-server`，PG 库 `wanling`
- 旧名 `agent-chat` / `agentchat` 已全部废弃（历史文档 `docs/superpowers/plans|specs/` 保留原样）

## 开发命令

### 服务端 (Go)
```bash
cd server
go run cmd/main.go                 # 启动服务（需先配置 .env，监听 :18008）
go test ./...                      # 运行全部测试（用 testcontainers 起 PG 容器，需 docker）
go test ./internal/hub/...         # 运行指定包测试
```

> 测试用 `testcontainers-go` 起一次性 PG 容器（`internal/repository/testdb.go` 的 `SetupTestDB`）。**禁止 mock 数据库**，所有 repo 测试连真库。CI=1 环境会跳过（runner 通常无 docker）。

### APP 端 (Flutter)
```bash
cd app
flutter pub get                    # 安装依赖（需 PUB_HOSTED_URL=https://pub.flutter-io.cn）
flutter run -d linux --release     # Linux desktop release 模式（开发常用）
flutter run -d <device-id>         # Android 真机/模拟器（adb devices 看 device-id）
flutter build apk --release        # 输出 build/app/outputs/flutter-apk/app-release.apk
flutter test                       # 运行测试
flutter test test/providers/...    # 运行指定目录测试
```

> `pubspec.lock` 镜像源必须保持 `pub.flutter-io.cn`，否则 commit 会被污染。运行时务必 export `PUB_HOSTED_URL` 和 `FLUTTER_STORAGE_BASE_URL`。
>
> **Android 构建注意**：`android/build.gradle.kts` 用腾讯云 + Maven Central 兜底镜像；首次构建会下载 Gradle + Android SDK 组件，耗时较长。涉及 native 插件（`flutter_local_notifications` / `flutter_background_service` / `wechat_assets_picker` / `wechat_camera_picker` 等）改动后，需同步 macOS 主工程插件注册（`MainFlutterWindow.swift`）和 Android 的 `MainActivity.kt`。
>
> **wechat_camera_picker 构建**：它间接拉 `sensors_plus 7.x`（需 Kotlin 2.2），但项目用 Flutter Built-in Kotlin（2.0）。`pubspec.yaml` 的 `dependency_overrides` 固定 `sensors_plus: ^6.1.1` 解决。若升级 Flutter 触发 Kotlin 版本变更，需重新评估此 override。

### 数据库
```bash
# 已有 wanling 库（docker 容器 agent-postgres，端口 6333）
for m in server/migrations/00{1,2,3,4,5}_*.sql; do
  psql -U agent -d wanling -h localhost -p 6333 -f "$m"
done
```

PostgreSQL 跑在 docker 容器 `agent-postgres`（端口映射 6333:5432），用户/密码 `agent/agent123`。

migration 列表：
- `001_init.sql` — 基础表（users / agents / conversations / messages / files）
- `002_conversation_last_message.sql` — `conversations.last_message_content` JSONB 缓存
- `003_unread_count.sql` — `conversations.unread_count` + `messages.is_read`（已读回执）
- `004_pin_hide.sql` — `conversations.hidden_at` + `conversations.pinned_at`（置顶 + 软删除）
- `005_profile_fields.sql` — `users.nickname` + `users.bio` + `agents.bio`（个人资料扩展）
- `006_message_soft_delete.sql` — `messages.deleted_at`（软删除，NULL=未删）+ 部分索引 `idx_messages_conv_not_deleted`（查询须加 `WHERE deleted_at IS NULL`）

也可用 `scripts/init_db.sh` 一键执行。

## 架构

```
用户 APP (Flutter, Linux desktop / Android)
    ↕ WebSocket + HTTP REST
服务端 (Go / Gin, :18008)
    ↕ WebSocket (标准接口)
Agent 平台插件 (plugin/hermes-plugin)
```

### 服务端核心组件

- **cmd/main.go** — 入口，组装所有依赖，注册路由。修改路由或新增 Handler 在此接入。**注意路由组角色限制**：
  - `userAuth` 组（仅 user role）管 `/api/users/me*`、`/api/conversations*`（含 `/read`、`/pin`、`/unpin`、hide 等子路由）
  - `fileAuth` 组（user + agent role）管 `/api/upload`、`/api/files/:id`，因为 agent 也要上传/下载文件
  - `/api/pair/*` 扫码配对：`POST /tickets` + `GET /tickets/:id` 匿名（凭 256-bit ticket_id）；`POST /tickets/:id/scan` + `POST /tickets/:id/complete` 走 `pairAuth` 组（user JWT）。GET 按 IP 60/min、complete 按 user 10/min 限流（`internal/ratelimit/`）
  - `/ws` 和 `/health` 单独挂，前者用 `AuthMiddleware` 接受 user+agent 双角色
- **internal/hub/** — WebSocket 连接管理器，用 `sync.Map` 以 `role:id` 为 key 管理所有客户端连接，提供 `SendToUser` / `SendToAgent` / `SendToConv`（user+agent 双发，用于消息删除等多端同步广播）方法。
- **internal/message/processor.go** — 消息处理器。`HandleIncoming` 用事务（BeginTx → CreateTx → UpdateLastMessageTx → Commit）保证消息持久化和会话缓存原子性，dispatch 在 commit 之后。
- **internal/handler/** — HTTP Handler 集合：
  - `auth_handler.go` — 注册/登录/Agent token 换取
  - `user_handler.go` — `GET /api/users/me`（restoreSession 拉取用户信息）+ `PUT /api/users/me`（更新 nickname / bio / avatar_url）+ `PUT /api/users/me/password`（改密码，校验旧密码）
  - `agent_handler.go` — Agent CRUD
  - `conversation_handler.go` — 会话列表（IM 风格，含 agent + last_message_content + unread_count + 置顶/隐藏标记）+ FindOrCreate + `POST /:id/read`（标记已读）+ `POST/DELETE /:id/pin`（置顶/取消）+ `DELETE /:id`（隐藏 / 软删除）
  - `ws_handler.go` — WebSocket 协议（Hello → Identify → Heartbeat → Dispatch）
  - `message_handler.go` — 消息软删除。`DELETE /api/messages/:id`（单删）+ `POST /api/messages/batch-delete`（批量，必须同一会话，上限 100）。权限：user 必须是会话 owner，agent 必须是该会话 agent。删除后重算 `last_message_content` 缓存（全删完用 `ClearLastMessage` 置 NULL）+ 广播 `MESSAGE_DELETE`（`hub.SendToConv` 双端，payload 含 ids + conversation_id）
  - `file_handler.go` — 文件上传/下载。**Agent role 上传**时 `owner_id` 落地为 `agent.owner_id`（在 handler 内查 owner），下载仅凭 file UUID + 任意 JWT 即可（不再校验 owner 一致）。
  - `pairing_handler.go` — 扫码配对 4 接口（`CreateTicket`/`GetTicket`/`ScanTicket`/`CompleteTicket`）。GET completed 返回凭据后**领完即焚**（清空 `pairing_tickets.secret_key`）；scan 幂等（同 user 重扫 OK，跨 user 403）；complete 选已有 agent 重置 secret_key、新建 agent 走 `AgentRepo.Create`。响应统一返 `{status}` 字段串（pending/scanned/completed/expired/not_found）。
  - `middleware.go` — JWT AuthMiddleware，把 `userID`/`role` 写入 gin.Context
  - `access_log.go` — `BusinessAccessLog()` 自定义 access log 中间件，只记录命中注册路由的请求（`c.FullPath()` 非空），扫描器探测的 NoRoute 404 静默。main.go 用 `gin.New() + Recovery + BusinessAccessLog` 替代 `gin.Default()`
- **internal/auth/jwt.go** — JWT 认证，通过 `role` 字段区分 user 和 agent 两种身份。
- **internal/repository/** — 数据库操作层。`ConversationRepo.ListWithAgent` JOIN agents 表返回 IM 列表，SELECT 故意不含 `secret_key`（用 `AgentSummary` 模型避免误用）。
- **internal/model/null_json.go** — `NullJSON` 类型（实现 Scanner/Valuer/Marshaler/Unmarshaler），处理可空 JSONB 字段。**不要加 `omitempty` tag**（实现了 MarshalJSON 后 omitempty 是死代码）。
- **internal/storage/** — 文件存储抽象，当前为本地存储，接口预留 MinIO 扩展。
- **internal/config/config.go** — 从环境变量加载配置，必填项（JWT_SECRET、DB_PASSWORD）缺失直接报错退出。
- **internal/presence/** — 基于 Redis 的在线状态服务。

### APP 端核心结构

- **lib/main.dart** — 入口。`async main` 在 runApp 前调 `restoreSession` 拉用户信息，避免首帧渲染时 auth 状态未定。`MaterialApp.router` 固定 `locale: Locale('zh')` + `supportedLocales: [zh]` + Material/Widgets/Cupertino 三套 `localizationsDelegates`（让内置组件和第三方插件拿到 zh locale，否则 wechat_assets_picker 会因 Flutter 默认 supportedLocales=[en,US] 被解析成英文）。
- **lib/router.dart** — GoRouter 配置。`StatefulShellRoute.indexedStack` 实现底部 3-tab 保活；redirect 根据 `authProvider.isAuthenticated` 守卫。**转场动画**：8 个路由统一用 `pageBuilder` + `CustomTransitionPage` + 手写 `SlideTransition`（横向平移，200ms，easeOut），替代 Material 3 默认的 Zoom 缩放转场，对齐主流 IM 利落手感。用 `_cupertinoPage` 工厂统一构建。取舍：放弃 iOS 边缘左滑跟手返回（`TransitionsBuilder` 签名无 route 参数挂不了手势）。
- **lib/router_helpers.dart** — `chatRoute(convId, agentId)` 拼路径 + `startChatAndPush(context, ref, agent)` 统一 findOrCreate + 跳转。
- **lib/services/api_service.dart** — Dio HTTP 封装。含 `@visibleForTesting withDio` 构造和 dio getter；Dio Interceptor 在 401 时触发全局登出回调（由 authProvider 反向注入，避免 Riverpod 循环依赖）。
- **lib/services/websocket_service.dart** — WebSocket 客户端，实现完整 Opcode 协议 + 自动重连 + OpResume 补发。
- **lib/services/background_chat_service.dart** — `flutter_background_service` Android 前台服务，APP 后台/被杀时仍能接收消息推送（保活 WS 连接，3s 重连兜底）。
- **lib/services/notification_service.dart** — `flutter_local_notifications` 封装，后台收到消息时弹通知，点击跳转对应会话。
- **lib/providers/** — Riverpod 状态管理：
  - `authProvider` — 认证（含 user 信息，restoreSession 调 /me）
  - `agentListProvider` — Agent CRUD
  - `conversationProvider` — IM 列表（订阅 MESSAGE_CREATE 本地更新预览 + 未读计数 + 置顶/隐藏状态）
  - `chatProvider` — family，key 是 record `({convId, agentId})`
  - `settingsProvider` — 服务器地址（默认 `http://localhost:18008`）
  - `savedLoginsProvider` — 多账号管理（`secure_storage` 加密存储历史登录，支持切换）
  - `typingProvider` — 输入指示器（"对方正在输入..."，订阅 WS TYPING 事件）
- **lib/pages/** — 14 个页面：
  - `SplashPage` — 启动闪屏，决定走登录还是主页
  - `LoginPage` / `SelectAccountPage` — 登录/注册 + 已保存账号选择（多账号）
  - `HomePage` — Scaffold + BottomNavigationBar（3 tab 容器）
  - `MessagesPage` — 消息 tab，IM 风格列表（未读小红点 + 置顶分组）
  - `AgentListPage` — Agent tab，紧凑列表（行点击 → 聊天；头像点击 → 详情）
  - `AgentDetailPage` — 详情：密钥眼睛切换 + 复制 + 编辑/删除 + 发消息 CTA
  - `ChatPage` — 聊天，入参 `(convId, agentId)` record。长按消息弹浮动菜单（复制/删除/多选），多选模式：顶部深色 AppBar（左取消/居中"已选择 N 条"）+ 左侧统一勾选框 + 底部固定操作栏（复制/删除纯 icon，N=0 置灰）。删除走 `ChatNotifier.deleteMessages`（乐观更新+WS MESSAGE_DELETE 同步）。`PopScope` 多选模式拦截返回键。**IM 风输入栏**：AppBar 居中标题（昵称 + 在线/正在输入副标题，正在输入绿色）+ `MessageInputBar`（加号↔发送动态切换 + 加号九宫格面板）。上传通道：文件（file_picker）/相册（wechat_assets_picker）/拍照（wechat_camera_picker），统一走 `_uploadAndSendAsset`
  - `ProfilePage` — 我的 tab 入口，展示用户信息 + 头像
  - `EditProfilePage` / `CropAvatarPage` / `ChangePasswordPage` — 个人资料编辑三件套
  - `SettingsPage` / `AboutPage` — 设置（服务器地址）+ 关于（用 `package_info_plus` 取版本号）
- **lib/rendering/** — 消息内容渲染器体系（注册表模式，为后续 HTML/卡片扩展预留）：
  - `message_content_renderer` — `MessageContentRenderer` 接口（`selectable`/`wrapInBubble`/`build`）+ `ContentRendererRegistry` 注册表（`MsgType → Renderer`）+ `MessageRenderContext`。MessageBubble 只管外壳，内容渲染委托给注册表查到的 renderer。扩展新类型只需写一个 renderer 并 `register`
  - `builtin_renderers` — 内置 renderer：`TextContentRenderer`（含 markdown 语法检测分流）、`MarkdownContentRenderer`（走 MarkdownView）、`ImageContentRenderer`（不可选/不包气泡）、`FileContentRenderer`。`registerBuiltinRenderers()` 在 main.dart 启动时调
- **lib/widgets/** — 14 个组件：
  - `Avatar` — 首字母 + hash 色板（avatar_url 为空时降级）；有 url 时拼 baseUrl + 注入 Authorization 头（用 `cached_network_image`）。`memCacheWidth` 限显示尺寸 ×3 解码（避免大图占满 ImageCache 被淘汰，二级页返回时头像稳定命中内存不闪）。`fadeInDuration`/`fadeOutDuration` 设 zero（关闭加载淡入，对齐主流 IM 直接显示）
  - `AvatarPicker` — `wechat_assets_picker` + `crop_your_image` 选图裁剪（绕开 Android ActivityResult 崩溃）。导出 `defaultAssetPickerConfig` 共享配置（简中 textDelegate + pathNameBuilder 把 Android 系统相册名 Recent 转成「最近项目」+ 品牌绿），`pickImageBytes`（头像，返回字节）和 `ChatPage._pickAlbum`（聊天发图，返回 AssetEntity）两处复用，避免配置漂移
  - `CopyableField` — 复制 + 眼睛切换
  - `MessageBubble` — **StatefulWidget**，负责外壳（气泡三角/选择态/勾选框/长按），内容渲染委托给 `ContentRendererRegistry`。长按：`onLongPressStart` → 震动（`HapticFeedback.selectionClick`）+ 进选择态（包 `SelectableRegion` 持 key + postFrame `selectAll` 显示拉杆）+ 回调弹菜单。**SelectableRegion 仅长按后挂上**（避免常态吞长按手势，绕开 markdown_widget 内置 SelectionArea 的 Bug）。菜单"复制"读当前选区（`onSelectionChanged` 缓存）降级全文。多选模式渲染左侧 22px 圆形勾选框
  - `MessageInputBar` — IM 风聊天输入栏（StatefulWidget）。内聚输入文本/焦点/面板显隐/加号↔发送切换状态，对外 5 个回调（`onSend`/`onPickFile`/`onTakePhoto`/`onPickAlbum`，不依赖 Provider）。结构：填充式胶囊输入框（白底圆角 6、isDense 锁 40px、`maxLines:null` 1~5 行）+ `AnimatedSwitcher`（150ms 加号 ⊕ ↔ 绿色发送）+ `AnimatedSize`（250ms 上滑）的 `PlusPanel`（九宫格：拍照/相册/文件，去图片）。键盘↔面板互斥（FocusNode listener：输入框获焦收面板；点加号 unfocus 展面板）。`ColoredBox` 在 `SafeArea` 外层填满底部安全区。统一字号 16/w300（与气泡一致）
  - `MessageContextMenu` — 长按消息浮动菜单（`OverlayEntry` + `LayerLink`/`CompositedTransformFollower` 紧贴气泡上方 8px）。半透明深色（`#262626` 0.91）+ 圆角 12 + 阴影，三项横向（复制/删除/多选，icon 上文字下，删除红色）。全屏透明遮罩捕获外部点击 → onDismiss。由 ChatPage 的 OverlayEntry 驱动
  - `BubbleWithTail` — 带三角的气泡容器（text/markdown/file 共用），maxWidth=屏宽×0.9（留余量防 markdown 内容 sub-pixel 溢出）
  - `MarkdownView` — **自控 markdown 渲染**，不用 `MarkdownWidget`（它内部固定包 `SelectionArea`+`ListView`+`VisibilityDetector`，吞长按手势且不必要）。用 markdown_widget 底层 API：`m.Document.parseLines` → `WidgetVisitor.visit`（AST→SpanNode，config/generator 钩子照常生效）→ `SpanNode.build()`（→InlineSpan）→ `Column[Text.rich]`。**不包 SelectionArea**（选择由 MessageBubble 外层统一管）。样式/LaTeX/代码高亮 100% 保留
  - `markdown_config` — `markdownStyle({isDark})` 极简墨白样式预设。**注意 markdown_widget 2.3.2+8 bug**：表内容 `TBodyNode` 实际读 `headerStyle` 而非 `bodyStyle`，故表头表内容共用 `headerStyle`；且 `PConfig.textStyle.height` 必须 ≥ 1.6（否则任务列表 checkbox WidgetSpan 算出负 padding，debug 模式崩溃）
  - `markdown_latex` — `LatexSyntax`（`$...$`/`$$...$$` 匹配）+ `latexGenerator`（`SpanNodeGeneratorWithTag`，走 `flutter_math_fork` 的 `Math.tex`），通过 `MarkdownGenerator.inlineSyntaxList`/`generators` 注入。块级 `$$...$$` 的 WidgetSpan child 包 `SelectAllOrNoneContainer`（fallbackText=latex 源码），行内 `$...$` 不包
  - `markdown_code_wrapper` — 代码块复制按钮（右上角，✓ 回弹 2 秒，无语言标签），签名对齐 `markdown_widget` 的 `CodeWrapper` typedef，注入 `PreConfig.wrapper`。**外层包 `SelectAllOrNoneContainer`（fallbackText=代码源码）实现整块选中**
  - `SelectAllOrNoneContainer` — 块级整体选中（主流 IM 式）。`SelectionContainer` + `SelectAllOrNoneContainerDelegate`（照搬 Flutter 官方示例，落块即全选）。`fallbackText` 兜底非文本块（如 LaTeX 图形）的复制。注入到代码块 wrapper / 块级 LaTeX / 表格 wrapper
  - `TypingBubble` — 对方"正在输入"动画气泡
  - `UnreadBadge` — 未读数红点
  - `ConnectionBanner` — WS 断线时顶部条幅提示
  - `FullScreenImagePage` — `photo_view` 全屏查看 + 双指缩放
- **lib/utils/** — 6 个工具：
  - `app_lifecycle_observer.dart` — 监听 app 前后台切换，触发后台服务启停
  - `dio_error.dart` — 统一 Dio 异常 → 用户可读文案
  - `notification_payload.dart` — 通知点击 payload 解析（路由到对应会话）
  - `permission_helper.dart` — `permission_handler` 封装，运行时权限申请（图片/通知）
  - `secure_storage.dart` — `flutter_secure_storage` 封装，加密存储 token / 多账号
  - `snackbar.dart` — 全局 Snackbar helper
- **lib/models/** — `User`、`Agent`、`Conversation`（含 `lastMessagePreview` / `unreadCount` / `isPinned` / `isHidden` getter）、`Message`、`WSMessage`
- **scripts/** — 项目级运维脚本：
  - `init_db.sh` — 一键建库 + 跑 migrations
  - `deploy.sh` — 本地编译 → rsync → systemctl restart（生产部署）
  - `admin.sh` — 交互式管理菜单（加用户/重置密码/构建 APK/重启服务等）
  - `publish-plugin.sh` — 把 `plugin/` 同步到公开镜像 repo（`gitee.com/luoyu318/wanling-plugin`），用 `PUBLISH_REPO_DIR=<路径>` 指定本地 clone
  - `migrate-rename-to-wanling.sh` — 一次性生产迁移脚本（agent-chat→wanling 改名用，已执行完）

## WebSocket 协议

基于 Opcode 的二进制协议（参考主流 IM Bot）：

| Opcode | 名称 | 方向 | 用途 |
|--------|------|------|------|
| 0 | Dispatch | S→C | 事件推送（MESSAGE_CREATE / MESSAGE_DELETE / AGENT_ONLINE / AGENT_OFFLINE / TYPING_START） |
| 1 | Heartbeat | C→S | 心跳 |
| 2 | Identify | C→S | 鉴权（携带 JWT token） |
| 6 | Resume | C→S | 断线恢复，携带最后收到的序列号 |
| 7 | Reconnect | S→C | 服务端要求重连 |
| 10 | Hello | S→C | 连接建立，含心跳间隔 |
| 11 | HeartbeatACK | S→C | 心跳回应 |

连接流程：WS 建立 → 服务端发 Hello → 客户端发 Identify → 服务端验证 → 开始双向消息 → 客户端定期 Heartbeat。断线后客户端用 OpResume 携带最后 seq，服务端补发缺失的 Dispatch。

消息格式 (`WSMessage`)：`{ op, d, t, s }`，其中 `d` 为 JSON payload，`t` 为事件类型（仅 Dispatch 用），`s` 为序列号（用于 Resume）。

## 认证体系

统一 JWT，`role` 字段区分身份：
- 用户：用户名密码登录获取 `{ sub: user_id, role: "user" }`
- Agent：`agent_id + secret_key` 换取 `{ sub: agent_id, role: "agent", owner: user_id }`

中间件 `handler.AuthMiddleware` 根据 role 校验权限，把 `userID` / `role` 写入 gin.Context。

## 数据库

PostgreSQL，表结构见 `server/migrations/`。核心表：users、agents、conversations、messages、files。messages.content 为 JSONB，通过 `msg_type` 区分文本/Markdown/图片/文件/混合消息。

关键扩展字段：
- `conversations.last_message_content`（migration 002）— JSONB，缓存最后一条消息内容，写消息时由 MessageProcessor 在事务内同步更新，避免 IM 列表 JOIN messages 表。NULL 表示从未发过消息的会话（IM 列表 `WHERE last_message_content IS NOT NULL` 过滤）。
- `conversations.unread_count`（migration 003）— int，IM 列表未读数。
- `conversations.hidden_at` / `pinned_at`（migration 004）— TIMESTAMPTZ，非空表示已隐藏/已置顶。新消息来时 `hidden_at` 置空（自动恢复显示）。IM 列表排序：置顶组在前 + `last_message_at` 倒序。
- `messages.is_read`（migration 003）— bool，预留"已读回执"扩展。
- `users.nickname` / `users.bio` / `agents.bio`（migration 005）— 个人资料扩展，`nickname` 为空时回退 `username`。
- `messages.deleted_at`（migration 006）— TIMESTAMPTZ，软删除（NULL=未删）。查询须加 `WHERE deleted_at IS NULL`，配合部分索引 `idx_messages_conv_not_deleted`。
- `pairing_tickets` 表（migration 007）— 扫码配对票据表（**非业务表**），仅握手用。5 分钟 TTL（查询时计算），`secret_key` 领完即焚。后台 goroutine 每 10 分钟清理 1 小时前的记录（`internal/pair/cleanup.go`）。

## 测试

### 后端
- `internal/repository/testdb.go` 提供 `SetupTestDB(t)` 起 testcontainers PG 容器，所有 repo 测试连真库（**禁止 mock**）。
- Handler 测试用 `httptest` + gin，覆盖 happy path + 4xx/5xx 分支。
- 测试中 username 用 `shortName(t, prefix)` helper 截断（避免超 varchar(64)）。

### APP
- 单元/widget 测试用 `mocktail` + `test/helpers/mock_adapter.dart`（含 `MockHttpClientAdapter` 和 `CapturingMockAdapter`）。
- `test/helpers/fake_ws.dart` 提供 `FakeWS extends WebSocketService`，用 StreamController 模拟消息流。
- E2E 测试在 `test/e2e/`，验证路由 redirect + tab 切换。

## 配置

通过环境变量或 `.env` 文件配置（见 `server/.env.example`）。配置加载逻辑在 `internal/config/config.go`，直接从 `os.Getenv` 读取。

## 插件分发

`plugin/` 是插件总目录，每个子目录是一个独立插件（当前只有 `hermes-plugin/`，未来可加 `openclaw-plugin/` 等）。插件代码可公开，与主库私有代码解耦。

- **主库 `plugin/`** = 权威源（日常开发在此改，经常和 server 同步改协议）
- **公开镜像 repo**：`gitee.com/luoyu318/wanling-plugin`（镜像 repo 根 = 主库 `plugin/` 内容）
- **`plugin/install-remote.sh`** — 总入口引导脚本（被用户 curl），支持 `--plugin=<name>` 选插件（默认 hermes-plugin），下载后 exec 调用插件的 install.sh
- **`plugin/hermes-plugin/install.sh`** — 实际安装脚本，四模式：默认安装 / `--update`（只同步代码）/ `--config`（只改配置）/ `--pair`（扫码配对，见下），支持 `--profile=<name>` 多 profile
- **`scripts/publish-plugin.sh`** — 发布：`PUBLISH_REPO_DIR=<镜像 repo 本地路径> ./scripts/publish-plugin.sh`，用 rsync 同步整个 `plugin/` 到镜像 repo（排除 `.git/`、`__pycache__`），从 `hermes-plugin/plugin.yaml` 读 version 打 tag

用户一键安装：
```bash
curl -fsSL https://gitee.com/luoyu318/wanling-plugin/raw/main/install-remote.sh | \
  bash -s -- --server=URL --agent-id=ID --secret-key=KEY
```

## 扫码配对

hermes 终端 `./install.sh --pair` 生成授权二维码 → 万灵 app「万灵」tab 右上角 `+` → 扫一扫 → 选/建 Agent → hermes 终端自动拿到凭据完成配置。**无需 user token**，是 `--register` 的扫码升级版（`--register` 仍保留给自动化脚本）。

**三方握手**（hermes 终端 / 万灵 server / 万灵 app）：
1. hermes 端 `install.sh --pair` 输入 server URL → 生成 ticket（256-bit hex，TTL 5min）→ 终端打印 ASCII 二维码（内容 `WLPAIR:<ticket_id>`，qrencode → python3+qrcode → 纯文本三级兜底）
2. 万灵 app 扫码（`mobile_scanner`，`ScanPairPage`）→ `POST /api/pair/tickets/:id/scan`（user JWT）回显该 user 名下 agent 列表
3. app 在 `PairSelectAgentPage` 选已有 agent（弹"重置密钥"确认）或新建 → `POST /api/pair/tickets/:id/complete`
4. hermes 端 2s 短轮询 `GET /api/pair/tickets/:id`，completed 时拿凭据，**领完即焚**（secret_key 领走后清空）

**关键设计**：
- **覆盖语义无状态**：选任意已有 agent 都重置 secret_key 使旧 hermes 失效，**不存绑定表**（`agents` 表不加字段）。票据表 `pairing_tickets` 仅握手用，非业务表。
- **鉴权**：hermes 端只凭 ticket_id（不可猜），app 端走 user JWT。scan 与 complete 校验同一 user，防 A 扫码 B complete。
- **限流**：`GET /tickets/:id` 按 IP 60/min（防枚举），`complete` 按 user 10/min。Redis 可用时走 Redis，否则内存降级。
- **票据清理**：`pair.RunCleanup` 后台 goroutine 每 10 分钟删 1 小时前的票据。

**新增组件**：
- server：`migrations/007_pairing_tickets.sql`、`model/pairing_ticket.go`、`repository/pairing_repo.go`、`handler/pairing_handler.go`、`ratelimit/middleware.go`、`pair/cleanup.go`
- app：`pages/scan_pair_page.dart`、`pages/pair_select_agent_page.dart`、`models/pairing.dart`
- 设计文档：`docs/superpowers/specs/2026-06-22-hermes-qr-pair-design.md`

## 安全

- **鉴权**：所有 `/api/*` 业务路由都在 `AuthMiddleware` 之后；`AgentToken` 内部用 `secret_key` 校验；`/health`、`/ws` 公开是设计如此
- **公网扫描防护**：`BusinessAccessLog` 静默 NoRoute 404，扫描器探测不污染日志；进一步加固可选 Go 内置 IP 黑名单或 fail2ban（见 `docs/deployment.md`）
- **文件上传大小**：生产 nginx 反代需设 `client_max_body_size`（默认 1MB 会拦头像上传，建议 20MB）
- **secret_key 存储**：`hermes-plugin/install.sh` 写完 `.env` 自动 `chmod 600`
