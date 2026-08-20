// desktop/test/settings_page_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/settings_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_desktop/pages/settings_page.dart';
import 'package:wanling_desktop/providers/desktop_notifications_provider.dart';

/// 已登录 auth 种子(user 供账号段显示)。api.logout stub 成空:
/// 登出确认测试点「退出」后会走 notifier.logout → api.logout,不能发网络。
class _LoggedInAuth extends AuthNotifier {
  _LoggedInAuth() : super(_NoopApi()) {
    state = AuthState(
      token: 'test-token',
      user: User(
        id: 'u1',
        username: 'alice',
        nickname: 'Alice',
        createdAt: DateTime(2026, 1, 1),
      ),
    );
  }
}

class _NoopApi extends ApiService {
  _NoopApi() : super(baseUrl: '');

  @override
  Future<void> logout() async {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'api_base_url': 'http://dev:18008',
    });
    // logout → TokenVault.clearAuth 走 flutter_secure_storage,mock 成内存实现。
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('设置页:服务器地址展示 + 弹窗修改写入 settingsProvider', (tester) async {
    final container = ProviderContainer(
      overrides: [authProvider.overrideWith((ref) => _LoggedInAuth())],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();

    // 只读展示当前地址。
    expect(find.text('http://dev:18008'), findsOneWidget);

    await tester.tap(find.text('服务器地址'));
    await tester.pumpAndSettle();

    // 弹窗 TextField 预填当前地址,输入新地址保存。
    expect(find.byType(TextField), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'http://new:9000');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(container.read(settingsProvider), 'http://new:9000');
    expect(find.text('http://new:9000'), findsOneWidget);
  });

  testWidgets('设置页:退出登录需确认,确认后 auth 置未登录', (tester) async {
    final container = ProviderContainer(
      overrides: [authProvider.overrideWith((ref) => _LoggedInAuth())],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(container.read(authProvider).isAuthenticated, isTrue);

    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();

    // 确认对话框弹出,未确认前不登出。
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(container.read(authProvider).isAuthenticated, isTrue);

    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();

    expect(container.read(authProvider).isAuthenticated, isFalse);
  });

  testWidgets('设置页:通知开关切换并持久化', (tester) async {
    final container = ProviderContainer(
      overrides: [authProvider.overrideWith((ref) => _LoggedInAuth())],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(container.read(desktopNotificationsProvider), isTrue);
    expect(
      (tester.widget(find.byKey(const ValueKey('notif_switch'))) as SwitchListTile)
          .value,
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey('notif_switch')));
    await tester.pumpAndSettle();

    expect(container.read(desktopNotificationsProvider), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('desktop.notifications_enabled'), isFalse);
  });

  testWidgets('设置页:关于段渲染', (tester) async {
    final container = ProviderContainer(
      overrides: [authProvider.overrideWith((ref) => _LoggedInAuth())],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();

    // 关于段在列表底部,滚到可见。
    await tester.scrollUntilVisible(find.text('关于'), 200);
    await tester.pumpAndSettle();

    expect(find.text('关于'), findsOneWidget);
    expect(find.text('万灵 Wanling'), findsOneWidget);
    expect(find.text('版本 1.5.0'), findsOneWidget);
  });
}
