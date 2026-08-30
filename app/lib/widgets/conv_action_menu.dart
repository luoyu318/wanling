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
/// - [showNavAction]：是否展示「固定到底栏」项。agent_session 会话
///   （multi_session agent 的二级 session）结构性不在一级消息列表,固定槽
///   无法渲染,二级页传 false 隐藏该入口
/// - [isNavPinned]：是否已固定到底栏（含 conv 槽与 agent 槽两种形态,由调用方
///   折算）,仅 [showNavAction] 为 true 时生效
/// - [onPinToggle]/[onNavPinToggle]/[onHide]：对应动作回调；
///   [onNavPinToggle] 仅 [showNavAction] 为 true 时必须提供
Future<void> showConvActionMenu(
  BuildContext context,
  Offset globalPos, {
  required bool isPinned,
  required Future<void> Function() onPinToggle,
  required Future<void> Function() onHide,
  bool showNavAction = true,
  bool isNavPinned = false,
  Future<void> Function()? onNavPinToggle,
}) async {
  assert(
    !showNavAction || onNavPinToggle != null,
    'showNavAction=true 时必须提供 onNavPinToggle',
  );
  final selected = await showAppActionMenu(
    context,
    globalPos,
    items: [
      if (showNavAction)
        ActionMenuItem(
          value: 'nav',
          label: isNavPinned ? '从底栏移除' : '固定到底栏',
          icon: isNavPinned ? Icons.dock_outlined : Icons.dock,
        ),
      ActionMenuItem(
        value: 'pin',
        label: isPinned ? '取消置顶' : '置顶',
        icon: Icons.vertical_align_top,
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
      await onNavPinToggle?.call();
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
    await confirmHideConversation(context, onHide);
  }
}

/// 「删除会话」确认框(长按菜单与左滑按钮共用)。
/// 聊天记录保留,有新消息时会话自动恢复(hide 语义)。
Future<void> confirmHideConversation(
  BuildContext context,
  Future<void> Function() onHide,
) async {
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
