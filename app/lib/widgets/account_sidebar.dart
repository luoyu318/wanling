import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:wanling_core/models/account_mark.dart';
import 'package:wanling_core/models/saved_login.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:wanling_core/theme/app_colors.dart';
import 'package:wanling_core/utils/snackbar.dart';
import '../utils/dio_error.dart';
import 'account_mark_editor.dart';
import 'app_action_menu.dart';
import 'avatar.dart';
import 'feedback/app_dialog.dart';
import 'password_text_field.dart';
import 'sidebar_profile_panel.dart';

/// 账号卡片主标题：备注 > 昵称 > 账号名。
String accountCardTitle(SavedLogin login) {
  if (login.label != null && login.label!.isNotEmpty) return login.label!;
  if (login.username.isNotEmpty) return login.username;
  return login.server;
}

/// 左侧侧滑面板：AppBar 头像触发，迁移自旧「切换账号」底部弹层。
/// 双层结构：左竖条(88px 账号切换) + 右主面板(SidebarProfilePanel 承接原我的页菜单)。
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
    ref
        .read(savedLoginsProvider.notifier)
        .duplicate(index)
        .then((_) {
          if (mounted) {
            showAppSnackBar(
              context,
              '已复制,可长按头像编辑新账号',
              type: SnackBarType.success,
            );
          }
        })
        .catchError((e) {
          if (mounted) {
            showAppSnackBar(context, e.toString(), type: SnackBarType.error);
          }
        });
  }

  /// 长按账号头像弹动作菜单(原 ⋯ 菜单三项:编辑/复制/删除)。
  Future<void> _showAccountActions(
    int index,
    SavedLogin login,
    Offset pos,
  ) async {
    final selected = await showAppActionMenu(
      context,
      pos,
      items: const [
        ActionMenuItem(value: 'edit', label: '编辑', icon: Icons.edit_outlined),
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
      _showEditDialog(login, index);
    } else if (selected == 'duplicate') {
      _duplicate(index);
    } else if (selected == 'delete') {
      _showDeleteConfirm(index, login);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(savedLoginsProvider);
    final width = MediaQuery.of(context).size.width * 0.85;

    return SizedBox(
      width: width,
      child: Stack(
        children: [
          // 垫底白色:竖条 88dp 在非整数 dpr 下宽度非整数物理像素,接缝列
          // 亚像素混合会透出下层灰底形成断续"边框线",垫白后混合结果恒为白
          const Positioned.fill(
            child: ColoredBox(color: Colors.white),
          ),
          // stretch:主面板与竖条同撑满全高,否则面板按内容高度垂直居中成浮动卡片
          Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // —— 左竖条:账号切换(88px) ——
              _buildAccountStrip(state),
              // —— 主面板 ——
              Expanded(
                child: Container(
                  color: Colors.white,
                  child: const SafeArea(child: SidebarProfilePanel()),
                ),
              ),
            ],
          ),
          // 切换中遮罩(防抖 + 用户感知,覆盖整个双层面板含状态栏区域)
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

  /// 左竖条:全部账号头像(当前绿框高亮),点按切换,长按弹编辑/复制/删除菜单,
  /// 底部「+」添加服务器。切换中遮罩沿用原实现(覆盖整个双层面板)。
  Widget _buildAccountStrip(SavedLoginsState state) {
    return Container(
      width: 88,
      // 纯白与主面板同色:消除 F7F7F7|白 的色差分界(用户要求无线)
      color: Colors.white,
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 12),
            // 账号多时竖条内部滚动,「添加」按钮保持钉底
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var i = 0; i < state.logins.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: GestureDetector(
                          // 当前项禁用点按(对齐原账号卡片):switchTo 对同索引是 no-op,
                          // 但 _switchTo 仍会回调 onClose/弹成功 snackbar,必须在此挡掉
                          onTap: i == state.selectedIndex
                              ? null
                              : () => _switchTo(i),
                          onLongPressStart: (d) => _showAccountActions(
                            i,
                            state.logins[i],
                            d.globalPosition,
                          ),
                          child: _stripAvatar(state, i),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            // 底部「添加」:对齐主流 IM 竖排样式(圆角方块 + 号居中,文字下方),
            // 88px 竖条内 OutlinedButton.icon 横向放不下会把文字挤成竖排换行
            InkWell(
              onTap: _showAddDialog,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppColors.divider),
                    ),
                    child: const Icon(
                      Icons.add,
                      size: 26,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '添加',
                    maxLines: 1,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  /// 竖条账号项:头像 + 名字,当前项绿框高亮。
  Widget _stripAvatar(SavedLoginsState state, int i) {
    final login = state.logins[i];
    final isCurrent = i == state.selectedIndex;
    final title = accountCardTitle(login);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              width: 2,
              color: isCurrent ? AppColors.accentGreen : Colors.transparent,
            ),
          ),
          child: Avatar(name: title, size: 44, radius: 8),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 76,
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 11,
              color: isCurrent
                  ? AppColors.textPrimary
                  : AppColors.textSecondary,
              fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }
}
