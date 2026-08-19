import 'package:go_router/go_router.dart';

import 'shell/desktop_shell.dart';
import 'pages/login_page.dart';
import 'pages/messages_page.dart';
import 'pages/wanling_page.dart';
import 'pages/settings_page.dart';

/// 桌面路由:/login 独立;/messages /wanling /settings 共享 DesktopShell(左导航+内容)。
final router = GoRouter(
  initialLocation: '/login',
  routes: [
    GoRoute(path: '/login', builder: (c, s) => const DesktopLoginPage()),
    ShellRoute(
      builder: (c, s, child) => DesktopShell(child: child),
      routes: [
        GoRoute(path: '/messages', builder: (c, s) => const MessagesPage()),
        GoRoute(path: '/wanling', builder: (c, s) => const WanlingPage()),
        GoRoute(path: '/settings', builder: (c, s) => const SettingsPage()),
      ],
    ),
  ],
);
