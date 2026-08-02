import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/account_mark.dart';
import '../models/saved_login.dart';
import '../providers/saved_logins_provider.dart';
import '../theme/account_palette.dart';
import '../utils/dio_error.dart';
import '../utils/snackbar.dart';
import 'account_mark_editor.dart';
import 'feedback/app_dialog.dart';
import 'password_text_field.dart';

/// 登录后切换账号:弹出底部 sheet,点卡片一键静默切换。
/// 当前选中项仅展示,不可点;其他项点击触发 switchTo。
Future<void> showSwitchAccountSheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
    ),
    builder: (_) => const SwitchAccountSheet(),
  );
}

class SwitchAccountSheet extends ConsumerStatefulWidget {
  const SwitchAccountSheet({super.key});

  @override
  ConsumerState<SwitchAccountSheet> createState() => _SwitchAccountSheetState();
}

class _SwitchAccountSheetState extends ConsumerState<SwitchAccountSheet> {
  bool _switching = false;

  Future<void> _switchTo(int index) async {
    if (_switching) return; // 防抖
    setState(() => _switching = true);
    try {
      await ref.read(savedLoginsProvider.notifier).switchTo(index);
      if (mounted) Navigator.of(context).pop(); // 成功:关闭弹层,UI 自然跳会话页
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, extractDioErrorMessage(e),
            type: SnackBarType.error);
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
              key: const ValueKey('sheet_label_field'),
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
        final labelRaw = labelCtrl.text.trim();
        if (s.isEmpty || u.isEmpty || p.isEmpty) {
          if (context.mounted) {
            showAppSnackBar(context, '请填写完整', type: SnackBarType.error);
          }
          return;
        }
        try {
          await ref.read(savedLoginsProvider.notifier).edit(
                index,
                server: s,
                username: u,
                password: p,
                label: labelRaw,
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

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(savedLoginsProvider);
    return Stack(
      children: [
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 标题栏
                Row(
                  children: [
                    const Text('切换账号',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w500)),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => Navigator.of(context).pop(),
                      child: const Icon(Icons.close, size: 22),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: state.logins.length,
                    itemBuilder: (_, i) => _AccountCard(
                      login: state.logins[i],
                      isCurrent: i == state.selectedIndex,
                      onTap: () => _switchTo(i),
                      onEdit: () => _showEditDialog(state.logins[i], i),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        // 切换中遮罩(防抖 + 用户感知)
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
                  Text('切换中…',
                      style: TextStyle(color: Colors.white, fontSize: 13)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 切换弹层内的账号卡片。
/// label 优先作主标题,无 label 回退 server;server 始终作副标题。
/// 有 mark 时左侧 4px 竖条用 mark 颜色,有 emoji 作 leading icon。
class _AccountCard extends StatelessWidget {
  final SavedLogin login;
  final bool isCurrent;
  final VoidCallback onTap;
  final VoidCallback onEdit;

  const _AccountCard({
    required this.login,
    required this.isCurrent,
    required this.onTap,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stripeColor = login.mark != null
        ? AccountPalette.colorAt(login.mark!.colorIndex)
        : theme.colorScheme.primary;
    final title = (login.label != null && login.label!.isNotEmpty)
        ? login.label!
        : login.server;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: isCurrent
            ? theme.colorScheme.primaryContainer
            : const Color(0xFFF5F5F5),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: isCurrent ? null : onTap,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(width: 4, color: stripeColor),
              ),
            ),
            child: Row(
              children: [
                if (login.mark?.emoji != null) ...[
                  Text(login.mark!.emoji!,
                      style: const TextStyle(fontSize: 18)),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                              fontSize: 14, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 2),
                      Text('${login.username} @ ${login.server}',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF999999))),
                    ],
                  ),
                ),
                if (isCurrent)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Text('当前',
                        style: TextStyle(
                            fontSize: 11, color: Color(0xFF999999))),
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.more_horiz, size: 20),
                    onPressed: onEdit,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
