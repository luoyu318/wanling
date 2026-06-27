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
# 跑全部 migrations（按文件名序执行）
for m in server/migrations/*.sql; do
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
- `007_pairing_tickets.sql` — 扫码配对票据表（见「扫码配对」节）
- `008_approvals.sql` — 审批卡片表 `approvals`（state 状态机 + 会话级 allow_pattern 白名单 + card_type CHECK 约束）
- `009_approval_confirm_id.sql` — `approvals.confirm_id`（slash_confirm 类型用，存 hermes `tools/slash_confirm` 的 confirm_id）
- `010_approval_slash_confirm_type.sql` — 放宽 `approvals_card_type_check` 加 `slash_confirm`（008 源文件已同步）

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
  - `agentAuth` 组（仅 agent role）管 `/api/agents/me/conversations`（agent 视角 findOrCreate，跟 user 版 `/api/conversations` 对称）
  - `approvalAuth` 组（user + agent role）管审批 API：`/api/conversations/:id/approvals`（agent 创建审批卡片，**逻辑上仅 agent 用**但挂在双角色组）、`/api/approvals/:id`（GET 查详情双角色用）。`POST /api/approvals/:id/decide` 挂 `userAuth`（仅 user 决策）。审批 API 限流 20/min（`internal/ratelimit/`）
  - `fileAuth` 组（user + agent role）管 `/api/upload`、`/api/files/:id`，因为 agent 也要上传/下载文件
  - `/api/pair/*` 扫码配对：`POST /tickets` + `GET /tickets/:id` 匿名（凭 256-bit ticket_id）；`POST /tickets/:id/scan` + `POST /tickets/:id/complete` 走 `pairAuth` 组（user JWT）。GET 按 IP 60/min、complete 按 user 10/min 限流（`internal/ratelimit/`）
  - `/ws` 和 `/health` 单独挂，前者用 `AuthMiddleware` 接受 user+agent 双角色
- **internal/hub/** — WebSocket 连接管理器，用 `sync.Map` 以 `role:id` 为 key 管理所有客户端连接，提供 `SendToUser` / `SendToAgent` / `SendToConv`（user+agent 双发，用于消息删除等多端同步广播）方法。**dispatch.go** 提供 3 个审批相关广播 helper：`BroadcastMessageUpdate`（双端，消息内容更新如审批决策后双写 content）、`SendApprovalDecided`（仅 agent，推决策结果带 session_key/confirm_id）、`SendApprovalExpired`（仅 agent，超时通知）。Hub 持有 `NextSeq()` 自增序列号（per-client 单调递增，供 dispatch 的 WSMessage.s 字段）。
- **internal/message/processor.go** — 消息处理器。`HandleIncoming` 用事务（BeginTx → CreateTx → UpdateLastMessageTx → Commit）保证消息持久化和会话缓存原子性，dispatch 在 commit 之后。
- **internal/handler/** — HTTP Handler 集合：
  - `auth_handler.go` — 注册/登录/Agent token 换取
  - `user_handler.go` — `GET /api/users/me`（restoreSession 拉取用户信息）+ `PUT /api/users/me`（更新 nickname / bio / avatar_url）+ `PUT /api/users/me/password`（改密码，校验旧密码）
  - `agent_handler.go` — Agent CRUD
  - `conversation_handler.go` — 会话列表（IM 风格，含 agent + last_message_content + unread_count + 置顶/隐藏标记）+ FindOrCreate + `POST /:id/read`（标记已读）+ `POST/DELETE /:id/pin`（置顶/取消）+ `DELETE /:id`（隐藏 / 软删除）。**`FindOrCreateAsAgent`** 是 agent 视角的对称版（`POST /api/agents/me/conversations`，body `{user_id}`），供 agent 主动 findOrCreate（如发起审批卡片时定位会话）
  - `approval_handler.go` — 审批卡片 3 接口。`CreateApproval`（agent，事务内创建 msg_type=card 消息 + last_message_content，事务外创建 approval 记录，广播 MESSAGE_CREATE；command + allow_pattern 时先查会话级白名单匹配，命中返 auto_approved 不发卡片）、`Decide`（user，调 approval.Service 推进状态机）、`Get`（双角色兜底查询）。**WS payload 必须含 conversation_id/sender_type/sender_id/created_at**（APP chatProvider 按 conversation_id 过滤 + ChatMessage.fromJson 必填校验，缺字段会被丢弃）
  - `ws_handler.go` — WebSocket 协议（Hello → Identify → Heartbeat → Dispatch）
  - `message_handler.go` — 消息软删除。`DELETE /api/messages/:id`（单删）+ `POST /api/messages/batch-delete`（批量，必须同一会话，上限 100）。权限：user 必须是会话 owner，agent 必须是该会话 agent。删除后重算 `last_message_content` 缓存（全删完用 `ClearLastMessage` 置 NULL）+ 广播 `MESSAGE_DELETE`（`hub.SendToConv` 双端，payload 含 ids + conversation_id）
  - `file_handler.go` — 文件上传/下载。**Agent role 上传**时 `owner_id` 落地为 `agent.owner_id`（在 handler 内查 owner），满足 `files.owner_id` 外键到 `users(id)` 约束（agent_id 不在 users 表，直接用会 500）。**下载有归属校验防 IDOR**：user 校验 `f.OwnerID == userID`，agent 校验 `f.OwnerID == ownerID`，不匹配返 403（否则任何登录用户可遍历 UUID 下载他人文件）。file_handler 的错误日志都带 `[upload]`/`[download]` 前缀走 stderr。**图片缩略图**：上传时 `isImageUpload`（mime 或扩展名双重判定）命中则同步调 `imaging.GenerateThumbnail` 生成 600px 长边 JPEG 缩略图落盘（`{原fileID}_thumb.jpg`，fail-soft 失败降级原图不阻断上传）；图片 mime 按 `resolveImageMime` 矫正（客户端传 octet-stream 时按扩展名补正）。**下载支持 `?thumb=1`**：返回缩略图（消息列表场景），无缩略图自动降级原图。**响应带缓存头** `Cache-Control: immutable, max-age=2592000` + `ETag`（fileId 与内容 1:1 不可变，客户端 HTTP 层命中本地缓存根治重复下载）
  - `pairing_handler.go` — 扫码配对 4 接口（`CreateTicket`/`GetTicket`/`ScanTicket`/`CompleteTicket`）。GET completed 返回凭据后**领完即焚**（清空 `pairing_tickets.secret_key`）；scan 幂等（同 user 重扫 OK，跨 user 403）；complete 选已有 agent 重置 secret_key、新建 agent 走 `AgentRepo.Create`。响应统一返 `{status}` 字段串（pending/scanned/completed/expired/not_found）。
  - `middleware.go` — JWT AuthMiddleware，把 `userID`/`role` 写入 gin.Context
  - `access_log.go` — `BusinessAccessLog()` 自定义 access log 中间件，只记录命中注册路由的请求（`c.FullPath()` 非空），扫描器探测的 NoRoute 404 静默。main.go 用 `gin.New() + Recovery + BusinessAccessLog` 替代 `gin.Default()`
- **internal/auth/jwt.go** — JWT 认证，通过 `role` 字段区分 user 和 agent 两种身份。
- **internal/repository/** — 数据库操作层。`ConversationRepo.ListWithAgent` JOIN agents 表返回 IM 列表，SELECT 故意不含 `secret_key`（用 `AgentSummary` 模型避免误用）。
- **internal/model/null_json.go** — `NullJSON` 类型（实现 Scanner/Valuer/Marshaler/Unmarshaler），处理可空 JSONB 字段。**不要加 `omitempty` tag**（实现了 MarshalJSON 后 omitempty 是死代码）。
- **internal/storage/** — 文件存储抽象，当前为本地存储，接口预留 MinIO 扩展。`Provider.SaveThumbnail(storageName, data)` 按指定名落盘缩略图字节（`LocalStorage` 实现写同 baseDir，文件名 `{原fileID}_thumb.jpg`）。
- **internal/imaging/** — 图片缩略图生成（`golang.org/x/image/draw` Catmull-Rom 高质量缩放）。`GenerateThumbnail(reader)` 解码 jpeg/png/webp/gif → 按长边 600 等比缩放（不放大）→ 透明图填白底合成（JPEG 不支持 alpha）→ 编码 JPEG(q85) 返回 `(bytes, w, h, err)`；非图片解码失败返回 error 供上游 fail-soft。
- **internal/config/config.go** — 从环境变量加载配置，必填项（JWT_SECRET、DB_PASSWORD）缺失直接报错退出。
- **internal/presence/** — 基于 Redis 的在线状态服务。`Online`/`RefreshTTL` 都用 **幂等 `SET`**（带 ttl）而非 `EXPIRE`：`EXPIRE` 对已失效的 key 返回 0 且不重建，会导致 Redis 清空或 server 重启后（既有 WS 连接不会断开）存活连接的 presence key 永久丢失，agent 表现为「离线但能正常收发消息」；`SET` 幂等且能重建 key，**下一次心跳即自愈**（commit 766f192 修复）。无 Redis 时降级为内存 map（多实例部署不生效）。
- **internal/approval/** — 审批状态机编排层。`service.go` 的 `Decide` 是核心：JOIN 查审批+消息 → 校验 action_id 合法 → `MarkDecided`（allow_always 才写 allow_pattern；deny/cancel 映射 denied，其余 approved）→ 双写 messages.content（state + decided_*）→ 广播 MESSAGE_UPDATE（双端）+ APPROVAL_DECIDED（仅 agent，带 session_key + confirm_id）。`cleanup.go` 的 `RunCleanup` 后台 goroutine 每 1 分钟扫超时审批（pending + expires_at < now）→ MarkExpired + 广播 APPROVAL_EXPIRED。`*Service` 同时满足 `ExpiredFinder`/`Marker` 接口供 cleanup 调用。

### APP 端核心结构

- **lib/main.dart** — 入口。`async main` 在 runApp 前调 `restoreSession` 拉用户信息，避免首帧渲染时 auth 状态未定。`MaterialApp.router` 固定 `locale: Locale('zh')` + `supportedLocales: [zh]` + Material/Widgets/Cupertino 三套 `localizationsDelegates`（让内置组件和第三方插件拿到 zh locale，否则 wechat_assets_picker 会因 Flutter 默认 supportedLocales=[en,US] 被解析成英文）。
- **lib/router.dart** — GoRouter 配置。`StatefulShellRoute.indexedStack` 实现底部 3-tab 保活；redirect 根据 `authProvider.isAuthenticated` 守卫。**转场动画**：8 个路由统一用 `pageBuilder` + `CustomTransitionPage` + 手写 `SlideTransition`（横向平移，200ms，easeOut），替代 Material 3 默认的 Zoom 缩放转场，对齐主流 IM 利落手感。用 `_cupertinoPage` 工厂统一构建，**每个 pageBuilder 必须传 `key: state.pageKey`**（否则 pushReplacement 时新旧 page key 相同，Flutter 复用旧 State，新页 initState/_markRead 不触发——曾导致「通知跳转后未读不清」bug）。取舍：放弃 iOS 边缘左滑跟手返回（`TransitionsBuilder` 签名无 route 参数挂不了手势）。
- **lib/router_helpers.dart** — `chatRoute(convId, agentId)` 拼路径 + `startChatAndPush(context, ref, agent)` 统一 findOrCreate + 跳转。
- **lib/services/api_service.dart** — Dio HTTP 封装。含 `@visibleForTesting withDio` 构造和 dio getter；Dio Interceptor 在 401 时触发全局登出回调（由 authProvider 反向注入，避免 Riverpod 循环依赖）。
- **lib/services/websocket_service.dart** — WebSocket 客户端，实现完整 Opcode 协议 + 自动重连 + OpResume 补发。
- **lib/services/background_chat_service.dart** — `flutter_background_service` Android 前台服务，APP 后台/被杀时仍能接收消息推送（保活 WS 连接，3s 重连兜底）。跑在**独立 isolate**，看不到 UI 状态，故通过 IPC（`service.on('setActiveConv')`）接收 UI 同步的「当前正在看的会话」(`_activeConvId`)。收消息时判断「要不要弹通知」：`_appInForeground && convId == _activeConvId` 才跳过（前台但不在该会话仍要弹），避免用户正在看的会话误弹系统通知。**未读计数**：`UnreadCounter`（isolate 本地 Map，进入会话清零，复用 setActiveConv IPC）。**头像同步**：`syncAgentAvatar` IPC 接收 UI 同步的 agent avatar_url，URL 变化时清内存+文件缓存（`clearAvatarFileCache`）。收 agent 消息时按 `_unread.get(convId)` 拼 `[N条]` 前缀，并加载头像（内存→文件缓存→下载→首字母色块兜底）。进入会话时 `cancel(convId.hashCode)` 清通知横幅（不点通知直接进 APP 读消息横幅也消失）。
- **lib/services/notification_service.dart** — `flutter_local_notifications` 封装，后台收到消息时弹通知，点击跳转对应会话。**通知样式**：普通文本样式 + `largeIcon`（192x192 方形圆角头像 bitmap，折叠态右侧大头像位），body 用 `[N条]agent名: 消息` 格式（N>1 时）。**点击跳转用智能单例**（`main.dart` 注入 onTap）：用 `routerDelegate.currentConfiguration` 读真实栈顶 location，若已在某个 `/chat/X`（栈顶是 ChatPage）则 `router.pushReplacement('/chat/Y')` 替换栈顶（避免无限叠加），否则 `router.push('/chat/Y')`。**注意**：ChatPage 是 push 出来的栈帧（基础 location 仍是 `/`），不能用 `router.replace`（replace 替换路由目标 URI 不替换 push 栈帧，栈仍叠加）。
- **lib/providers/** — Riverpod 状态管理：
  - `authProvider` — 认证（含 user 信息，restoreSession 调 /me）
  - `agentListProvider` — Agent CRUD
  - `conversationProvider` — IM 列表（订阅 MESSAGE_CREATE 本地更新预览 + 未读计数 + 置顶/隐藏状态）。`setActiveConv(convId)` 方法：发 WS op=3 上报正在看的会话，同时 `FlutterBackgroundService().invoke('setActiveConv', ...)` 同步到 bg-service isolate（让后台通知逻辑也感知，避免正在看的会话误弹通知）。`load()` 拉列表成功后调 `syncAgentAvatarsToBgService`，把每个 agent 的 avatar_url 经 IPC 同步到 isolate（供通知下载头像）。
  - `chatProvider` — family，key 是 record `({convId, agentId})`。同文件还有 `wsProvider`（仅 watch `authProvider.token`，token 变化才重建 WS，避免 updateProfile 刷新 user 触发误断连）和 `connStateProvider`（StreamProvider 桥接 `wsProvider.connectionStateStream`，订阅期先同步推一次 currentConnState 防 banner 误判）。banner 必须订阅 connStateProvider 而非直接 read wsProvider——切换账号时 wsProvider 重建，直接订阅会监听到已 dispose 的旧实例。
  - `settingsProvider` — 服务器地址（baseUrl，默认 `http://localhost:18008`）。被 main/auth/chat/avatar 多处引用。**设置 UI 入口已隐藏**，baseUrl 现由切换账号流程按账号保存值同步覆盖。
  - `savedLoginsProvider` — 多账号管理（`secure_storage` 加密存储历史登录）。`switchTo(index)` 是核心编排：`setSwitching(true)` → `logout(silent:true)`（保留 isSwitching）→ `select(index)` → `onLogin` 注入（invalidate apiProvider + `settingsProvider.setBaseUrl` + login）→ finally `setSwitching(false)`。AuthState 的 `isSwitching` 标志让路由守卫和 banner 在过渡期不误判（见 router.dart 和 ConnectionBanner）。
  - `typingProvider` — 输入指示器（"对方正在输入..."）。**双重订阅**：`ws.typingStream`（TYPING_START）→ startTyping 标记；`ws.messages`（agent 的 MESSAGE_CREATE）→ clearTyping 清掉。clearTyping 放全局 provider 而非 ChatPage 内订阅，是为了「用户已离开 ChatPage / 切到别的会话」时 typing 也能被清掉（否则「正在输入」会卡住不消失）。
- **lib/pages/** — 15 个页面：
  - `SplashPage` — 启动闪屏，决定走登录还是主页
  - `LoginPage` / `SelectAccountPage` — 登录/注册 + 已保存账号选择（多账号）。`SelectAccountPage` 选中账号后触发与切换面板相同的登录注入流程
  - `HomePage` — Scaffold + BottomNavigationBar（3 tab 容器）
  - `MessagesPage` — 消息 tab，IM 风格列表（未读小红点 + 置顶分组）
  - `AgentListPage` — Agent tab，紧凑列表（行点击 → 聊天；头像点击 → 详情）
  - `AgentDetailPage` — 详情：密钥眼睛切换 + 复制 + 编辑/删除 + 发消息 CTA
  - `ChatPage` — 聊天，入参 `(convId, agentId)` record。长按消息弹浮动菜单（复制/删除/多选），多选模式：顶部深色 AppBar（左取消/居中"已选择 N 条"）+ 左侧统一勾选框 + 底部固定操作栏（复制/删除纯 icon，N=0 置灰）。删除走 `ChatNotifier.deleteMessages`（乐观更新+WS MESSAGE_DELETE 同步）。`PopScope` 多选模式拦截返回键。**IM 风输入栏**：AppBar 居中标题（昵称 + 在线/正在输入副标题，正在输入绿色）+ `MessageInputBar`（加号↔发送动态切换 + 加号九宫格面板）。上传通道：文件（file_picker）/相册（wechat_assets_picker）/拍照（wechat_camera_picker），统一走 `_uploadAndSendAsset`
  - `ProfilePage` — 我的 tab 入口，展示用户信息 + 头像。设置项分组：切换账号（≥2 账号才显示，拉起 `SwitchAccountSheet`）/ 通知权限跳转 / 修改密码 / 关于 / 退出登录。**原设置内页入口已隐藏**
  - `ScanPairPage` / `PairSelectAgentPage` — 扫码配对两件套（见「扫码配对」节），AgentListPage 右上角 `+` 拉起
  - `EditProfilePage` / `CropAvatarPage` / `ChangePasswordPage` — 个人资料编辑三件套
  - `AboutPage` — 关于（用 `package_info_plus` 取版本号）。**`SettingsPage` 已移除**（服务器地址配置内页废弃），设置入口在 ProfilePage 暂时隐藏；服务器地址现在由「切换账号」流程管理（见 `savedLoginsProvider.switchTo`，切换时按账号保存的 baseUrl 同步到 `settingsProvider`）。`settingsProvider`（baseUrl）仍被 main/auth/chat/avatar 多处引用，未删
- **lib/rendering/** — 消息内容渲染器体系（注册表模式，为后续 HTML/卡片扩展预留）：
  - `message_content_renderer` — `MessageContentRenderer` 接口（`selectable`/`wrapInBubble`/`build`）+ `ContentRendererRegistry` 注册表（`MsgType → Renderer`）+ `MessageRenderContext`。MessageBubble 只管外壳，内容渲染委托给注册表查到的 renderer。扩展新类型只需写一个 renderer 并 `register`
  - `builtin_renderers` — 内置 renderer：`TextContentRenderer`（含 markdown 语法检测分流）、`MarkdownContentRenderer`（走 MarkdownView）、`ImageContentRenderer`（不可选/不包气泡，缩略图包 Hero + 点击进画廊 `rc.openGallery`；用 `thumbUrl` 加载服务端 600px 缩略图 + `memCacheWidth:600` 限解码尺寸 + `cacheKey=thumbCacheKey` 统一内存缓存口径）、`FileContentRenderer`。`registerBuiltinRenderers()` 在 main.dart 启动时调
  - `card_renderer` — **审批卡片渲染器**（msg_type=card）。`CardContentRenderer` 注册到 MsgType.card，卡片自带白底外壳（`wrapInBubble=false`，MessageBubble 仍给三角）。`_CardView` StatefulWidget 管乐观更新（点按钮立即本地切状态，失败回滚 + snackbar）。按 card_type 分流渲染：command/slash_confirm 用代码块预览，tool 用工具名+预览，file 用文件行。按钮终态映射：deny/cancel→denied，allow_once/allow_always/once/always→approved；终态文案区分（已批准/已拒绝 vs 已确认/已取消）。**`CardContentRenderer.onDecide` 是全局静态回调**，ChatNotifier 构造时注入（避免 Riverpod 循环依赖）
- **lib/theme/** — 设计 token 集合（为将来主题切换/ThemeExtension 铺路，常量改 getter 即可接入）：
  - `app_colors` — 应用色板集中地。把散落各页面的色值（背景 `#EDEDED`/次要文字 `#999999`/品牌绿 `#07C160` 等）收拢到一处，避免硬编码漂移
  - `app_menu_style` — 深色菜单统一色板 token（`#262626` 0.91 背景 + 圆角 12）。`MessageContextMenu`（消息级浮动菜单）和 `AppTextSelectionToolbar`（文字级系统选区菜单）共用，保证两套深色菜单视觉一致
  - `account_palette` — 账号标记固定调色板（8 色）。`AccountMark.colorIndex` 索引此数组，存索引而非 Color 值（序列化稳定 + 便于换肤）
- **lib/widgets/** — 组件（含 `gallery/` 画廊子目录、`feedback/` 反馈子目录）：
  - `Avatar` — 首字母 + hash 色板（avatar_url 为空时降级）；有 url 时拼 baseUrl + 注入 Authorization 头（用 `cached_network_image`）。`memCacheWidth` 限显示尺寸 ×3 解码（避免大图占满 ImageCache 被淘汰，二级页返回时头像稳定命中内存不闪）。`fadeInDuration`/`fadeOutDuration` 设 zero（关闭加载淡入，对齐主流 IM 直接显示）。`cacheKey='avatar_$url'` 命名空间隔离（避免与消息图 key 冲突）
  - `AvatarPicker` — `wechat_assets_picker` + `crop_your_image` 选图裁剪（绕开 Android ActivityResult 崩溃）。导出 `defaultAssetPickerConfig` 共享配置（简中 textDelegate + pathNameBuilder 把 Android 系统相册名 Recent 转成「最近项目」+ 品牌绿），`pickImageBytes`（头像，返回字节）和 `ChatPage._pickAlbum`（聊天发图，返回 AssetEntity）两处复用，避免配置漂移
  - `CopyableField` — 复制 + 眼睛切换
  - `MessageBubble` — **StatefulWidget**，负责外壳（气泡三角/选择态/勾选框/长按），内容渲染委托给 `ContentRendererRegistry`。透传 `conversationMessages`（会话全部消息，供画廊收集）+ `openGallery`（点击图片回调）给 renderer。长按：`onLongPressStart` → 震动（`HapticFeedback.selectionClick`）+ 进选择态（包 `SelectableRegion` 持 key + postFrame `selectAll` 显示拉杆）+ 回调弹菜单。**SelectableRegion 仅长按后挂上**（避免常态吞长按手势，绕开 markdown_widget 内置 SelectionArea 的 Bug）。菜单"复制"读当前选区（`onSelectionChanged` 缓存）降级全文。多选模式渲染左侧 22px 圆形勾选框
  - `MessageInputBar` — IM 风聊天输入栏（StatefulWidget）。内聚输入文本/焦点/面板显隐/加号↔发送切换状态，对外 5 个回调（`onSend`/`onPickFile`/`onTakePhoto`/`onPickAlbum`，不依赖 Provider）。结构：填充式胶囊输入框（白底圆角 6、isDense 锁 40px、`maxLines:null` 1~5 行）+ `AnimatedSwitcher`（150ms 加号 ⊕ ↔ 绿色发送）+ `AnimatedSize`（250ms 上滑）的 `PlusPanel`（九宫格：拍照/相册/文件，去图片）。键盘↔面板互斥（FocusNode listener：输入框获焦收面板；点加号 unfocus 展面板）。`ColoredBox` 在 `SafeArea` 外层填满底部安全区。统一字号 16/w300（与气泡一致）
  - `MessageContextMenu` — 长按消息浮动菜单（`OverlayEntry` + `LayerLink`/`CompositedTransformFollower` 紧贴气泡上方 8px）。半透明深色（`#262626` 0.91）+ 圆角 12 + 阴影，三项横向（复制/删除/多选，icon 上文字下，删除红色）。全屏透明遮罩捕获外部点击 → onDismiss。由 ChatPage 的 OverlayEntry 驱动
  - `BubbleWithTail` — 带三角的气泡容器（text/markdown/file 共用），maxWidth=屏宽×0.9（留余量防 markdown 内容 sub-pixel 溢出）
  - `MarkdownView` — **自控 markdown 渲染**，不用 `MarkdownWidget`（它内部固定包 `SelectionArea`+`ListView`+`VisibilityDetector`，吞长按手势且不必要）。用 markdown_widget 底层 API：`m.Document.parseLines` → `WidgetVisitor.visit`（AST→SpanNode，config/generator 钩子照常生效）→ `SpanNode.build()`（→InlineSpan）→ `Column[Text.rich]`。**不包 SelectionArea**（选择由 MessageBubble 外层统一管）。样式/LaTeX/代码高亮 100% 保留
  - `markdown_config` — `markdownStyle({isDark, baseUrl, token})` 极简墨白样式预设。**图片渲染安全策略**：只放行内部 server 图片（`/api/files/xxx`，adapter `_rewrite_remote_images` 已把 agent 回复里可下载的远程图下载上传替换为此内部链接），带 JWT 渲染成 `CachedNetworkImage`；其余 http(s) URL（追踪图/SSRF/LLM 幻觉）一律文字占位，不发网络请求。内部图片用 `thumbUrl` 加载缩略图 + `memCacheWidth:600` + `cacheKey=thumbCacheKey`（与 image 类型共享内存缓存），包 Hero（tag='gallery_$fileId'，与 image 类型同口径）+ 点击进会话级画廊（`openGallery`，与 image 类型完全对称）。**注意 markdown_widget 2.3.2+8 bug**：表内容 `TBodyNode` 实际读 `headerStyle` 而非 `bodyStyle`，故表头表内容共用 `headerStyle`；且 `PConfig.textStyle.height` 必须 ≥ 1.6（否则任务列表 checkbox WidgetSpan 算出负 padding，debug 模式崩溃）
  - `markdown_latex` — `LatexSyntax`（`$...$`/`$$...$$` 匹配）+ `latexGenerator`（`SpanNodeGeneratorWithTag`，走 `flutter_math_fork` 的 `Math.tex`），通过 `MarkdownGenerator.inlineSyntaxList`/`generators` 注入。块级 `$$...$$` 的 WidgetSpan child 包 `SelectAllOrNoneContainer`（fallbackText=latex 源码），行内 `$...$` 不包
  - `markdown_code_wrapper` — 代码块复制按钮（右上角，✓ 回弹 2 秒，无语言标签），签名对齐 `markdown_widget` 的 `CodeWrapper` typedef，注入 `PreConfig.wrapper`。**外层包 `SelectAllOrNoneContainer`（fallbackText=代码源码）实现整块选中**
  - `markdown_strong` — 自定义 Bold 节点，覆盖 markdown_widget 默认的 `FontWeight.bold`（w700）改用 w500（medium），对齐 IM 简洁风格、与 H1 标题字重一致。通过 `MarkdownGenerator.generators` 注入
  - `markdown_block_spacing` — 自定义块级元素（标题/分割线）的上下间距。markdown_widget 2.3.2+8 默认无法直接配置这两类元素 margin，用 `SpanNodeGeneratorWithTag` 注入自定义节点重写 padding
  - `SelectAllOrNoneContainer` — 块级整体选中（主流 IM 式）。`SelectionContainer` + `SelectAllOrNoneContainerDelegate`（照搬 Flutter 官方示例，落块即全选）。`fallbackText` 兜底非文本块（如 LaTeX 图形）的复制。注入到代码块 wrapper / 块级 LaTeX / 表格 wrapper
  - `TypingBubble` — 对方"正在输入"动画气泡
  - `UnreadBadge` — 未读数红点
  - `ConnectionBanner` — WS 断线时顶部条幅提示。ConsumerStatefulWidget，订阅 `connStateProvider` + `authProvider`（用 `ref.listenManual` + `fireImmediately`）。**3 秒防抖**：disconnected 不立即显示，先启 Timer，期间恢复（connected/connecting）则 cancel；超时才显示。认证过渡期（isSwitching/isRestoring/isLoading）和 connecting/loading 态都静默，消除切换/登录时的闪烁。
  - `gallery/zoomable_gallery` — 会话级图片画廊（PageView 翻页 + Hero 共享元素过渡）。点击聊天图片（image 类型 / markdown 内嵌图）打开全屏画廊，可左右滑动切换会话内所有图片。`_openGallery`（ChatPage）收集会话图片去重反转成正序 + 定位初始页。放大态下图片平移到边缘后跟随手指翻页（photo_view 原版 shouldMove 协调：到边让 PageView drag 赢得手势）；翻页时离开页完全滑出屏幕外（监听 `_pageController` 连续 page 值，`|page-oldIndex|>=1.0`）才重置 position/scaleState，避免半屏可见时缩回原大小的突兀感。单击/下拉关闭。**ImageProvider 用原图（高清，支持 4× 缩放）+ `cacheKey=originCacheKey`** 与缩略图场景隔离（避免缩略图小 bitmap 把原图大 bitmap 从内存 LRU 顶掉；同图重复打开画廊命中内存免重解码）。**长按弹 BottomSheet**（外包 `LongPressDetector`，pointer 层不与缩放冲突）→ 复用 `PanelItem` 菜单项样式（顶部圆角 12）→ 点保存调 `saveToGallery`（鉴权下载 + gal 写相册）+ SnackBar 反馈
  - `gallery/photo_view/` — **内化的 photo_view 0.15.0 源码**（脱离 pub 依赖作内部组件，package 自引用改为 `package:app/widgets/gallery/photo_view/`）。提供缩放/平移/fling 惯性。关键改动点：`photo_view_core.dart` 的 fling 用 `velocity/drag`（drag=0.018）替代原版写死 100px；`clampPosition` 拆严格版与 overscroll 版；`photo_view_gesture_detector.dart` 移除 DoubleTapGestureRecognizer 的 pointer 层方案（已废弃，现恢复竞技场仲裁）；`_blindScaleListener` 不钳制 position（避免双指缩放频闪）。photo_view 源码既有大量 info/warning 是内化时自带的，非本次引入
  - `CardButton` / `CardStateBadge` / `CountdownTimer` — **审批卡片组件三件套**。`CardButton` 三色实心按钮（primary 绿/info 蓝/danger 红）+ Material Icons（check/shield/close）+ 三态（active/selected/disabled）；`CardStateBadge` 右上角终态徽章（✓已批准/✗已拒绝/⏰已超时）；`CountdownTimer` 倒计时（按 expires_at 自算，每秒刷新）
  - `long_press_detector` — **长按检测器（pointer 层）**。用 `Listener`（不进 gesture arena）实现，500ms 不动触发 `onLongPressStart`，移动超 18px 阈值取消。不与内部手势识别器（SelectableRegion 长按选词 / PhotoViewGallery 缩放）抢手势。message_bubble 长按弹菜单 + gallery 长按保存共用（从 message_bubble 提取）
  - `panel_item` — **加号面板/画廊菜单共用菜单项**。52×52 白底圆角 12 容器 + 30px 黑色 outlined 图标 + 11px #6B7280 灰字（图标上文字下）。MessageInputBar 加号面板（拍照/相册/文件）+ gallery 长按保存菜单共用（从 message_input_bar 提取）
  - `PasswordTextField` — 密码输入框组件（StatefulWidget），内置 obscure 显隐状态 + 右侧 `IconButton`（visibility / visibility_off）。替代 login_page / select_account_page / switch_account_sheet / change_password_page 四处原本各写一份的密码框，统一显隐交互
  - `SwitchAccountSheet` — 切换账号底部弹层（从 ProfilePage「切换账号」入口拉起）。列出 `savedLoginsProvider` 已保存账号（含账号标记 + 服务器名），点击触发 `switchTo(index)`。仅在 ≥2 个账号时显示入口
  - `AccountMarkEditor` — 账号标记编辑对话框，给已保存登录起别名（如「工作号」「测试号」），存回 savedLogins，让切换面板和登录选择页更易辨认
  - `settings_group` / `settings_tile` — **通用列表项组件**。`SettingsGroup` 白底卡片容器（顶部默认 8px margin，与 ProfilePage/AgentDetailPage 卡片间距一致）包裹一组 `SettingsTile`；`SettingsTile` 通用行（左 icon + label + 右 trailing 默认 chevron，带按下反馈），从 ProfilePage 的 `_ProfileTile` 升格为公共组件，ProfilePage/AgentDetailPage 复用，避免两处列表样式漂移
  - `feedback/` — **统一反馈组件子目录**（commit 939a804 引入，收拢此前散落各处的弹窗/提示实现）：
    - `app_dialog` — 统一风格全局 Dialog helper（圆角 12 / 标题 17·w500 / 内容 14·w300 / 品牌绿确认按钮）。替代各页 showDialog + AlertDialog 拼装
    - `app_snackbar` — 统一位置轻量提示条。位置策略用 SafeArea bottom 80px（不再依赖 inputBarKey），覆盖输入栏但不遮挡。替代 utils/snackbar.dart 的旧实现
    - `app_text_selection_toolbar` — 文字级系统选区菜单（commit e51366b）。覆写 Flutter 系统 `TextSelectionToolbar`，深色配色对齐 `app_menu_style`，让长按文字选词后的系统菜单与消息级浮动菜单视觉统一。估算菜单宽度（4 中文按钮 + 分隔线）对齐 anchor
- **lib/utils/** — 7 个工具：
  - `app_lifecycle_observer.dart` — 监听 app 前后台切换，触发后台服务启停
  - `avatar_bitmap.dart` — 通知头像加载（URL 下载 → 裁方形(192x192)+圆角 → 文件缓存；失败兜底首字母色块，复用 `Avatar.colorFor`）。纯函数不依赖 Riverpod，isolate 可用
  - `dio_error.dart` — 统一 Dio 异常 → 用户可读文案
  - `gallery_image.dart` — 画廊数据层。`GalleryImage` 模型（url/fileId/headers/heroTag='gallery_$fileId'）；`GalleryImage.fromInternal` 拼**原图** URL（画廊全屏看大图用高清）；`thumbUrl(baseUrl, fileId)` 拼**缩略图** URL（`?thumb=1`，服务端返回 600px 长边小图，无缩略图时自动降级原图，消息列表/气泡/markdown 内嵌图场景用）；`extractInternalImageIds` 用正则从 markdown 提取 `/api/files/{id}`；`collectConversationImages` 遍历会话 image + markdown 消息去重收集，结尾反转（chatProvider 是 newest-first，反转后 index 0 = 最旧）；`saveToGallery` 将画廊图片保存到系统相册（dio 鉴权下载字节，3 秒超时 → `Gal.putImageBytes` 写相册，gal 按 magic bytes 自动推断格式免临时文件，返回 `SaveResult` 枚举，gal 写入免权限）
  - `image_cache_key.dart` — **图片内存缓存 key 统一约定**。`thumbCacheKey(fileId)`='thumb_$fileId'（缩略图场景：消息列表/气泡/markdown 内嵌图共用）；`originCacheKey(fileId)`='origin_$fileId'（画廊原图独用）。key 用稳定前缀+fileId，不含 baseUrl/host，切服务器/账号时同一张图内存缓存仍命中。根治「每次打开重新加载」：缩略图与画廊原图 cacheKey 隔离，避免小 bitmap 把大 bitmap 从 LRU 顶掉；同图多处复用同一 key 不重复解码
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
| 0 | Dispatch | S→C | 事件推送（MESSAGE_CREATE / MESSAGE_UPDATE / MESSAGE_DELETE / AGENT_ONLINE / AGENT_OFFLINE / TYPING_START / APPROVAL_DECIDED / APPROVAL_EXPIRED） |
| 1 | Heartbeat | C→S | 心跳（仅 `{op:1}`，不再携带 seq；seq 由 Dispatch 自带，Resume 单独走 op=6） |
| 2 | Identify | C→S | 鉴权（携带 JWT token）。**握手阶段强制只接受 Identify**，其余 opcode 必须在 Identify 之后 |
| 3 | SetActiveConv | C→S | 上报当前正在看的会话（`{conv_id}`），供服务端判断要不要计未读。空 conv_id = 退出会话。仅 user 角色（agent 不计未读）。见「未读感知」节 |
| 6 | Resume | C→S | 断线恢复，携带最后收到的序列号。**必须在 Identify 之后** |
| 7 | Reconnect | S→C | 服务端要求重连 |
| 10 | Hello | S→C | 连接建立，含心跳间隔 |
| 11 | HeartbeatACK | S→C | 心跳回应 |

**审批相关 Dispatch 事件**（opcode 同为 0）：
- `MESSAGE_UPDATE`（双端，user+agent）— 消息内容更新。审批决策后双写 messages.content，广播此事件让 APP 端切换卡片终态（按钮置灰 + 徽章）。payload：`{message_id, conversation_id, content}`
- `APPROVAL_DECIDED`（仅 agent）— 推决策结果。payload：`{approval_id, message_id, conversation_id, session_key, confirm_id, decision, reason, decided_by, decided_at}`。agent 拿 session_key + confirm_id 路由到等待协程（exec_approval 用 session_key 调 `resolve_gateway_approval`；slash_confirm 用 confirm_id 调 `slash_confirm.resolve`）
- `APPROVAL_EXPIRED`（仅 agent）— 超时通知。payload：`{approval_id, message_id, conversation_id, session_key, expired_at}`

连接流程：WS 建立 → 服务端发 Hello → 客户端发 Identify → 服务端验证 → 开始双向消息 → 客户端定期 Heartbeat。断线后客户端用 OpResume 携带最后 seq，服务端补发缺失的 Dispatch。

消息格式 (`WSMessage`)：`{ op, d, t, s }`，其中 `d` 为 JSON payload，`t` 为事件类型（仅 Dispatch 用），`s` 为序列号（用于 Resume）。

### 未读感知（op=3 SetActiveConv）

服务端判断「用户是否正在看会话 X」以决定 agent 消息要不要计未读，靠 **SetActiveConv (op=3)** 协议感知，不轮询、不查 DB：

1. **APP 进入 ChatPage**：initState 发 `{op:3, d:{conv_id: X}}` → `client.SetActiveConv(X)`
2. **APP 退出 ChatPage**：dispose 发 `{op:3, d:{conv_id: ""}}`（空 = 退出）→ `client.SetActiveConv("")`
3. **agent 发消息**：`message/processor.go` 的 `HandleIncoming` 判断 `senderType=="agent" && !hub.IsUserViewingConv(userID, convID)` 才 `IncrUnreadTx`。`IsUserViewingConv` 遍历该 user 所有 WS 连接，任一 `ActiveConvID==convID` 即返 true（不看 = 计未读）
4. **APP 端 IPC 同步**：`conversationProvider.setActiveConv` 除发 WS 外，还通过 `FlutterBackgroundService().invoke('setActiveConv', ...)` 同步到 bg-service isolate，让后台通知逻辑也感知（用户正在看的会话不弹系统通知，见通知节）

**关键约束**：`Client.activeConvID` 字段读写走 `sync.Mutex`（与 `seq` 字段并发模式一致）。Resume/Resume 之后才允许发 SetActiveConv（握手阶段只接 Identify）。多端（多个 WS 连接）各自独立上报，任一端在看即视为在看。

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
- `approvals` 表（migration 008/009/010）— **审批卡片表**，业务表。记录卡片审批完整生命周期。`card_type` CHECK 约束限定 `command/tool/file/slash_confirm`；`state` 状态机 `pending→approved/denied/expired`（终态不可逆）；`actions` JSONB 存按钮列表；`allow_pattern` 会话级命令白名单（仅 allow_always 决策写入，`*`→`%`/`?`→`_` LIKE 匹配，大小写敏感对齐 shell）；`confirm_id` 仅 slash_confirm 用（存 hermes `tools/slash_confirm` 的 confirm_id 供 resolve 定位）。`messages.content` 双写 state（避免 IM 列表渲染 JOIN）。
- `messages.content` 的 `msg_type=card` 类型（见 `internal/model/approval.go` 的 `CardContent`）— 审批卡片消息。data 含 approval_id/card_type/title/preview/meta/actions/state/decided_*/expires_at/confirm_id。state 在 approvals 表和 messages.content 双写（决策时同步更新两边）。

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

