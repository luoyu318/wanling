import 'package:flutter/material.dart';

import 'package:app/widgets/mini_program_overlay.dart';

/// 统一风格的全局 Dialog helper。
///
/// 规格：圆角 12 / 标题 17/w500/#111111 / 内容 14/w300/#555555 /
/// 按钮：取消 TextButton(#999999) + 主操作 FilledButton(#07C160, 圆角 4)。
///
/// 用法：
/// ```dart
/// await showAppDialog(
///   context: context,
///   title: '确认删除',
///   content: Text('删除后无法恢复'),
///   confirmText: '删除',
///   onConfirm: () => doDelete(),
/// );
/// ```
///
/// [dismissOnConfirm]：默认 true（点主按钮立即关 dialog 再回调）。
/// 表单场景（校验失败 / 异常时需保留用户输入）传 false，由 onConfirm 自行控制关闭。
///
/// [embedded]=true：小程序嵌入模式专用。嵌入页面挂全局 Host 层，context 向上
/// 无 Navigator，showDialog 的 Navigator.of 必崩；改经宿主顶端专用 Overlay
/// 呈现（视觉规格与路由模式逐字一致）。路由模式行为不变。
Future<void> showAppDialog({
  required BuildContext context,
  required String title,
  required Widget content,
  String confirmText = '确定',
  String cancelText = '取消',
  VoidCallback? onConfirm,
  bool barrierDismissible = true,
  bool dismissOnConfirm = true,
  bool embedded = false,
}) async {
  if (embedded) {
    await showMiniProgramOverlay<void>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (ctx, close) => buildAppAlertDialog(
        title: title,
        content: content,
        confirmText: confirmText,
        cancelText: cancelText,
        onCancel: close,
        onConfirm: () {
          // 对齐路由模式 dismissOnConfirm 语义:先关弹层再回调
          if (dismissOnConfirm) close();
          onConfirm?.call();
        },
      ),
    );
    return;
  }
  await showDialog(
    context: context,
    barrierDismissible: barrierDismissible,
    builder: (ctx) => buildAppAlertDialog(
      title: title,
      content: content,
      confirmText: confirmText,
      cancelText: cancelText,
      onCancel: () => Navigator.pop(ctx),
      onConfirm: () {
        if (dismissOnConfirm) Navigator.pop(ctx);
        onConfirm?.call();
      },
    ),
  );
}

/// 统一风格 AlertDialog 视觉规格的唯一真相源,路由模式(showDialog)与小程序
/// 嵌入模式(showMiniProgramOverlay)共用;开合动作由调用方注入
/// ([onCancel]/[onConfirm] 各自绑定 Navigator.pop 或 Overlay close)。
Widget buildAppAlertDialog({
  required String title,
  required Widget content,
  String confirmText = '确定',
  String cancelText = '取消',
  required VoidCallback onCancel,
  required VoidCallback onConfirm,
}) {
  return AlertDialog(
    backgroundColor: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    ),
    titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
    contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
    actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    title: Text(
      title,
      style: const TextStyle(
        fontSize: 17,
        fontWeight: FontWeight.w500,
        color: Color(0xFF111111),
      ),
    ),
    content: DefaultTextStyle(
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w300,
        color: Color(0xFF555555),
        height: 1.5,
      ),
      child: content,
    ),
    actions: [
      TextButton(
        onPressed: onCancel,
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFF999999),
        ),
        child: Text(cancelText),
      ),
      FilledButton(
        onPressed: onConfirm,
        style: FilledButton.styleFrom(
          backgroundColor: const Color(0xFF07C160),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        child: Text(confirmText),
      ),
    ],
  );
}
