import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:wanling_core/providers/settings_provider.dart';
import 'package:wanling_core/services/notification_service.dart';
import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 桌面通知初始化(Windows/Linux settings 由 core notification_service 处理)
  await NotificationService.instance.init();
  // 注入已 load 的 SharedPreferences(savedLogins 依赖同步实例),
  // 再按 app 壳同序恢复:settings → savedLogins → 登录态。
  // restoreSession 完成后才 runApp,首帧即最终登录态,无 /login 闪现。
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
  );
  await container.read(settingsProvider.notifier).load();
  await container.read(savedLoginsProvider.notifier).load();
  await container.read(authProvider.notifier).restoreSession();
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const WanlingDesktopApp(),
    ),
  );
}