## 审批卡片

Agent 执行敏感操作（危险命令 / 工具调用 / 文件操作 / 破坏性 slash 命令）前，发审批卡片到对话让 user 按钮决策，替代纯文本审批。

**两类审批通道**（对应 hermes 两个跨平台契约方法）：

| 通道 | 触发场景 | adapter 方法 | hermes resolve 原语 | action_id |
|---|---|---|---|---|
| exec_approval | 危险命令 / 工具 / 文件 | `send_exec_approval` | `tools.approval.resolve_gateway_approval(session_key, choice)` | allow_once/allow_always/deny |
| slash_confirm | /new /clear /reset /undo | `send_slash_confirm` | `tools.slash_confirm.resolve(session_key, confirm_id, choice)` | once/always/cancel |

**决策回传链路**（agent 不在 send_* 方法内等决策，立即返回 success）：
1. agent 调 send_* → 万灵 server 创建审批卡片（落 messages + approvals）+ 广播 MESSAGE_CREATE
2. APP 渲染卡片 + 按钮 + 倒计时，user 点按钮 → `POST /api/approvals/:id/decide`
3. server service.Decide 推进状态机 + 双写 content + 广播 MESSAGE_UPDATE（双端切终态）+ APPROVAL_DECIDED（仅 agent）
4. hermes plugin `_on_approval_decided` 按 decision 分流：once/always/cancel → `slash_confirm.resolve(session_key, confirm_id, choice)`；allow_once/allow_always/deny → `resolve_gateway_approval(session_key, choice)`，唤醒 hermes 等待队列

