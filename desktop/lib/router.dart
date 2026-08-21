import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/providers/auth_provider.dart';
import 'shell/desktop_shell.dart';
import 'pages/agent_detail_page.dart';
import 'pages/login_page.dart';
import 'pages/messages_page.dart';
import 'pages/subagent_detail_page.dart';
import 'pages/wanling_page.dart';
import 'pages/settings_page.dart';

/// 桌面路由:/login 独立;/messages /wanling /settings 共享 DesktopShell(左导航+内容)。
///
/// 登录态守卫(与 app 壳 router 同语义):watch authProvider → 登录态变化时
/// router 重建触发 redirect 重判;切换账号(isSwitching)期间视同已登录,
/// logout→login 中间态不误跳 /login。
final routerProvider = Provider<GoRouter>((ref) {
  final auth = ref.watch(authProvider);
  return GoRouter(
    initialLocation: '/messages',
    redirect: (ctx, state) {
      final loggedIn = auth.isAuthenticated || auth.isSwitching;
      final isAuthFlow = state.matchedLocation == '/login';
      if (!loggedIn && !isAuthFlow) return '/login';
      if (loggedIn && isAuthFlow) return '/messages';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (c, s) => const DesktopLoginPage()),
      ShellRoute(
        builder: (c, s, child) => DesktopShell(child: child),
        routes: [
          GoRoute(path: '/messages', builder: (c, s) => const MessagesPage()),
          GoRoute(path: '/wanling', builder: (c, s) => const WanlingPage()),
          GoRoute(path: '/settings', builder: (c, s) => const SettingsPage()),
          // agent 详情(万灵列表点击推入,渲染进右卡片)
          GoRoute(
            path: '/agent/:id',
            builder: (c, s) =>
                AgentDetailPage(agentId: s.pathParameters['id']!),
          ),
          // 子 Agent 详情页:core 渲染层 task 卡片硬编码 push
          // '/chat/subagent/:taskCardId?convId=...&title=...',desktop 必须
          // 匹配该 path(本壳无 /chat/:convId 路由,无静态段吞参冲突)。
          // 参数校验 fail-fast(对齐 app 壳 router):taskCardId/convId
          // 缺失或非 UUID 直接渲染错误页,不放行到 api 拼无效路径。
          GoRoute(
            path: '/chat/subagent/:taskCardId',
            builder: (c, s) {
              final taskCardId = s.pathParameters['taskCardId'] ?? '';
              final convId = s.uri.queryParameters['convId'] ?? '';
              final title = s.uri.queryParameters['title'] ?? '';
              final uuid = RegExp(
                r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
              );
              if (taskCardId.isEmpty || convId.isEmpty) {
                return const SubagentParamErrorView(
                  message: '链接缺少必要参数(convId / taskCardId)',
                );
              }
              if (!uuid.hasMatch(taskCardId) || !uuid.hasMatch(convId)) {
                return const SubagentParamErrorView(
                  message: '链接参数格式错误(需合法 UUID)',
                );
              }
              return SubagentDetailPage(
                taskCardId: taskCardId,
                convId: convId,
                title: title,
              );
            },
          ),
        ],
      ),
    ],
  );
});
