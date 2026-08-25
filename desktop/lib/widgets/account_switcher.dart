import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import '../utils/dio_error.dart';
import 'add_account_dialog.dart';

/// 菜单「添加服务器/账号」项的特殊 value(与账号索引区分)。
const _addEntry = -1;

/// 登录页顶部多账号切换器。
///
/// savedLogins 为空时不渲染(除非 alwaysShow,工具条底部需常驻入口);
/// 点击弹出账号菜单(username@server),选中即调 SavedLoginsNotifier
/// .switchTo:silent logout → 切 baseUrl → 用保存的凭据自动登录,
/// 全程 isSwitching 守卫防 router 误跳。
///
/// iconOnly=true 时 child 只渲染「切换」双箭头图标(工具条底部紧凑
/// 模式,区别于头像),菜单逻辑与完整模式一致。
class AccountSwitcher extends ConsumerWidget {
  final bool iconOnly;

  /// savedLogins 为空时是否仍渲染(工具条常驻入口,菜单提示暂无账号)。
  final bool alwaysShow;

  const AccountSwitcher({super.key, this.iconOnly = false, this.alwaysShow = false});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedLoginsProvider);
    if (saved.isEmpty && !alwaysShow) return const SizedBox.shrink();
    final busy = ref.watch(
      authProvider.select((s) => s.isSwitching || s.isLoading),
    );
    final current = saved.selected;
    final scheme = Theme.of(context).colorScheme;

    return PopupMenuButton<int>(
      key: const ValueKey('account_switcher_button'),
      enabled: !busy,
      tooltip: '切换服务器/账号',
      itemBuilder: (_) => [
        if (saved.logins.isEmpty)
          const PopupMenuItem(enabled: false, child: Text('暂无已保存账号'))
        else
          for (var i = 0; i < saved.logins.length; i++)
            PopupMenuItem(
              value: i,
              child: Text(
                '${saved.logins[i].username}@${saved.logins[i].server}',
              ),
            ),
        // 添加新服务器/账号(对齐 app select_account_page「+ 添加服务器」):
        // 登录页表单即添加流程,勾选记住账号后自动入 savedLogins。
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: _addEntry,
          child: Row(
            children: [
              Icon(Icons.add, size: 18),
              SizedBox(width: 6),
              Text('添加服务器/账号'),
            ],
          ),
        ),
      ],
      onSelected: (i) async {
        if (i == _addEntry) {
          // 弹添加框(对齐 app select_account_page):填完保存进
          // savedLogins,是否立即登录由用户在列表里点选。
          await showAddAccountDialog(context, ref);
          return;
        }
        try {
          // 登录页处于登出态:selectedIndex 仍指上次账号,switchTo 对
          // i==selectedIndex 是 no-op(点了没反应),且未登录时多余 logout 会
          // 触发 server 黑名单请求。登出态用 loginWith(无 no-op 短路、
          // 不 logout),登录态(预留复用)用 switchTo(silent logout→登录)。
          final loggedIn =
              ref.read(authProvider.select((s) => s.isAuthenticated));
          final notifier = ref.read(savedLoginsProvider.notifier);
          if (loggedIn) {
            // 已登录:in-place 静默切换(switchTo 内部 silent logout → 切
            // baseUrl → 保存凭据重登,全程 isSwitching 守卫 router 不跳登录页),
            // 成功反馈对齐 app account_sidebar。
            await notifier.switchTo(i);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已切换账号')),
              );
            }
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
          ? SizedBox(
              width: 36,
              height: 36,
              child: Center(
                child: Icon(
                  Icons.swap_horiz,
                  size: 21,
                  color: scheme.onSurface.withValues(alpha: 0.6),
                ),
              ),
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
