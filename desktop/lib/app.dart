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
