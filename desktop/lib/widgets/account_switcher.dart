import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import '../utils/dio_error.dart';

/// 登录页顶部多账号切换器。
///
/// savedLogins 为空时不渲染;点击弹出账号菜单(username@server),
/// 选中即调 SavedLoginsNotifier.switchTo:silent logout → 切 baseUrl →
/// 用保存的凭据自动登录,全程 isSwitching 守卫防 router 误跳。
///
/// iconOnly=true 时 child 只渲染账号图标(工具条底部紧凑模式),
/// 菜单逻辑与完整模式一致。
class AccountSwitcher extends ConsumerWidget {
  final bool iconOnly;

  const AccountSwitcher({super.key, this.iconOnly = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedLoginsProvider);
    if (saved.isEmpty) return const SizedBox.shrink();
    final busy = ref.watch(
      authProvider.select((s) => s.isSwitching || s.isLoading),
    );
    final current = saved.selected;

    return PopupMenuButton<int>(
      key: const ValueKey('account_switcher_button'),
      enabled: !busy,
      tooltip: '切换服务器/账号',
      itemBuilder: (_) => [
        for (var i = 0; i < saved.logins.length; i++)
          PopupMenuItem(
            value: i,
            child: Text(
              '${saved.logins[i].username}@${saved.logins[i].server}',
            ),
          ),
      ],
      onSelected: (i) async {
        try {
          // 登录页处于登出态:selectedIndex 仍指上次账号,switchTo 对
          // i==selectedIndex 是 no-op(点了没反应),且未登录时多余 logout 会
          // 触发 server 黑名单请求。登出态用 loginWith(无 no-op 短路、
          // 不 logout),登录态(预留复用)用 switchTo(silent logout→登录)。
          final loggedIn =
              ref.read(authProvider.select((s) => s.isAuthenticated));
          final notifier = ref.read(savedLoginsProvider.notifier);
          if (loggedIn) {
            await notifier.switchTo(i);
          } else {
            await notifier.loginWith(i);
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(extractDioErrorMessage(e))));
          }
        }
      },
      child: iconOnly
          ? const Padding(
              padding: EdgeInsets.all(8),
              child: Icon(Icons.account_circle, size: 22),
            )
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.account_circle, size: 20),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      current != null
                          ? '${current.username}@${current.server}'
                          : '切换账号',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (busy)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    const Icon(Icons.arrow_drop_down, size: 18),
                ],
              ),
            ),
    );
  }
}
