import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:wanling_core/models/account_mark.dart';
import 'package:wanling_core/models/saved_login.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:wanling_core/theme/account_palette.dart';
import 'package:wanling_core/theme/app_colors.dart';
import '../utils/dio_error.dart';
import 'package:wanling_core/utils/snackbar.dart';
import '../widgets/account_mark_editor.dart';
import '../widgets/feedback/app_dialog.dart';
import '../widgets/password_text_field.dart';

/// 独立的选择账号页面。从登录页「切换服务器/账号」入口进入。
///
/// 交互:
/// - 点卡片本体 → loginWith 用保存凭据直接登录(切换中显示 loading 遮罩)
/// - 点 ✏ 编辑 → 弹 dialog 改 server/username/password/label/mark
/// - 点 🗑 删除 → 弹确认 dialog
/// - 点 + 添加服务器 → 弹 dialog 填新组合
///
/// 与 switch_account_sheet(已登录态"我的"切换账号)的区别:本页面在登出态打开,
/// 用 loginWith 而非 switchTo——后者在 index==selectedIndex 时 no-op 短路,
/// 会让"点已选中卡片重新登录"失效。
class SelectAccountPage extends ConsumerStatefulWidget {
  const SelectAccountPage({super.key});

  @override
  ConsumerState<SelectAccountPage> createState() => _SelectAccountPageState();
}

class _SelectAccountPageState extends ConsumerState<SelectAccountPage> {
  bool _switching = false;

