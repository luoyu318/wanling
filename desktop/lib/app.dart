import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'providers/theme_mode_provider.dart';
import 'router.dart';
import 'theme/desktop_theme.dart';

class WanlingDesktopApp extends ConsumerWidget {
  const WanlingDesktopApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    // watch routerProvider:登录态变化 → router 重建 → redirect 重判(app 壳同模式)
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: '万灵',
      debugShowCheckedModeBanner: false,
      theme: DesktopTheme.light,
      darkTheme: DesktopTheme.dark,
      themeMode: mode,
      routerConfig: router,
    );
  }
}
