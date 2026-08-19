import 'package:flutter/material.dart';

/// 桌面双套主题:浅色参照 core 紧凑浅色(白底/浅灰页面/深黑正文),
/// 深色自定(深灰 surface/更深背景/浅灰正文),主色均为品牌绿系。
/// 不指定 fontFamily,跟随系统。
class DesktopTheme {
  DesktopTheme._();

  /// 品牌绿(core accentGreen)
  static const Color _brandGreen = Color(0xFF07C160);

  /// 深色场景品牌绿(深底上略降饱和)
  static const Color _brandGreenDark = Color(0xFF4CAF6E);

  static final ThemeData light = ThemeData(
    useMaterial3: true,
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
}
