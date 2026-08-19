import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 主题空壳:Task 2 实现桌面完整主题,先保证编译通过。
class DesktopTheme {
  static final ThemeData light = ThemeData.light();
  static final ThemeData dark = ThemeData.dark();
}

/// 主题模式 provider 空壳(Task 2 接入 settings 持久化)。
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);