**关键设计**：
- **立即返回**：send_exec_approval/send_slash_confirm 发卡片后立即返回 success=True，**不 await user 决策**（hermes gateway 调用有 15s timeout，await 会被杀掉走文本兜底）。决策由 APPROVAL_DECIDED 事件异步唤醒 hermes。
- **state 双写**：approvals.state + messages.content.data.state 双写，IM 列表/聊天渲染只读 messages 不 JOIN。
- **会话级白名单**（仅 exec_approval 的 command + allow_always）：写 `approvals.allow_pattern`，下次同会话同 agent 发同 pattern 命令时 server 命中返 auto_approved 直接放行。`*`→`%`/`?`→`_` LIKE 匹配，大小写敏感（对齐 shell）。
- **slash_confirm 的 always 语义不同**：不是会话白名单，而是 hermes 端持久化 `approvals.destructive_slash_confirm: false`（关掉这类命令的确认），由 hermes 在 `_on_confirm` handler 里处理，**不写 allow_pattern**。
- **超时**：5 分钟，独立 expired 终态。`approval.RunCleanup` 后台 goroutine 每 1 分钟扫 pending + expires_at < now → MarkExpired + 广播 APPROVAL_EXPIRED。hermes 端通过自己的 approval/slash_confirm queue 管理 timeout，APPROVAL_EXPIRED 主要用于本地状态可视化。

