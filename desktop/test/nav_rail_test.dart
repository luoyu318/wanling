// desktop/test/nav_rail_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/services/websocket_service.dart';
import 'package:wanling_core/utils/secure_storage.dart';
import 'package:wanling_desktop/shell/nav_rail.dart';
import 'package:go_router/go_router.dart';

/// 复用 shell_test 的空 savedLogins 种子模式。
class _EmptySavedLogins extends SavedLoginsNotifier {
  _EmptySavedLogins(SharedPreferences prefs)
    : super(
        prefs: prefs,
        storage: SecureStorage(deviceId: 'test'),
        onLogout: ({bool silent = false}) async {},
        onLogin: (u, p) async {},
        onSwitchingChange: (s) {},
      );
}

void main() {
  testWidgets('工具条渲染五类入口且无设置项', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        authProvider.overrideWith(
          (ref) => AuthNotifier(ApiService(baseUrl: '')),
        ),
        savedLoginsProvider.overrideWith((ref) => _EmptySavedLogins(prefs)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: GoRouter(
            // 显式初始路由:默认 '/' 不在路由表,不指定会落错误页致 NavRail 不渲染
            initialLocation: '/messages',
            routes: [
              ShellRoute(
                builder: (c, s, child) => Scaffold(body: Row(children: [NavRail(), Expanded(child: child)])),
                routes: [
                  GoRoute(path: '/messages', builder: (c, s) => const Scaffold(body: Text('messages'))),
                  GoRoute(path: '/wanling', builder: (c, s) => const Scaffold(body: Text('wanling'))),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('navrail_search')), findsOneWidget);
    expect(find.byKey(const ValueKey('navrail_new_chat')), findsOneWidget);
    expect(find.byKey(const ValueKey('navrail_messages')), findsOneWidget);
    expect(find.byKey(const ValueKey('navrail_wanling')), findsOneWidget);
    expect(find.byKey(const ValueKey('navrail_account')), findsOneWidget);
    // 设置项已移除(入口进标题栏)
    expect(find.byKey(const ValueKey('navrail_settings')), findsNothing);
    // 透明工具条:无背景色 Container
    final rail = tester.widget<Container>(find.byType(Container).first);
    expect(rail.color, isNull);
  });
}
