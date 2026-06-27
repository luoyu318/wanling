import 'package:flutter/material.dart';

/// 深色菜单统一色板 token。
///
/// 给 MessageContextMenu（消息级锚钉菜单）和 AppTextSelectionToolbar
/// （文字级系统菜单）共用，保证两套深色菜单视觉一致。
///
/// 历史背景：MessageContextMenu 早期用 `Color(0xE8262626)` 内联硬编码；
/// 本次抽象把色值集中到此处，未来调色只改一处。
class AppMenuStyle {
  AppMenuStyle._(); // 仅静态常量

  // —— 深色菜单统一色板 ——
  /// 背景：90% 黑透（半透能让用户感知菜单悬浮在内容之上）
  static const Color darkBg = Color(0xE6262626);

  /// 前景文字 / icon 色
  static const Color darkFg = Colors.white;

  /// 危险操作色（删除按钮）
  static const Color darkDanger = Color(0xFFFF5B5B);

  /// 项之间分隔线（12% 白）
  static const Color darkDivider = Color(0x1FFFFFFF);

  // —— 阴影 ——
  static const BoxShadow shadow = BoxShadow(
    color: Color(0x66000000),
    blurRadius: 20,
    offset: Offset(0, 6),
  );

  // —— 圆角（按菜单类型不强统一）——
  /// MessageContextMenu 用（贴气泡，紧凑）
  static const double radiusAnchor = 4;

  /// AppTextSelectionToolbar 用（系统式，圆润）
  static const double radiusFloating = 8;
}
