# 万灵 APP

万灵 聊天系统的 Flutter 客户端。底部 3-tab 结构（消息 / 万灵 / 我的），主流 IM 紧凑风格，通过 HTTP REST + WebSocket 与服务端通信。

## 环境要求

- Flutter 3.44+ / Dart 3.10+
- Linux desktop 原生依赖：`libgtk-3-dev`、`cmake`、`ninja-build`、`clang`
- Android SDK + Java 17（构建 APK 必需，`android/build.gradle.kts` 已配国内镜像 + Maven Central 兜底镜像）
- 运行中的服务端（默认 `http://localhost:18008`，可在 APP 内"我的 → 设置"修改）

## 启动

### 通用前置（国内镜像必须）

```bash
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn
flutter pub get
```

### Linux desktop

```bash
flutter run -d linux --release   # 首次编译 1-2 分钟（C++ 原生代码）
```

### Android 真机/模拟器（开发常用）

```bash
adb devices                       # 确认设备在线
flutter run -d <device-id>        # 调试模式
flutter build apk --release       # 输出 build/app/outputs/flutter-apk/app-release.apk
```

涉及 native 插件（`flutter_local_notifications` / `flutter_background_service` / `wechat_assets_picker` 等）改动后，需同步检查：
- `android/app/src/main/kotlin/.../MainActivity.kt` — Android 插件注册
- `macos/Runner/MainFlutterWindow.swift` — macOS 桌面端插件注册（如需）

## 目录结构

```
lib/
├── main.dart                # async main + restoreSession + MaterialApp.router（固定 zh locale）
├── router.dart              # GoRouter + StatefulShellRoute.indexedStack（3 tab 保活）+ _cupertinoPage 横向平移转场(200ms)。pageBuilder 必传 `key: state.pageKey`（否则 pushReplacement 复用旧 State，initState 不触发）
├── router_helpers.dart      # chatRoute() + startChatAndPush() 统一跳转
├── models/                  # User / Agent / Conversation / Message / WSMessage
├── services/
│   ├── api_service.dart     # Dio HTTP 封装（401 触发全局登出）
│   ├── websocket_service.dart  # WS 客户端 + Opcode 协议 + 自动重连 + OpResume 补发
│   ├── background_chat_service.dart  # Android 前台服务，被杀后仍收消息；未读计数 + 头像 IPC 同步
│   └── notification_service.dart     # flutter_local_notifications 封装；文本样式+largeIcon 头像 + [N条] 计数
├── providers/               # Riverpod 状态管理
│   ├── auth_provider.dart
│   ├── agent_provider.dart
│   ├── conversation_provider.dart    # IM 列表 + 未读 + 置顶/隐藏
│   ├── chat_provider.dart            # family，key 是 record ({convId, agentId})
│   ├── settings_provider.dart
│   ├── saved_logins_provider.dart    # 多账号加密存储 + 切换
│   └── typing_provider.dart          # "对方正在输入" 指示器
├── pages/                   # 14 个页面（见下方"页面清单"）
├── rendering/              # 消息内容渲染器（注册表模式：MsgType → Renderer）
│   ├── message_content_renderer.dart  # Renderer 接口 + 注册表 + MessageRenderContext
│   └── builtin_renderers.dart         # text/markdown/image/file renderer + registerBuiltinRenderers()
├── widgets/                 # 组件，含 gallery/ 画廊子目录（见下方"组件清单"）
│   └── gallery/
│       ├── zoomable_gallery.dart     # 会话级图片画廊（Hero + 翻页 + 放大态跟随翻页）
│       └── photo_view/               # 内化的 photo_view 源码（缩放/平移/fling）
└── utils/
    ├── app_lifecycle_observer.dart   # 前后台切换 → 启停后台服务
    ├── avatar_bitmap.dart            # 通知头像加载(下载裁圆角+色块兜底,isolate 可用)
    ├── dio_error.dart                # Dio 异常 → 用户可读文案
    ├── gallery_image.dart            # 画廊数据层（GalleryImage 模型 + 会话图片收集 + markdown 提取）
    ├── notification_payload.dart     # 通知点击路由解析
    ├── permission_helper.dart        # 运行时权限申请
    ├── secure_storage.dart           # flutter_secure_storage 封装
    └── snackbar.dart

test/
├── e2e/                     # 路由 redirect + tab 切换 widget 测试
├── helpers/                 # mock_adapter.dart + fake_ws.dart（测试基础设施）
├── models/ providers/ services/ utils/ widgets/  # 单元/widget 测试
```

### 页面清单（14 个）

| 页面 | 说明 |
|------|------|
| `SplashPage` | 启动闪屏，决定走登录还是主页 |
| `LoginPage` | 登录/注册 |
| `SelectAccountPage` | 已保存账号选择（多账号切换） |
| `HomePage` | Scaffold + BottomNavigationBar（3 tab 容器） |
| `MessagesPage` | 消息 tab，IM 风格列表（未读红点 + 置顶分组） |
| `AgentListPage` | Agent tab，紧凑列表（行点击 → 聊天；头像点击 → 详情） |
| `AgentDetailPage` | 详情：密钥眼睛切换 + 复制 + 编辑/删除 + 发消息 CTA |
| `ChatPage` | 聊天，入参 `(convId, agentId)` record |
| `ProfilePage` | 我的 tab 入口，用户信息 + 头像 |
| `EditProfilePage` | 编辑昵称/简介/头像 |
| `CropAvatarPage` | `wechat_assets_picker` 选图 + `crop_your_image` 裁剪 |
| `ChangePasswordPage` | 改密码（校验旧密码） |
| `SettingsPage` | 服务器地址配置 |
| `AboutPage` | 版本号（`package_info_plus`） |

### 组件清单

