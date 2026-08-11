import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/account_mark.dart';
import '../models/saved_login.dart';
import '../providers/auth_provider.dart';
import '../providers/saved_logins_provider.dart';
import '../theme/account_palette.dart';
import '../utils/dio_error.dart';
import '../utils/snackbar.dart';
import 'account_mark_editor.dart';
import 'app_action_menu.dart';
import 'avatar.dart';
import 'feedback/app_dialog.dart';
import 'password_text_field.dart';

/// 账号卡片主标题：备注 > 昵称 > 账号名。
String accountCardTitle(SavedLogin login) {
  if (login.label != null && login.label!.isNotEmpty) return login.label!;
  if (login.username.isNotEmpty) return login.username;
  return login.server;
}

/// 左侧侧滑面板：AppBar 头像触发，迁移自旧「切换账号」底部弹层。
/// 由 HomePage 常驻挂载，进出动画由 HomePage 控制，本组件只负责内容与操作。
class AccountSidebar extends ConsumerStatefulWidget {
  const AccountSidebar({super.key, required this.onClose});

  /// 要求关闭面板：切换成功 / 操作完成时回调。
  final VoidCallback onClose;

  @override
  ConsumerState<AccountSidebar> createState() => _AccountSidebarState();
}

class _AccountSidebarState extends ConsumerState<AccountSidebar> {
  bool _switching = false;

  Future<void> _switchTo(int index) async {
    if (_switching) return; // 防抖
    setState(() => _switching = true);
    try {
      await ref.read(savedLoginsProvider.notifier).switchTo(index);
      if (!mounted) return;
      widget.onClose(); // 成功:收起面板
      showAppSnackBar(context, '已切换账号', type: SnackBarType.success);
    } catch (e) {
      if (mounted) {
        showAppSnackBar(
          context,
          extractDioErrorMessage(e),
          type: SnackBarType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  void _showEditDialog(SavedLogin login, int index) {
    final serverCtrl = TextEditingController(text: login.server);
    final usernameCtrl = TextEditingController(text: login.username);
    final passwordCtrl = TextEditingController(text: login.password);
    final labelCtrl = TextEditingController(text: login.label ?? '');
    AccountMark? currentMark = login.mark;
    bool clearMark = false;
    showAppDialog(
      context: context,
      title: '编辑账号',
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('sidebar_label_field'),
              controller: labelCtrl,
              decoration: const InputDecoration(
                labelText: '备注名(可选)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: serverCtrl,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: usernameCtrl,
              decoration: const InputDecoration(
                labelText: '用户名',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            PasswordTextField(controller: passwordCtrl),
            const SizedBox(height: 16),
            AccountMarkEditor(
              initial: login.mark,
              onChanged: (m) {
                currentMark = m;
                clearMark = (m == null && login.mark != null);
              },
            ),
          ],
        ),
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
          await ref
              .read(savedLoginsProvider.notifier)
              .edit(
                index,
                server: s,
                username: u,
                password: p,
                label: labelCtrl.text.trim(),
                mark: currentMark,
                clearMark: clearMark,
              );
          if (mounted) Navigator.of(context).pop();
        } catch (e) {
          if (mounted) {
            showAppSnackBar(context, e.toString(), type: SnackBarType.error);
          }
        }
      },
    );
  }

  void _showAddDialog() {
    final serverCtrl = TextEditingController();
    final usernameCtrl = TextEditingController();
    final passwordCtrl = TextEditingController();
    final labelCtrl = TextEditingController();
    AccountMark? currentMark;
    showAppDialog(
      context: context,
      title: '添加账号',
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('sidebar_label_field'),
              controller: labelCtrl,
              decoration: const InputDecoration(
                labelText: '备注名(可选)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: serverCtrl,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: usernameCtrl,
              decoration: const InputDecoration(
                labelText: '用户名',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            PasswordTextField(controller: passwordCtrl),
            const SizedBox(height: 16),
            AccountMarkEditor(initial: null, onChanged: (m) => currentMark = m),
          ],
        ),
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
          await ref
              .read(savedLoginsProvider.notifier)
              .add(
                s,
                u,
                p,
                label: labelCtrl.text.trim().isEmpty
                    ? null
                    : labelCtrl.text.trim(),
                mark: currentMark,
              );
          if (mounted) Navigator.of(context).pop();
        } catch (e) {
          if (mounted) {
            showAppSnackBar(context, e.toString(), type: SnackBarType.error);
          }
        }
      },
    );
  }

  void _showDeleteConfirm(int index, SavedLogin login) {
    showAppDialog(
      context: context,
      title: '确认删除',
      content: Text('确认删除 ${login.username} @ ${login.server}?'),
      confirmText: '确认',
      dismissOnConfirm: false,
      onConfirm: () async {
        try {
          await ref.read(savedLoginsProvider.notifier).remove(index);
          if (mounted) Navigator.of(context).pop();
        } catch (e) {
          if (mounted) {
            showAppSnackBar(context, e.toString(), type: SnackBarType.error);
          }
        }
      },
    );
  }

