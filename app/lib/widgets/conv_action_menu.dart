import 'package:flutter/material.dart';

import 'package:wanling_core/utils/snackbar.dart';
import 'app_action_menu.dart';
import 'feedback/app_dialog.dart';

/// 会话长按操作菜单（置顶/取消置顶 + 删除）。
///
/// 复用通用 [showAppActionMenu]（白底圆角 + 菜单项 icon + 边缘 clamp），
/// 菜单左上角对齐到 [globalPos]。
///
/// 参数：
/// - [isPinned]：当前置顶状态，决定菜单显示「置顶」还是「取消置顶」
/// - [onPinToggle]：用户点击置顶/取消置顶时的回调
/// - [onHide]：用户点击删除时的回调（删除确认 dialog 由本函数内部处理）
Future<void> showConvActionMenu(
  BuildContext context,
  Offset globalPos, {
  required bool isPinned,
  required Future<void> Function() onPinToggle,
  required Future<void> Function() onHide,
}) async {
  final selected = await showAppActionMenu(
    context,
    globalPos,
    items: [
      ActionMenuItem(
        value: 'pin',
        label: isPinned ? '取消置顶' : '置顶',
        icon: isPinned ? Icons.vertical_align_top : Icons.push_pin_outlined,
      ),
      const ActionMenuItem(
        value: 'hide',
        label: '删除会话',
        icon: Icons.delete_outline,
        color: Color(0xFFFA5151),
      ),
    ],
  );

  if (selected == null) return;
  if (!context.mounted) return;

  if (selected == 'pin') {
    try {
      await onPinToggle();
    } catch (_) {
      if (context.mounted) {
        showAppSnackBar(context, '操作失败,请重试', type: SnackBarType.error);
      }
    }
  } else if (selected == 'hide') {
    await showAppDialog(
      context: context,
      title: '确认删除该会话?',
      content: const Text('聊天记录将保留,有新消息时会话自动恢复。'),
      confirmText: '删除',
      onConfirm: () async {
        try {
          await onHide();
        } catch (_) {
          if (context.mounted) {
            showAppSnackBar(context, '删除失败,请重试', type: SnackBarType.error);
          }
        }
      },
    );
  }
}
