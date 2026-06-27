import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/saved_login.dart';
import '../providers/saved_logins_provider.dart';
import '../utils/snackbar.dart';
import '../widgets/feedback/app_dialog.dart';

/// 独立的选择账号页面。从登录页「切换服务器/账号」入口进入。
///
/// 交互:
/// - 点卡片本体 → select(index) + Navigator.pop(返回登录页)
/// - 点 ✏ 编辑 → 弹 dialog 改 server/username/password
/// - 点 🗑 删除 → 弹确认 dialog
/// - 点 + 添加服务器 → 弹 dialog 填新组合
class SelectAccountPage extends ConsumerWidget {
  const SelectAccountPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(savedLoginsProvider);
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('选择账号'),
      ),
      body: state.isEmpty
          ? _buildEmpty(context, ref)
          : _buildList(context, ref, state),
    );
  }

  Widget _buildEmpty(BuildContext context, WidgetRef ref) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('暂无记录', style: TextStyle(color: Color(0xFF999999))),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () => _showAddDialog(context, ref),
            icon: const Icon(Icons.add),
            label: const Text('添加服务器'),
          ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, WidgetRef ref, SavedLoginsState state) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            '点击账号自动返回登录页',
            style: TextStyle(color: Color(0xFF999999), fontSize: 12),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            itemCount: state.logins.length,
            itemBuilder: (_, i) => _LoginCard(
              login: state.logins[i],
              index: i,
              selected: i == state.selectedIndex,
              onTap: () {
                ref.read(savedLoginsProvider.notifier).select(i);
                Navigator.pop(context);
              },
              onEdit: () => _showEditDialog(context, ref, i, state.logins[i]),
              onDelete: () =>
                  _showDeleteConfirm(context, ref, i, state.logins[i]),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton.icon(
            onPressed: () => _showAddDialog(context, ref),
            icon: const Icon(Icons.add),
            label: const Text('添加服务器'),
          ),
        ),
      ],
    );
  }

  void _showAddDialog(BuildContext context, WidgetRef ref) {
    _showAccountDialog(
      context: context,
      title: '添加账号',
      initial: const SavedLogin(server: '', username: '', password: ''),
      onSubmit: (server, username, password) =>
          ref.read(savedLoginsProvider.notifier).add(
                server,
                username,
                password,
              ),
    );
  }

  void _showEditDialog(
      BuildContext context, WidgetRef ref, int index, SavedLogin login) {
    _showAccountDialog(
      context: context,
      title: '编辑账号',
      initial: login,
      onSubmit: (server, username, password) =>
          ref.read(savedLoginsProvider.notifier).edit(
                index,
                server: server,
                username: username,
                password: password,
              ),
    );
  }

  void _showDeleteConfirm(
      BuildContext context, WidgetRef ref, int index, SavedLogin login) {
    showAppDialog(
      context: context,
      title: '确认删除',
      content: Text('确认删除 ${login.username} @ ${login.server}?'),
      confirmText: '确认',
      onConfirm: () => ref.read(savedLoginsProvider.notifier).remove(index),
    );
  }

  /// 通用添加/编辑 dialog:三个字段 + 提交按钮。
  void _showAccountDialog({
    required BuildContext context,
    required String title,
    required SavedLogin initial,
    required Future<void> Function(
            String server, String username, String password)
        onSubmit,
  }) {
    final serverCtrl = TextEditingController(text: initial.server);
    final usernameCtrl = TextEditingController(text: initial.username);
    final passwordCtrl = TextEditingController(text: initial.password);
    showAppDialog(
      context: context,
      title: title,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: serverCtrl,
            decoration: const InputDecoration(
                labelText: '服务器地址', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: usernameCtrl,
            decoration: const InputDecoration(
                labelText: '用户名', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: passwordCtrl,
            obscureText: true,
            decoration: const InputDecoration(
                labelText: '密码', border: OutlineInputBorder()),
          ),
        ],
      ),
      confirmText: '保存',
      dismissOnConfirm: false,
      onConfirm: () async {
        final s = serverCtrl.text.trim();
        final u = usernameCtrl.text.trim();
        final p = passwordCtrl.text;
        if (s.isEmpty || u.isEmpty || p.isEmpty) {
          if (context.mounted) {
            showAppSnackBar(context, '请填写完整', type: SnackBarType.error);
          }
          return;
        }
        try {
          await onSubmit(s, u, p);
          if (context.mounted) Navigator.of(context).pop();
        } catch (e) {
          if (context.mounted) {
            showAppSnackBar(context, e.toString(), type: SnackBarType.error);
          }
        }
      },
    );
  }
}

/// 单张登录卡片。selected=true 时左侧显示主题色条 + 高亮背景。
class _LoginCard extends StatelessWidget {
  final SavedLogin login;
  final int index;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  const _LoginCard({
    required this.login,
    required this.index,
    required this.selected,
    required this.onTap,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  width: 3,
                  color: selected
                      ? theme.colorScheme.primary
                      : Colors.transparent,
                ),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (selected)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Row(
                            children: [
                              Icon(Icons.check_circle,
                                  size: 12, color: theme.colorScheme.primary),
                              const SizedBox(width: 4),
                            ],
                          ),
                        ),
                      Text(login.server,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 2),
                      Text('账号: ${login.username}',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF999999))),
                    ],
                  ),
                ),
                IconButton(
                  key: ValueKey('edit_$index'),
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  onPressed: onEdit,
                ),
                IconButton(
                  key: ValueKey('delete_$index'),
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: onDelete,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
