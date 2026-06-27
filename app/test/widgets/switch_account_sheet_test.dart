import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app/models/account_mark.dart';
import 'package:app/providers/saved_logins_provider.dart';
import 'package:app/utils/secure_storage.dart';
import 'package:app/widgets/switch_account_sheet.dart';

void main() {
  late ProviderContainer container;
  late SavedLoginsNotifier notifier;
  int logoutCalls = 0;
  List<String> loginCalls = [];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = SecureStorage(deviceId: 'test-device');
    logoutCalls = 0;
    loginCalls = [];
    notifier = SavedLoginsNotifier(
      prefs: prefs,
      storage: storage,
      onBaseUrlChange: (_) {},
      onLogout: ({bool silent = false}) async => logoutCalls++,
      onLogin: (u, p) async => loginCalls.add('$u:$p'),
      onSwitchingChange: (_) {},
    );
    await notifier.add('http://prod', 'uA', 'pA',
        label: '正式服', mark: const AccountMark(colorIndex: 3));
    await notifier.add('http://test', 'uB', 'pB', label: '测试服');
    notifier.select(0);
    container = ProviderContainer(
      overrides: [savedLoginsProvider.overrideWith((ref) => notifier)],
    );
  });

  Future<void> pumpSheet(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => showSwitchAccountSheet(ctx),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('渲染所有账号卡片与当前标记', (tester) async {
    await pumpSheet(tester);
    expect(find.text('正式服'), findsOneWidget);
    expect(find.text('测试服'), findsOneWidget);
    expect(find.text('uA @ http://prod'), findsOneWidget);
    expect(find.text('uB @ http://test'), findsOneWidget);
    // 当前选中项有「当前」标记
    expect(find.text('当前'), findsOneWidget);
  });

  testWidgets('点非当前卡片触发 switchTo', (tester) async {
    await pumpSheet(tester);
    await tester.tap(find.text('测试服'));
    await tester.pumpAndSettle();
    expect(logoutCalls, 1);
    expect(loginCalls, ['uB:pB']);
  });

  testWidgets('点当前卡片不触发切换', (tester) async {
    await pumpSheet(tester);
    await tester.tap(find.text('正式服'));
    await tester.pumpAndSettle();
    expect(logoutCalls, 0);
    expect(loginCalls, isEmpty);
  });

  testWidgets('切换中显示 loading 遮罩', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = SecureStorage(deviceId: 'test-device');
    final slowNotifier = SavedLoginsNotifier(
      prefs: prefs,
      storage: storage,
      onBaseUrlChange: (_) {},
      onLogout: ({bool silent = false}) async {},
      onLogin: (u, p) async {
        await Future.delayed(const Duration(milliseconds: 100));
      },
      onSwitchingChange: (_) {},
    );
    await slowNotifier.add('http://a', 'u1', 'p1');
    await slowNotifier.add('http://b', 'u2', 'p2');
    slowNotifier.select(0);
    final c = ProviderContainer(
      overrides: [savedLoginsProvider.overrideWith((ref) => slowNotifier)],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => showSwitchAccountSheet(ctx),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('http://b'));
    await tester.pump(); // 不 settle,看 loading
    expect(find.text('切换中…'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('切换失败显示错误提示', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final storage = SecureStorage(deviceId: 'test-device');
    final failNotifier = SavedLoginsNotifier(
      prefs: prefs,
      storage: storage,
      onBaseUrlChange: (_) {},
      onLogout: ({bool silent = false}) async {},
      onLogin: (u, p) async => throw Exception('密码错误'),
      onSwitchingChange: (_) {},
    );
    await failNotifier.add('http://a', 'u1', 'p1');
    await failNotifier.add('http://b', 'u2', 'p2');
    failNotifier.select(0);
    final c = ProviderContainer(
      overrides: [savedLoginsProvider.overrideWith((ref) => failNotifier)],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => ElevatedButton(
                onPressed: () => showSwitchAccountSheet(ctx),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('http://b'));
    await tester.pumpAndSettle();
    // SnackBar 显示错误(Exception 默认 toString 含「密码错误」)
    expect(find.textContaining('密码错误'), findsOneWidget);
  });
}
