import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/providers/saved_logins_provider.dart';

/// 「添加服务器/账号」弹框(对齐 app select_account_page._showAccountDialog
/// 的桌面简化版:备注/服务器/用户名/密码四字段,无头像标记编辑器)。
///
/// 保存走 [SavedLoginsNotifier.add](同 server+username 去重),成功后关闭。
/// 使用方:NavRail AccountSwitcher 菜单 + 登录页「添加服务器」按钮。
Future<void> showAddAccountDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  final serverCtrl = TextEditingController();
  final usernameCtrl = TextEditingController();
  final passwordCtrl = TextEditingController();
  final labelCtrl = TextEditingController();
  var obscure = true;
  String? error;
  var submitting = false;

  await showDialog<void>(
    context: context,
    builder: (dialogCtx) => StatefulBuilder(
      builder: (dialogCtx, setDialogState) => AlertDialog(
        title: const Text('添加服务器/账号'),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('add_label_field'),
                controller: labelCtrl,
                decoration: const InputDecoration(
                  labelText: '备注名(可选)',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('add_server_field'),
                controller: serverCtrl,
                decoration: const InputDecoration(
                  labelText: '服务器地址',
                  border: OutlineInputBorder(),
                  hintText: 'http://your-server:18008',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('add_username_field'),
                controller: usernameCtrl,
                // 不设 autofillHints:弹窗路由的 autofill 组随 pop 同帧拆除,
                // 与退出动画竞态会触发 framework「dependents.isEmpty」断言红屏。
                decoration: const InputDecoration(
                  labelText: '用户名',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('add_password_field'),
                controller: passwordCtrl,
                obscureText: obscure,
                decoration: InputDecoration(
                  labelText: '密码',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscure ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () => setDialogState(() => obscure = !obscure),
                  ),
                ),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(
                  error!,
                  style: TextStyle(
                    color: Theme.of(dialogCtx).colorScheme.error,
                    fontSize: 13,
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: submitting
                ? null
                : () async {
                    final s = serverCtrl.text.trim();
                    final u = usernameCtrl.text.trim();
                    final p = passwordCtrl.text;
                    if (s.isEmpty || u.isEmpty || p.isEmpty) {
                      setDialogState(() => error = '请填写完整');
                      return;
                    }
                    setDialogState(() {
                      submitting = true;
                      error = null;
                    });
                    try {
                      await ref
                          .read(savedLoginsProvider.notifier)
                          .add(s, u, p, label: labelCtrl.text.trim());
                      if (!dialogCtx.mounted) return;
                      Navigator.of(dialogCtx).pop();
                    } catch (e) {
                      setDialogState(() {
                        submitting = false;
                        error = '$e';
                      });
                    }
                  },
            child: submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
    ),
  );
  // controller 延迟销毁:showDialog 的 Future 在 pop 动画「开始」时即完成,
  // 立即 dispose 会让退出动画期间的 TextField 撞已销毁 controller。
  // 300ms 覆盖默认 150ms 退出动画,之后销毁不阻 GC 太久。
  Future.delayed(const Duration(milliseconds: 300), () {
    for (final c in [serverCtrl, usernameCtrl, passwordCtrl, labelCtrl]) {
      c.dispose();
    }
  });
}
