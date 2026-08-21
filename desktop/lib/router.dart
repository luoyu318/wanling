import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/providers/auth_provider.dart';
import 'shell/desktop_shell.dart';
import 'pages/agent_detail_page.dart';
import 'pages/login_page.dart';
import 'pages/messages_page.dart';
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
        ],
      ),
    ],
  );
});
