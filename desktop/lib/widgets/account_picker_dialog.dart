import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/models/saved_login.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import '../utils/dio_error.dart';
import 'add_account_dialog.dart';

/// 服务器/账号选择弹窗(对齐 app /select-account 页面的桌面对话框形态)。
///
/// 使用方:登录页「切换服务器/账号」按钮(登出态)。
/// - 点账号卡片 → loginWith 用保存凭据直接登录,成功关窗跳 /messages
/// - 尾部「+ 添加服务器」→ [showAddAccountDialog]
/// - 卡片尾部删除(确认后 remove)
Future<void> showAccountPickerDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  await showDialog<void>(
    context: context,
    builder: (dialogCtx) => const _AccountPickerDialog(),
  );
}

class _AccountPickerDialog extends ConsumerStatefulWidget {
  const _AccountPickerDialog();

  @override
  ConsumerState<_AccountPickerDialog> createState() =>
      _AccountPickerDialogState();
}

class _AccountPickerDialogState extends ConsumerState<_AccountPickerDialog> {
  bool _switching = false;
  String? _error;

  @override
  Widget build(BuildContext context) {
    final saved = ref.watch(savedLoginsProvider);
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('切换服务器/账号'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_error != null) ...[
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
              ),
              const SizedBox(height: 8),
            ],
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < saved.logins.length; i++)
                      _card(context, i, saved.logins[i], saved.selectedIndex,
                          theme),
                    if (saved.logins.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Text(
                          '暂无记录',
                          style: TextStyle(color: theme.hintColor),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              key: const ValueKey('picker_add_account'),
              onPressed:
                  _switching ? null : () => showAddAccountDialog(context, ref),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加服务器'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(BuildContext context, int index, SavedLogin login, int selected,
      ThemeData theme) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: index == selected
              ? theme.colorScheme.primary
              : theme.dividerColor,
        ),
      ),
      child: ListTile(
        dense: true,
        enabled: !_switching,
        leading: Icon(
          Icons.account_circle,
          size: 28,
          color: theme.colorScheme.primary,
        ),
        title: Text(
          '${login.username}@${login.server}',
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 13),
        ),
        subtitle: (login.label ?? '').isNotEmpty
            ? Text(
                login.label!,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              )
            : null,
        trailing: IconButton(
          icon: const Icon(Icons.delete_outline, size: 18),
          tooltip: '删除',
          onPressed:
              _switching ? null : () => _confirmRemove(context, index, login),
        ),
        onTap: _switching ? null : () => _loginWith(context, index),
      ),
    );
  }

  /// 登出态直登(loginWith 无 no-op 短路);成功关窗进主界面。
  /// 参数 context 仅用于 await 前取 Navigator/GoRouter 引用(lint 要求
  /// 跨 async 使用时在 mounted 守卫下走 State.context)。
  Future<void> _loginWith(BuildContext context, int index) async {
    final navigator = Navigator.of(context);
    final router = GoRouter.of(context);
    setState(() {
      _switching = true;
      _error = null;
    });
    try {
      await ref.read(savedLoginsProvider.notifier).loginWith(index);
      if (!mounted) return;
      navigator.pop();
      router.go('/messages');
    } catch (e) {
      if (mounted) setState(() => _error = extractDioErrorMessage(e));
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _confirmRemove(
      BuildContext context, int index, SavedLogin login) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确认删除 ${login.username} @ ${login.server}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ref.read(savedLoginsProvider.notifier).remove(index);
    }
  }
}
