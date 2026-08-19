import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// 左侧导航窄栏:消息/万灵/设置 + 底部退出(账号头像 Task 4 接入)。
class NavRail extends StatelessWidget {
  const NavRail({super.key});
  @override
  Widget build(BuildContext context) {
    final location = GoRouterState.of(context).uri.path;
    Widget item(IconData icon, String label, String route) {
      final selected = location.startsWith(route);
      return Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 300),
        child: IconButton(
          icon: Icon(icon, size: 20),
          color: selected ? Theme.of(context).colorScheme.primary : null,
          onPressed: () => context.go(route),
        ),
      );
    }

    return Container(
      width: 36,
      color:
          Theme.of(context).navigationBarTheme.backgroundColor ??
          Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          item(Icons.chat_bubble_outline, '消息', '/messages'),
          item(Icons.extension_outlined, '万灵', '/wanling'),
          item(Icons.settings_outlined, '设置', '/settings'),
        ],
      ),
    );
  }
}