  /// 克隆账号卡片:生成同 server 的完整副本(自动处理 username 冲突),提示用户去编辑。
  void _duplicate(int index) {
    ref.read(savedLoginsProvider.notifier).duplicate(index).then((_) {
      if (mounted) {
        showAppSnackBar(context, '已复制,可点击 ⋯ 编辑新账号',
            type: SnackBarType.success);
      }
    }).catchError((e) {
      if (mounted) {
        showAppSnackBar(context, e.toString(), type: SnackBarType.error);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(savedLoginsProvider);
    final user = ref.watch(authProvider).user;
    final current = state.selected;
    final width = MediaQuery.of(context).size.width * 0.78;

    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 16,
            offset: Offset(4, 0),
          ),
        ],
      ),
      child: Stack(
        children: [
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // —— 用户信息头部：白底，昵称下方简介，无关闭按钮 ——
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
                  child: Row(
                    children: [
                      Avatar(
                        name: user?.displayName ?? '?',
                        url: user?.avatarUrl,
                        size: 52,
                        radius: 10,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user?.displayName ?? '未登录',
                              style: const TextStyle(
                                color: Color(0xFF111111),
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (user != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                (user.bio != null && user.bio!.isNotEmpty)
                                    ? user.bio!
                                    : (current?.server ?? ''),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Color(0xFF999999),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                // —— 标题行 ——
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 14, 16, 0),
                  child: Row(
                    children: [
                      Text(
                        '切换账号',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Spacer(),
                      Text(
                        '点击账号直接切换',
                        style: TextStyle(
                          fontSize: 11,
                          color: Color(0xFF999999),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // —— 账号列表 ——
                Expanded(
                  child: state.isEmpty
                      ? const Center(
                          child: Text(
                            '暂无记录',
                            style: TextStyle(color: Color(0xFF999999)),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          itemCount: state.logins.length,
                          itemBuilder: (_, i) => _AccountCard(
                            login: state.logins[i],
                            isCurrent: i == state.selectedIndex,
                            onTap: () => _switchTo(i),
                            onEdit: () => _showEditDialog(state.logins[i], i),
                            onDuplicate: () => _duplicate(i),
                            onDelete: () =>
                                _showDeleteConfirm(i, state.logins[i]),
                          ),
                        ),
                ),
                // —— 添加服务器 ——
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: OutlinedButton.icon(
                    onPressed: _showAddDialog,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('添加服务器'),
                  ),
                ),
              ],
            ),
          ),
          // 切换中遮罩(防抖 + 用户感知,覆盖整个侧边栏含状态栏区域)
          if (_switching)
            Positioned.fill(
              child: Container(
                color: Colors.black38,
                alignment: Alignment.center,
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(strokeWidth: 2),
                    SizedBox(height: 12),
                    Text(
                      '切换中…',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 侧边栏内的账号卡片。
class _AccountCard extends StatelessWidget {
  final SavedLogin login;
  final bool isCurrent;
  final VoidCallback onTap;
  final VoidCallback onEdit;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;

  const _AccountCard({
    required this.login,
    required this.isCurrent,
    required this.onTap,
    required this.onEdit,
    required this.onDuplicate,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mark = login.mark != null
        ? AccountPalette.colorAt(login.mark!.colorIndex)
        : theme.colorScheme.primary;
    final title = accountCardTitle(login);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          gradient: isCurrent
              ? LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    mark.withValues(alpha: 0.22),
                    mark.withValues(alpha: 0.06),
                  ],
                )
              : null,
          color: isCurrent ? null : mark.withValues(alpha: 0.06),
          border: Border(
            left: BorderSide(
              width: isCurrent ? 4 : 2,
              color: isCurrent ? mark : mark.withValues(alpha: 0.5),
            ),
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: isCurrent ? null : onTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  // leading 方块：mark 色字/字母
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: isCurrent
                          ? mark.withValues(alpha: 0.18)
                          : mark.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      login.mark?.emoji ??
                          (login.username.isNotEmpty
                              ? login.username.characters.first.toUpperCase()
                              : '?'),
                      style: TextStyle(
                        fontSize: 15,
                        color: isCurrent ? mark : null,
                        fontWeight: isCurrent ? FontWeight.w600 : null,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight:
                                isCurrent ? FontWeight.w700 : FontWeight.w500,
                            color: const Color(0xFF111111),
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          '${login.username} @ ${login.server}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFF999999),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isCurrent)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: mark,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: const Text(
                        '当前',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  // ⋯ 菜单:编辑 / 复制 / 删除(统一竖排菜单样式)
                  Builder(
                    builder: (menuCtx) => IconButton(
                      icon: const Icon(Icons.more_horiz, size: 20),
                      tooltip: '更多操作',
                      onPressed: () async {
                        final box =
                            menuCtx.findRenderObject() as RenderBox?;
                        final pos =
                            box?.localToGlobal(Offset.zero) ?? Offset.zero;
                        final selected = await showAppActionMenu(
                          menuCtx,
                          pos,
                          items: const [
                            ActionMenuItem(
                              value: 'edit',
                              label: '编辑',
                              icon: Icons.edit_outlined,
                            ),
                            ActionMenuItem(
                              value: 'duplicate',
                              label: '复制',
                              icon: Icons.copy_outlined,
                            ),
                            ActionMenuItem(
                              value: 'delete',
                              label: '删除',
                              icon: Icons.delete_outline,
                              color: Color(0xFFFA5151),
                            ),
                          ],
                        );
                        if (selected == 'edit') {
                          onEdit();
                        } else if (selected == 'duplicate') {
                          onDuplicate();
                        } else if (selected == 'delete') {
                          onDelete();
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
