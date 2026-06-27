import 'package:app/pages/login_page.dart';
import 'package:app/pages/select_account_page.dart';
import 'package:app/providers/saved_logins_provider.dart';
import 'package:app/providers/settings_provider.dart';
import 'package:app/utils/secure_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late ProviderContainer container;
  late SavedLoginsNotifier savedLoginsNotifier;
  late SettingsNotifier settingsNotifier;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = SecureStorage(deviceId: 'test-device');
    settingsNotifier = SettingsNotifier();
    savedLoginsNotifier = SavedLoginsNotifier(
      prefs: prefs,
      storage: storage,
      onBaseUrlChange: (url) => settingsNotifier.setBaseUrl(url),
    );
    container = ProviderContainer(
      overrides: [
        savedLoginsProvider.overrideWith((ref) => savedLoginsNotifier),
        settingsProvider.overrideWith((ref) => settingsNotifier),
      ],
    );
  });

  Future<void> pumpPage(WidgetTester tester) async {
    // 用 router（含 / 和 /select-account）：LoginPage 内部走 context.push，
    // 必须有 GoRouter 在树上才能找到，否则抛异常。
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (_, __) => const LoginPage()),
        GoRoute(
            path: '/select-account',
            builder: (_, __) => const SelectAccountPage()),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: router),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('零记录时:无「切换」按钮', (tester) async {
    await pumpPage(tester);
    expect(find.textContaining('切换'), findsNothing);
  });

  testWidgets('有记录:显示「切换」按钮', (tester) async {
    await savedLoginsNotifier.add('http://x', 'u', 'p');
    await pumpPage(tester);
    expect(find.textContaining('切换'), findsOneWidget);
  });

  testWidgets('选中后表单预填 server/username/password', (tester) async {
    await savedLoginsNotifier.add('http://x', 'u', 'p');
    savedLoginsNotifier.select(0);
    await pumpPage(tester);
    // 找到三个 TextField,第一个(server)应含 http://x
    final fields = find.byType(TextField);
    expect(fields, findsNWidgets(3));
    expect((tester.widget(fields.at(0)) as TextField).controller?.text,
        'http://x');
    expect((tester.widget(fields.at(1)) as TextField).controller?.text, 'u');
    expect((tester.widget(fields.at(2)) as TextField).controller?.text, 'p');
  });

  testWidgets('登录按钮文案:选中态显示「点此登录」', (tester) async {
    await savedLoginsNotifier.add('http://x', 'u', 'p');
    savedLoginsNotifier.select(0);
    await pumpPage(tester);
    expect(find.text('点此登录'), findsOneWidget);
  });

  testWidgets('登录按钮文案:未选中显示「登录」', (tester) async {
    await pumpPage(tester);
    expect(find.text('登录'), findsAtLeast(1));
  });

  testWidgets('点「切换」跳到 SelectAccountPage', (tester) async {
    await savedLoginsNotifier.add('http://x', 'u', 'p');
    await pumpPage(tester);
    await tester.tap(find.textContaining('切换'));
    await tester.pumpAndSettle();
    expect(find.text('选择账号'), findsOneWidget);
  });
}
