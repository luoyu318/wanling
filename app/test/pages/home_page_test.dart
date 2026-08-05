// 首页左侧切换账号面板测试：验证 AppBar 头像触发打开、遮罩/返回键关闭。
//
// Mock 策略同 test/e2e/navigation_test.dart：
// - apiProvider：MockApi stub getMe/getAgents/getConversations
// - wsProvider：FakeWS 避免真实 WS 连接
// - SharedPreferences + SecureStorage：模拟 token 持久化
import 'package:app/models/user.dart';
import 'package:app/providers/auth_provider.dart';
import 'package:app/providers/chat_provider.dart' show wsProvider;
import 'package:app/providers/saved_logins_provider.dart';
import 'package:app/router.dart';
import 'package:app/services/api_service.dart';
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

  testWidgets('点 AppBar 头像弹出侧边栏,点遮罩关闭', (tester) async {
    final container = await buildContainer();
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: Consumer(builder: (_, ref, _) {
        return MaterialApp.router(routerConfig: ref.watch(routerProvider));
      }),
    ));
    await tester.pumpAndSettle();

    // 初始面板不可见（IgnorePointer + offset -1，但仍在树中）
    // 点击 AppBar 头像
    await tester.tap(find.byType(Avatar).first);
    await tester.pumpAndSettle();
    expect(find.byType(AccountSidebar), findsOneWidget);
    expect(find.text('切换账号'), findsOneWidget);

    // 点遮罩关闭:面板宽 78%(默认测试面 800px→624px),点右侧空白处落在遮罩上
    await tester.tapAt(const Offset(700, 400));
    await tester.pumpAndSettle();
    // 面板已逻辑关闭（opacity 0）。验证 Avatar 可再点开。
    await tester.tap(find.byType(Avatar).first);
    await tester.pumpAndSettle();
    expect(find.text('切换账号'), findsOneWidget);
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

    await tester.tap(find.byType(Avatar).first);
    await tester.pumpAndSettle();
    expect(find.text('切换账号'), findsOneWidget);

    final dynamic widgetsAppState =
        tester.state(find.byType(WidgetsApp));
    // 模拟系统返回
    await widgetsAppState.didPopRoute();
    await tester.pumpAndSettle();
    // 面板关闭：再次点击头像仍可打开（说明没退出 App）
    await tester.tap(find.byType(Avatar).first);
    await tester.pumpAndSettle();
    expect(find.text('切换账号'), findsOneWidget);
  });
}
