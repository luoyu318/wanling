# APP 入口与路由

main.dart + router.dart + router_helpers.dart。

## main.dart

入口。`async main` 在 runApp 前调 `restoreSession` 拉用户信息，避免首帧渲染时 auth 状态未定。`MaterialApp.router` 固定 `locale: Locale('zh')` + `supportedLocales: [zh]` + Material/Widgets/Cupertino 三套 `localizationsDelegates`（让内置组件和第三方插件拿到 zh locale，否则 wechat_assets_picker 会因 Flutter 默认 supportedLocales=[en,US] 被解析成英文）。

## router.dart

GoRouter 配置。3-tab 保活由 `HomePage` 内嵌 `NestedPageView` 实现（外层万灵↔我的 + 内层消息↔万灵，`AutomaticKeepAliveClientMixin` 保活），router 层是 25 条平铺 `GoRoute`。redirect 根据 `authProvider.isAuthenticated` 守卫。**转场动画**：25 个路由统一用 `pageBuilder` + `CustomTransitionPage` + 手写 `SlideTransition`（横向平移，200ms，easeOut），替代 Material 3 默认的 Zoom 缩放转场，对齐主流 IM 利落手感。用 `_cupertinoPage` 工厂统一构建，**每个 pageBuilder 必须传 `key: state.pageKey`**（否则 pushReplacement 时新旧 page key 相同，Flutter 复用旧 State，新页 initState/_markRead 不触发——曾导致「通知跳转后未读不清」bug）。取舍：放弃 iOS 边缘左滑跟手返回（`TransitionsBuilder` 签名无 route 参数挂不了手势）。

**关键路由顺序约束**(v1.0.10): `/chat/subagent/:taskCardId` 必须排在 `/chat/:convId` 之前,否则 GoRouter 把 path 第一段 'subagent' 当成 `:convId` 匹配(对齐 `/conversations/new/group` vs `/conversations/:id/detail` 模式)。subagent 路由的 convId 走 query 参数,空 convId/taskCardId 时 pageBuilder 内 fail-fast 返错误页(避免 api_service 拼出空路径段让 server Gin 行为未定义)

## router_helpers.dart

`chatRoute(convId, agentId)` 拼路径 + `startChatAndPush(context, ref, agent)` 统一 findOrCreate + 跳转。