| 组件 | 说明 |
|------|------|
| `Avatar` | 首字母 + hash 色板（avatar_url 为空时降级）；有 url 时拼 baseUrl + Authorization 头；`memCacheWidth` 限解码尺寸防返回闪烁 |
| `AvatarPicker` | 选图 + 裁剪（绕开 Android ActivityResult 崩溃）；导出 `defaultAssetPickerConfig` 共享配置（简中 + 相册名汉化），头像/聊天发图两处复用 |
| `CopyableField` | 复制 + 眼睛切换（用于密钥展示） |
| `MessageBubble` | **StatefulWidget**，负责外壳（气泡/选择态/勾选/长按），内容委托 `ContentRendererRegistry`，透传 `conversationMessages` + `openGallery` 给 renderer。长按：震动 + 进选择态（SelectableRegion+全选拉杆）+ 弹菜单。多选模式渲染左侧 22px 圆形勾选框 |
| `BubbleWithTail` | 带三角的气泡容器（text/markdown/file 共用） |
| `MessageContextMenu` | 长按消息浮动菜单（OverlayEntry + LayerLink 紧贴气泡）：半透明深色 + 三项横向（复制/删除/多选，icon 上文字下） |
| `MarkdownView` | **自控 markdown 渲染**（不用 MarkdownWidget，绕开其 SelectionArea 吞手势）。用 markdown_widget 底层 API：parseLines→WidgetVisitor.visit→SpanNode.build→Column[Text.rich] |
| `SelectAllOrNoneContainer` | 块级整体选中（主流 IM 式），SelectionContainer+Delegate，落块即全选。代码块/LaTeX/表格注入 |
| `markdown_config` | `markdown_widget` 的极简墨白样式预设（`markdownStyle({isDark})`） |
| `markdown_latex` | LaTeX 语法匹配（`LatexSyntax`）+ 渲染节点（`latexGenerator`，走 `flutter_math_fork`）。块级 `$...$` 包 SelectAllOrNoneContainer |
| `markdown_code_wrapper` | 代码块右上角复制按钮（✓ 回弹，无语言标签），外层包 SelectAllOrNoneContainer 整块选中 |
| `TypingBubble` | "对方正在输入" 动画气泡 |
| `UnreadBadge` | 未读数红点 |
| `ConnectionBanner` | WS 断线时顶部条幅 |
| `gallery/zoomable_gallery` | 会话级图片画廊（PageView 翻页 + Hero 共享元素过渡 + 放大态跟随翻页 + 长按保存到相册） |
| `gallery/photo_view/` | 内化的 photo_view 源码（脱离 pub 依赖，提供缩放/平移/fling 惯性） |
| `long_press_detector` | 长按检测器（pointer 层 Listener，不进 arena，message_bubble/gallery 共用） |
| `panel_item` | 加号面板/画廊菜单共用菜单项（52×52 白底圆角12 + outlined 图标 + 灰字） |

### 渲染器体系（lib/rendering/）

| 文件 | 说明 |
|------|------|
| `message_content_renderer` | `MessageContentRenderer` 接口（`selectable`/`wrapInBubble`/`build`）+ `ContentRendererRegistry` 注册表。扩展 HTML/卡片只需 register 一个 renderer |
| `builtin_renderers` | text/markdown/image/file renderer 实现 + `registerBuiltinRenderers()`（main.dart 启动时调） |

## 测试

```bash
flutter test                          # 全量
flutter test test/e2e/                # 仅 E2E
flutter test test/providers/...       # 指定目录
```

测试用 `mocktail` mock ApiService，`FakeWS extends WebSocketService` 注入测试消息流。`test/helpers/mock_adapter.dart` 提供共享 dio HttpClientAdapter mock。

## 主要交互

- **消息 tab**：IM 风格列表（头像 + agent 名 + 最后消息预览 + 时间 + 未读红点），下拉刷新，置顶分组在前，左滑/长按支持隐藏
- **万灵 tab**：紧凑列表，行点击 → 聊天，头像点击 → 详情；右上角 "+" 新建
- **Agent 详情**：密钥默认 `•••` 掩码（眼睛切换）+ AppID/密钥点击复制；编辑昵称 / 删除 / 发消息 CTA
- **聊天页**：文本/Markdown 消息渲染、输入指示器、消息已读回执、长按消息可复制、点击图片全屏查看
- **我的 tab**：用户信息（含头像）+ 编辑资料（昵称/简介/头像裁剪）+ 改密码 + 设置（服务器地址）+ 关于 + 退出登录 + 切换账号
- **多账号**：登录过的账号加密保存，下次进入可在 `SelectAccountPage` 直接选择
- **后台运行**（Android）：APP 退到后台/被杀后，`flutter_background_service` 前台服务保活 WS 连接，新消息通过 `flutter_local_notifications` 推送通知，点击跳转对应会话

## 服务端依赖

详见项目根 `../CLAUDE.md`。关键接口：

- 认证：`POST /api/auth/login` / `POST /api/auth/register` / `POST /api/agents/:id/token`
- 用户：`GET /api/users/me` / `PUT /api/users/me` / `PUT /api/users/me/password`
- Agent：`GET /api/agents` / `POST` / `PUT /api/agents/:id` / `DELETE`
- 会话：`GET /api/conversations` / `POST /api/conversations` (FindOrCreate) / `GET /api/conversations/:id/messages`
- 会话操作：`POST /api/conversations/:id/read` / `POST|DELETE /api/conversations/:id/pin` / `DELETE /api/conversations/:id` (隐藏)
- 文件：`POST /api/upload` / `GET /api/files/:id`
- WebSocket：`GET /ws`（OpCode 协议：Hello / Identify / Heartbeat / Resume / Dispatch）
