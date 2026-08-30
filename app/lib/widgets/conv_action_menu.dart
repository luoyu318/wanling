import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:wanling_core/utils/snackbar.dart';
import 'app_action_menu.dart';
import 'feedback/app_dialog.dart';

/// 会话长按操作菜单（固定到底栏 + 置顶/取消置顶 + 删除）。
///
/// 复用通用 [showAppActionMenu]（白底圆角 + 菜单项 icon + 边缘 clamp），
/// 菜单左上角对齐到 [globalPos]。
///
/// 参数：
/// - [isPinned]：会话置顶状态（列表内排序）
/// - [isNavPinned]：是否已固定到底栏（含 conv 槽与 agent 槽两种形态,由调用方折算）
/// - [onPinToggle]/[onNavPinToggle]/[onHide]：对应动作回调
Future<void> showConvActionMenu(
  BuildContext context,
  Offset globalPos, {
  required bool isPinned,
  required bool isNavPinned,
  required Future<void> Function() onPinToggle,
  required Future<void> Function() onNavPinToggle,
  required Future<void> Function() onHide,
}) async {
  final selected = await showAppActionMenu(
    context,
    globalPos,
    items: [
      ActionMenuItem(
        value: 'nav',
        label: isNavPinned ? '从底栏移除' : '固定到底栏',
        icon: isNavPinned ? Icons.dock_outlined : Icons.dock,
      ),
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

  if (selected == 'nav') {
    unawaited(HapticFeedback.selectionClick());
    try {
      await onNavPinToggle();
    } catch (_) {
      if (context.mounted) {
        showAppSnackBar(context, '操作失败,请重试', type: SnackBarType.error);
      }
    }
  } else if (selected == 'pin') {
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
