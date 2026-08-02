import 'package:flutter/material.dart';

/// 账号标记固定调色板(8 色)。
///
/// AccountMark.colorIndex 索引此数组。存索引而非 Color 值,
/// 序列化稳定 + 便于将来换肤。
class AccountPalette {
  const AccountPalette._();

  static const List<Color> colors = [
    Color(0xFFFA5151), // 红
    Color(0xFFFF9500), // 橙
    Color(0xFFFFCC00), // 黄
    Color(0xFF34C759), // 绿
    Color(0xFF00C7BE), // 青
    Color(0xFF007AFF), // 蓝
    Color(0xFF5856D6), // 紫
    Color(0xFF8E8E93), // 灰
  ];

  /// 安全取色:越界回退到末色(灰),避免 UI 崩溃。
  static Color colorAt(int index) {
    if (index < 0 || index >= colors.length) return colors.last;
    return colors[index];
  }
}
