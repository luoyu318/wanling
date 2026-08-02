import 'package:flutter/material.dart';

import '../utils/snackbar.dart';
import 'feedback/app_dialog.dart';

/// 会话长按操作菜单（置顶/取消置顶 + 删除）。
///
/// 用 PageRouteBuilder(Duration.zero) 无动画弹出，全屏 GestureDetector 点空白关闭。
/// 菜单左上角对齐到 [globalPos]，带边界保护不溢出屏幕。
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
  final overlay = Navigator.of(context).overlay!;
  final overlayBox = overlay.context.findRenderObject() as RenderBox;
  final overlaySize = overlayBox.size;
  final local = overlayBox.globalToLocal(globalPos);

  const menuWidth = 140.0;
  const itemHeight = 48.0;
  final menuHeight = itemHeight * 2;

  final left = (local.dx + menuWidth > overlaySize.width - 8)
      ? overlaySize.width - menuWidth - 8
      : local.dx;
  final top = (local.dy + menuHeight > overlaySize.height - 8)
      ? overlaySize.height - menuHeight - 8
      : local.dy;

  final selected = await Navigator.of(context).push<String>(
    PageRouteBuilder<String>(
      opaque: false,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (ctx, _, _) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => Navigator.pop(ctx),
          child: Stack(
            children: [
              Positioned(
                left: left,
                top: top,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    width: menuWidth,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      boxShadow: const [
                        BoxShadow(
                          color: Color(0x26000000),
                          blurRadius: 12,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _menuItem(
                          label: isPinned ? '取消置顶' : '置顶',
                          color: const Color(0xFF111111),
                          onTap: () => Navigator.pop(ctx, 'pin'),
                        ),
                        _menuItem(
                          label: '删除会话',
                          color: const Color(0xFFFA5151),
                          onTap: () => Navigator.pop(ctx, 'hide'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    ),
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
    showAppDialog(
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

Widget _menuItem({
  required String label,
  required Color color,
  required VoidCallback onTap,
}) {
  return InkWell(
    onTap: onTap,
    child: Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      child: Text(label, style: TextStyle(color: color, fontSize: 14)),
    ),
  );
}