  /// 点卡片:用保存凭据直接登录。
  ///
  /// SelectAccountPage 在登出态被打开(从登录页"切换服务器/账号"进入),
  /// 此时 selectedIndex 仍指向前次登录账号,用 switchTo 会因"index==selected"
  /// no-op 短路导致已选中卡片点击无反应。改用 loginWith:
  /// - 不 no-op 短路(已选中卡片也会真的登录)
  /// - 不调 silent logout(本就登出态,重复 logout 多余)
  /// 失败时提示并保持在本页(不 pop)。
  Future<void> _switchTo(int index) async {
    if (_switching) return; // 防抖
    setState(() => _switching = true);
    try {
      await ref.read(savedLoginsProvider.notifier).loginWith(index);
      // 成功:router 因 auth 变化自动跳转,无需手动 pop
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, extractDioErrorMessage(e),
            type: SnackBarType.error);
      }
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(savedLoginsProvider);
    return Scaffold(
      backgroundColor: AppColors.pageBgLight,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(),
        ),
        title: const Text('选择账号'),
      ),
      body: Stack(
        children: [
          state.isEmpty
              ? _buildEmpty(state)
              : _buildList(context, state),
          // 切换/登录中遮罩(防抖 + 用户感知)
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
                    Text('登录中…',
                        style: TextStyle(color: Colors.white, fontSize: 13)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEmpty(SavedLoginsState state) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text('暂无记录', style: TextStyle(color: Color(0xFF999999))),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () => _showAddDialog(context),
            icon: const Icon(Icons.add),
            label: const Text('添加服务器'),
          ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, SavedLoginsState state) {
    return Column(
      children: [
        const Padding(
          padding: EdgeInsets.all(12),
          child: Text(
            '点击账号直接登录',
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
              onTap: () => _switchTo(i),
              onEdit: () => _showEditDialog(context, i, state.logins[i]),
              onDelete: () =>
                  _showDeleteConfirm(context, i, state.logins[i]),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: OutlinedButton.icon(
            onPressed: () => _showAddDialog(context),
            icon: const Icon(Icons.add),
            label: const Text('添加服务器'),
          ),
        ),
      ],
    );
  }

  void _showAddDialog(BuildContext context) {
    _showAccountDialog(
      context: context,
      title: '添加账号',
      initial: const SavedLogin(server: '', username: '', password: ''),
      onSubmit: (server, username, password, label, mark, clearMark) =>
          ref.read(savedLoginsProvider.notifier).add(
                server,
                username,
                password,
                label: label,
                mark: mark,
              ),
    );
  }

  void _showEditDialog(
      BuildContext context, int index, SavedLogin login) {
    _showAccountDialog(
      context: context,
      title: '编辑账号',
      initial: login,
      onSubmit: (server, username, password, label, mark, clearMark) =>
          ref.read(savedLoginsProvider.notifier).edit(
                index,
                server: server,
                username: username,
                password: password,
                label: label,
                mark: mark,
                clearMark: clearMark,
              ),
    );
  }

  void _showDeleteConfirm(
      BuildContext context, int index, SavedLogin login) {
    showAppDialog(
      context: context,
      title: '确认删除',
      content: Text('确认删除 ${login.username} @ ${login.server}?'),
      confirmText: '确认',
      onConfirm: () => ref.read(savedLoginsProvider.notifier).remove(index),
    );
  }

  /// 通用添加/编辑 dialog:label + 三字段 + 标记编辑器。
  ///
  /// onSubmit 末两个参数:
  /// - mark: 编辑器输出的 AccountMark?(null 表示清空或未设)
  /// - clearMark: 用户在编辑器选「无」且原 mark 非空时为 true(用于区分「不改」与「清空」)
  void _showAccountDialog({
    required BuildContext context,
    required String title,
    required SavedLogin initial,
    required Future<void> Function(
      String server,
      String username,
      String password,
      String? label,
      AccountMark? mark,
      bool clearMark,
    ) onSubmit,
  }) {
    final serverCtrl = TextEditingController(text: initial.server);
    final usernameCtrl = TextEditingController(text: initial.username);
    final passwordCtrl = TextEditingController(text: initial.password);
    final labelCtrl = TextEditingController(text: initial.label ?? '');
    AccountMark? currentMark = initial.mark;
    bool clearMark = false;
    showAppDialog(
      context: context,
      title: title,
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const ValueKey('label_field'),
              controller: labelCtrl,
              decoration: const InputDecoration(
                  labelText: '备注名(可选)', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
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
            PasswordTextField(controller: passwordCtrl),
            const SizedBox(height: 16),
            AccountMarkEditor(
              initial: initial.mark,
              onChanged: (m) {
                currentMark = m;
                clearMark = (m == null && initial.mark != null);
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
        final labelRaw = labelCtrl.text.trim();
        if (s.isEmpty || u.isEmpty || p.isEmpty) {
          if (context.mounted) {
            showAppSnackBar(context, '请填写完整', type: SnackBarType.error);
          }
          return;
        }
        try {
          await onSubmit(s, u, p, labelRaw, currentMark, clearMark);
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
    // mark 色:有 mark 用 mark 颜色,否则主题色(同侧边栏方案 E 取色逻辑)
    final mark = login.mark != null
        ? AccountPalette.colorAt(login.mark!.colorIndex)
        : theme.colorScheme.primary;
    // 主标题:label 优先,无 label 回退 username(对齐侧边栏 accountCardTitle)
    final title = (login.label != null && login.label!.isNotEmpty)
        ? login.label!
        : (login.username.isNotEmpty ? login.username : login.server);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          gradient: selected
              ? LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    mark.withValues(alpha: 0.22),
                    mark.withValues(alpha: 0.06),
                  ],
                )
              : null,
          color: selected ? null : mark.withValues(alpha: 0.06),
          border: Border(
            left: BorderSide(
              width: selected ? 4 : 2,
              color: selected ? mark : mark.withValues(alpha: 0.5),
            ),
          ),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
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
                      color: selected
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
                        color: selected ? mark : null,
                        fontWeight: selected ? FontWeight.w600 : null,
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
                                selected ? FontWeight.w700 : FontWeight.w500,
                            color: const Color(0xFF111111),
                          ),
                        ),
                        const SizedBox(height: 1),
                        Text(
                          '${login.username} @ ${login.server}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF999999)),
                        ),
                      ],
                    ),
                  ),
                  if (selected)
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
      ),
    );
  }
}
