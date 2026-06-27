import 'package:flutter/material.dart';

import '../widgets/feedback/app_snackbar.dart' as new_impl;

/// SnackBar 类型，保留枚举以维持 API 兼容。
///
/// 注意：当前 AppSnackBar 实现（OverlayEntry 版本）统一深色胶囊样式，
/// type 字段暂未影响渲染（保留参数避免调用方改动）。
enum SnackBarType {
  info, // 默认
  success, // 成功
  error, // 错误
}

/// 全局统一的 SnackBar 工具（转发到 lib/widgets/feedback/app_snackbar.dart）。
///
/// 用法：
///   showAppSnackBar(context, '保存成功', type: SnackBarType.success);
///   showAppSnackBar(context, '网络错误');
///
/// 行为统一：
///   - 时长 2 秒
///   - 文字白色
///   - 贴 MessageInputBar 上方显示（无输入栏时贴底）
void showAppSnackBar(
  BuildContext context,
  String message, {
  SnackBarType type = SnackBarType.info,
}) {
  new_impl.showAppSnackBar(context, message, type: type);
}
