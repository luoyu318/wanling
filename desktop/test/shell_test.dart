// desktop/test/shell_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/conversation_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/services/noop_local_message_store.dart';
import 'package:wanling_core/services/websocket_service.dart';
import 'package:wanling_core/utils/secure_storage.dart';
import 'package:wanling_desktop/pages/login_page.dart';
import 'package:wanling_desktop/pages/messages_page.dart';
import 'package:wanling_desktop/router.dart';
import 'package:wanling_desktop/shell/nav_rail.dart';

/// 已登录 auth 种子:token 直灌(镜像 Task 3 种子模式,无副作用)。
class _LoggedInAuth extends AuthNotifier {
  _LoggedInAuth() : super(ApiService(baseUrl: '')) {
    state = AuthState(token: 'test-token');
  }
}

/// 空会话种子:autoload=false 跳过 load/WS,防测试发网络。
class _EmptyConvNotifier extends ConversationListNotifier {
  _EmptyConvNotifier()
    : super(
        ApiService(baseUrl: ''),
        WebSocketService(),
        'test-user',
        NoopLocalMessageStore(),
        autoload: false,
      );
}

/// 空 savedLogins 种子:登录页 watch 它,不 override 会拉 SharedPreferences 链。
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

Future<ProviderContainer> _container({required AuthNotifier auth}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [
      authProvider.overrideWith((ref) => auth),
      conversationProvider.overrideWith((ref) => _EmptyConvNotifier()),
      savedLoginsProvider.overrideWith((ref) => _EmptySavedLogins(prefs)),
    ],
  );
}

void main() {
  testWidgets('路由守卫:未登录访问受保护路由重定向 /login', (tester) async {
    final container = await _container(
      auth: AuthNotifier(ApiService(baseUrl: '')),
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: container.read(routerProvider)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(DesktopLoginPage), findsOneWidget);
    expect(find.byType(MessagesPage), findsNothing);
    expect(find.byType(NavRail), findsNothing); // 无移动式导航
  });

  testWidgets('路由守卫:已登录进入 shell + 左侧导航', (tester) async {
    final container = await _container(auth: _LoggedInAuth());
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: container.read(routerProvider)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MessagesPage), findsOneWidget); // 进入消息页
    expect(find.byType(NavRail), findsOneWidget); // shell 左导航渲染
    expect(find.byType(DesktopLoginPage), findsNothing);
  });
}
