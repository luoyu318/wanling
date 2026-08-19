// desktop/test/theme_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_desktop/pages/settings_page.dart';
import 'package:wanling_desktop/providers/theme_mode_provider.dart';

void main() {
  testWidgets('themeModeProvider 默认 light,持久化切换到 dark 后重建仍是 dark', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    var container = ProviderContainer();
    expect(container.read(themeModeProvider), ThemeMode.light);

    await container.read(themeModeProvider.notifier).setMode(ThemeMode.dark);
    container.dispose();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('desktop.theme_mode'), 'dark');

    container = ProviderContainer();
    container.read(themeModeProvider.notifier); // 触发懒构造,否则恢复任务不会启动
    // 异步恢复:等待一帧微任务
    await tester.pump(const Duration(milliseconds: 10));
    expect(container.read(themeModeProvider), ThemeMode.dark);
    container.dispose();
  });

  testWidgets('设置页 RadioListTile 切深色:provider 状态与持久化同步变化', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsPage()),
      ),
    );

    expect(find.text('浅色'), findsOneWidget);
    expect(find.text('深色'), findsOneWidget);
    expect(find.text('跟随系统'), findsOneWidget);
    expect(container.read(themeModeProvider), ThemeMode.light);

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();

    expect(container.read(themeModeProvider), ThemeMode.dark);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('desktop.theme_mode'), 'dark');
    container.dispose();
  });
}
