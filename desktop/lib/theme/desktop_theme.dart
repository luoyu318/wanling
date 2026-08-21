import 'dart:io' show Platform;

import 'package:flutter/material.dart';

/// 桌面双套主题:浅色参照 core 紧凑浅色(白底/浅灰页面/深黑正文),
/// 深色自定(深灰 surface/更深背景/浅灰正文),主色均为品牌绿系。
///
/// fontFamily:Flutter 引擎默认请求 Roboto,Windows 无此字体,中文经
/// DirectWrite 兜底落到宋体(观感怪异的根因)。Windows 显式指定系统
/// UI 字体 Microsoft YaHei UI;Linux/macOS 保持 null 走各自正常兜底。
class DesktopTheme {
  DesktopTheme._();

  /// Windows 系统 UI 字体,其余平台 null(跟随引擎兜底)。
  static final String? uiFontFamily =
      Platform.isWindows ? 'Microsoft YaHei UI' : null;

  /// 品牌绿(core accentGreen)
  static const Color _brandGreen = Color(0xFF07C160);

  /// 深色场景品牌绿(深底上略降饱和)
  static const Color _brandGreenDark = Color(0xFF4CAF6E);

  static final ThemeData light = ThemeData(
    useMaterial3: true,
    fontFamily: uiFontFamily,
    colorScheme: const ColorScheme(
      brightness: Brightness.light,
      primary: _brandGreen,
      onPrimary: Colors.white,
      secondary: _brandGreen,
      onSecondary: Colors.white,
      error: Color(0xFFFA5151),
      onError: Colors.white,
      surface: Color(0xFFFFFFFF),
      onSurface: Color(0xFF111111),
      surfaceContainerHighest: Color(0xFFEDEDED),
    ),
    scaffoldBackgroundColor: const Color(0xFFEDEDED),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFFFFFFFF),
      foregroundColor: Color(0xFF111111),
      elevation: 0,
    ),
    dividerTheme: const DividerThemeData(color: Color(0xFFE4E4E4)),
    splashFactory: NoSplash.splashFactory,
  );

  static final ThemeData dark = ThemeData(
    useMaterial3: true,
    fontFamily: uiFontFamily,
    colorScheme: const ColorScheme(
      brightness: Brightness.dark,
      primary: _brandGreenDark,
      onPrimary: Color(0xFF17181C),
      secondary: _brandGreenDark,
      onSecondary: Color(0xFF17181C),
      error: Color(0xFFFA5151),
      onError: Colors.white,
      surface: Color(0xFF1E1F24),
      onSurface: Color(0xFFE8E8E8),
      surfaceContainerHighest: Color(0xFF26272D),
    ),
    scaffoldBackgroundColor: const Color(0xFF17181C),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF1E1F24),
      foregroundColor: Color(0xFFE8E8E8),
      elevation: 0,
    ),
    dividerTheme: const DividerThemeData(color: Color(0xFF2E2F36)),
    splashFactory: NoSplash.splashFactory,
  );

  /// —— 浮动卡片布局 token(spec §4) ——
  /// 窗口画布底色(无边框后整窗背景,卡片缝隙/边距露出)。
  static Color canvasColor(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF101014) : const Color(0xFFE9EAEC);

  /// 卡片底色(会话列表/聊天区两张卡片;深色下聊天区略深一档见 spec)。
  static Color cardColor(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF1A1A20) : const Color(0xFFFFFFFF);

  /// 聊天区卡片底色(深色下比会话卡片深 3 位形成层次,浅色比纯白
  /// 降一档 FCFCFC,与画布/左卡片拉开微妙层次)。
  static Color chatCardColor(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF17171D) : const Color(0xFFFCFCFC);

  /// 卡片边框/画布上细分割线。
  static Color cardBorderColor(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF2E2E38) : const Color(0xFFDCDCDC);
}
