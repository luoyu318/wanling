// 首页左侧切换账号面板测试：验证 AppBar 头像触发打开、遮罩/返回键关闭。
//
// Mock 策略同 test/e2e/navigation_test.dart：
// - apiProvider：MockApi stub getMe/getAgents/getConversations
// - wsProvider：FakeWS 避免真实 WS 连接
// - SharedPreferences + SecureStorage：模拟 token 持久化
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:app/router.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:app/widgets/account_sidebar.dart';
import 'package:app/widgets/avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

final _testUser = User(
  id: 'u1',
  username: 'kira',
  avatarUrl: null,
  createdAt: DateTime.utc(2026, 6, 13),
);

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    // restoreSession 从 prefs 读 token 判已登录;不 set 会挂起(getInstance 永不完成)。
    SharedPreferences.setMockInitialValues({'token': 'fake-token'});
  });

  void stubBaseUrl(MockApi api) {
    when(() => api.baseUrl).thenReturn('http://test.local');
  }

  Future<ProviderContainer> buildContainer() async {
    final api = MockApi();
    stubBaseUrl(api);
    when(() => api.getMe()).thenAnswer((_) async => _testUser);
    when(() => api.getConversations()).thenAnswer((_) async => []);
    when(() => api.getAgents()).thenAnswer((_) async => []);
    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(FakeWS()),
      sharedPrefsProvider
          .overrideWithValue(await SharedPreferences.getInstance()),
    ]);
    addTearDown(container.dispose);
    await container.read(authProvider.notifier).restoreSession();
    return container;
  }

  /// 限定在 AppBar 内的头像（面板头部也有一个 52px Avatar，不能按 .first 找）。
  Finder appBarAvatar() => find.descendant(
      of: find.byType(AppBar), matching: find.byType(Avatar));

  testWidgets('点 AppBar 头像弹出侧边栏,点遮罩关闭', (tester) async {
    final container = await buildContainer();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: Consumer(builder: (_, ref, _) {
        return MaterialApp.router(routerConfig: ref.watch(routerProvider));
      }),
    ));
    await tester.pumpAndSettle();

    // 面板常驻挂载但 IgnorePointer(ignoring:true) 不可命中 → 初始为关闭态
    expect(find.byType(AccountSidebar).hitTestable(), findsNothing);

    // 点 AppBar 头像 → 打开
    await tester.tap(appBarAvatar());
    await tester.pumpAndSettle();
    expect(find.byType(AccountSidebar).hitTestable(), findsOneWidget);

    // 点遮罩关闭:面板宽 85%(默认测试面 800px→680px),点右侧空白处落在遮罩上
    await tester.tapAt(const Offset(700, 400));
    await tester.pumpAndSettle();
    expect(find.byType(AccountSidebar).hitTestable(), findsNothing);

    // 可再点开 → 确认面板确实重新进入可交互态
    await tester.tap(appBarAvatar());
    await tester.pumpAndSettle();
    expect(find.byType(AccountSidebar).hitTestable(), findsOneWidget);
  });

  testWidgets('系统返回键关闭面板而非退出', (tester) async {
    final container = await buildContainer();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: Consumer(builder: (_, ref, _) {
        return MaterialApp.router(routerConfig: ref.watch(routerProvider));
      }),
    ));
    await tester.pumpAndSettle();

    await tester.tap(appBarAvatar());
    await tester.pumpAndSettle();
    expect(find.byType(AccountSidebar).hitTestable(), findsOneWidget);

    // 模拟系统返回键：WidgetsBinding.handlePopRoute 走 observer.didPopRoute →
    // PopScope(canPop:false) → 不退出路由，只关面板
    await WidgetsBinding.instance.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(AccountSidebar).hitTestable(), findsNothing);

    // 面板关闭后仍可再点开 → 说明 App 未退出
    await tester.tap(appBarAvatar());
    await tester.pumpAndSettle();
    expect(find.byType(AccountSidebar).hitTestable(), findsOneWidget);
  });
}
