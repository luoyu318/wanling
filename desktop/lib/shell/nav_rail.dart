import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/no_conversation_hint_provider.dart';

/// 左侧导航窄栏:消息/万灵/设置 + 底部退出(账号头像 Task 4 接入)。
/// 离开消息页时清除 noConversationHintProvider 的无会话提示
/// (本栏常驻且不 watch 该 provider,清除无 defunct 风险)。
class NavRail extends ConsumerWidget {
  const NavRail({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final location = GoRouterState.of(context).uri.path;
    Widget item(IconData icon, String label, String route) {
      final selected = location.startsWith(route);
      return Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 300),
        child: IconButton(
          icon: Icon(icon, size: 20),
          color: selected ? Theme.of(context).colorScheme.primary : null,
          onPressed: () {
            if (route != '/messages') {
              ref.read(noConversationHintProvider.notifier).state = null;
            }
            context.go(route);
          },
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
