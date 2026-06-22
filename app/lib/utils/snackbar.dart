import 'package:flutter/material.dart';

/// SnackBar 类型，决定背景色。
enum SnackBarType {
  info, // 灰色（默认）
  success, // 绿色
  error, // 红色
}

/// 全局统一的 SnackBar 工具。
///
/// 用法：
///   showAppSnackBar(context, '保存成功', type: SnackBarType.success);
///   showAppSnackBar(context, '网络错误');
///
/// 行为统一：
///   - 时长 2 秒
///   - 文字白色
///   - 背景色按 type 区分
void showAppSnackBar(
  BuildContext context,
  String message, {
  SnackBarType type = SnackBarType.info,
}) {
  final color = switch (type) {
    SnackBarType.info => const Color(0xFF666666),
    SnackBarType.success => const Color(0xFF07C160),
    SnackBarType.error => const Color(0xFFFA5151),
  };
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message),
      backgroundColor: color,
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
