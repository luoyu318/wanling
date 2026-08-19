// 端到端路由测试：覆盖未登录/已登录 redirect、底部 tab 切换三场景。
//
// 关键 Mock 策略：
// - apiProvider：用 mocktail 的 MockApi，stub getMe/getAgents/getConversations
// - wsProvider：用 FakeWS（test/helpers/fake_ws.dart），避免真实 WS 连接
//   wsProvider 在 auth.isAuthenticated 时会调用 connect()，连真实 WS 会失败/超时；
//   FakeWS.messages 返回空 Stream，conversationProvider 订阅后不会收到任何消息
// - SharedPreferences：用 setMockInitialValues 模拟 token 持久化
import 'package:wanling_core/models/user.dart';
import 'package:app/pages/profile_page.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:app/router.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

/// 测试用 User fixture（避免每处重复构造）。
final _testUser = User(
  id: 'u1',
  username: 'kira',
  avatarUrl: null,
  createdAt: DateTime.utc(2026, 6, 13),
);

void main() {
  setUp(() {
    // auth_provider.restoreSession 会调 SecureStorage.getAccessToken,
    // flutter_secure_storage 在 flutter test 环境无原生通道,
    // 不调 setMockInitialValues 会永远挂起导致 pumpAndSettle 死循环。
    FlutterSecureStorage.setMockInitialValues({});
  });

  // mocktail 未 stub 的非空 String getter 会返回 null 触发 type error，
  // 这里给所有 MockApi 实例补一个 baseUrl stub。auth_provider 的 service IPC
  // 调用会读 api.baseUrl。
  void stubBaseUrl(MockApi api) {
    when(() => api.baseUrl).thenReturn('http://test.local');
  }

  group('路由 redirect', () {
    testWidgets('未登录访问任意路由重定向到 /login', (tester) async {
      SharedPreferences.setMockInitialValues({}); // 无 token
      final api = MockApi();
      stubBaseUrl(api);
      final ws = FakeWS();

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        wsProvider.overrideWithValue(ws),
        sharedPrefsProvider
            .overrideWithValue(await SharedPreferences.getInstance()),
      ]);
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).restoreSession();

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (_, ref, _) {
          return MaterialApp.router(routerConfig: ref.watch(routerProvider));
        }),
      ));
      await tester.pumpAndSettle();

      // 应该看到登录页（用户名/密码两个输入框）
      expect(find.byType(TextField), findsWidgets);
    });

    testWidgets('已登录访问 /login 重定向到 /', (tester) async {
      SharedPreferences.setMockInitialValues({'token': 'fake-token'});
      final api = MockApi();
      stubBaseUrl(api);
      final ws = FakeWS();
      when(() => api.getMe()).thenAnswer((_) async => _testUser);
      // 重定向到 / 后 _AGroupPage 的 IndexedStack 会同时构建 MessagesPage + AgentListPage，
      // 二者 initState/build 均会触发 load，故 getConversations + getAgents 都需 stub。
      when(() => api.getConversations()).thenAnswer((_) async => []);
      when(() => api.getAgents()).thenAnswer((_) async => []);

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        wsProvider.overrideWithValue(ws),
        sharedPrefsProvider
            .overrideWithValue(await SharedPreferences.getInstance()),
      ]);
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).restoreSession();

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (_, ref, _) {
          return MaterialApp.router(routerConfig: ref.watch(routerProvider));
        }),
      ));
      await tester.pumpAndSettle();

      // 应该看到 HomePage 的底部导航
      expect(find.byType(BottomNavigationBar), findsOneWidget);
      expect(find.text('消息'), findsWidgets);
      expect(find.text('万灵'), findsWidgets);
      expect(find.text('我的'), findsWidgets);
    });
  });

  group('底部导航切换', () {
    testWidgets('点击 tab 切换分支', (tester) async {
      SharedPreferences.setMockInitialValues({'token': 'fake-token'});
      final api = MockApi();
      stubBaseUrl(api);
      final ws = FakeWS();
      when(() => api.getMe()).thenAnswer((_) async => _testUser);
      // 进入 MessagesPage 会触发 conversationProvider.load；切到 AgentListPage
      // 时 AgentListNotifier 构造函数也会自动 load。stub 二者返回空。
      when(() => api.getAgents()).thenAnswer((_) async => []);
      when(() => api.getConversations()).thenAnswer((_) async => []);

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        wsProvider.overrideWithValue(ws),
        sharedPrefsProvider
            .overrideWithValue(await SharedPreferences.getInstance()),
      ]);
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).restoreSession();

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (_, ref, _) {
          return MaterialApp.router(routerConfig: ref.watch(routerProvider));
        }),
      ));
      await tester.pumpAndSettle();

      // 默认 / (PageView index 0 = 消息 tab)
      expect(find.text('消息'), findsWidgets);

      // 点击 Agent tab
      await tester.tap(find.text('万灵'));
      await tester.pumpAndSettle();
      // 应该看到 Agent 列表页面（空状态显示"暂无 Agent"）
      expect(find.text('暂无 Agent'), findsOneWidget);

      // 点击 我的 tab
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      // 应该看到 ProfilePage 顶部用户名(侧边栏常驻也会显示用户名,限定在 ProfilePage 内查找)
      expect(
        find.descendant(
          of: find.byType(ProfilePage),
          matching: find.text('kira'),
        ),
        findsOneWidget,
      );
    });
  });
}