**新增组件**：
- server：`migrations/008/009/010`、`model/approval.go`、`repository/approval_repo.go`、`approval/service.go`、`approval/cleanup.go`、`hub/dispatch.go`、`handler/approval_handler.go`（+ `conversation_handler.go` 的 `FindOrCreateAsAgent`）
- app：`models/approval.dart`、`rendering/card_renderer.dart`、`widgets/card_button.dart`/`card_state_badge.dart`/`countdown_timer.dart`、`chat_provider.dart`（处理 MESSAGE_UPDATE）+ `api_service.dart`（decideApproval）+ `websocket_service.dart`（messageUpdates stream）
- plugin：`adapter.py` 的 `send_exec_approval`/`send_slash_confirm` + `_on_approval_decided`/`_on_approval_expired` + `_resolve_conv_id`（本地 user_id→conv_id 缓存 + HTTP 兜底）。**adapter WS 协议对齐**：握手必须先 Identify（server ws_handler 强制首条 Identify），注册成功后再发 OpResume（`_last_seq>0` 时）补发断线期间 dispatch；`message_id` 用 `uuid.uuid4().hex[:12]`（不用时间戳，防跨客户端冲突）。
- 设计文档：`docs/superpowers/specs/2026-06-23-approval-card-design.md`（按规则不入库）

## 安全

- **鉴权**：所有 `/api/*` 业务路由都在 `AuthMiddleware` 之后；`AgentToken` 内部用 `secret_key` 校验；`/health`、`/ws` 公开是设计如此
- **IDOR 防护**：文件下载 `GET /api/files/:id` 做归属校验（owner_id 匹配，不匹配 403），防 UUID 遍历越权下载他人文件
- **公网扫描防护**：`BusinessAccessLog` 静默 NoRoute 404，扫描器探测不污染日志；进一步加固可选 Go 内置 IP 黑名单或 fail2ban（见 `docs/deployment.md`）
- **文件上传大小**：生产 nginx 反代需设 `client_max_body_size`（默认 1MB 会拦头像上传，建议 20MB）
- **secret_key 存储**：`hermes-plugin/install.sh` 写完 `.env` 自动 `chmod 600`
