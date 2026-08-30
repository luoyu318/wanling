// 「更多」抽屉测试:网格渲染/激活描边/点选切换/编辑入口。
// 预种 3 个溢出 agent(总 4 agent)触发更多槽。harness 同 e2e 模式。
import 'package:app/pages/home_page.dart';
import 'package:app/widgets/nav_tab_bar.dart';
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;
import 'package:wanling_core/providers/nav_order_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:wanling_core/services/api_service.dart';
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

Agent _agent(String id) => Agent(
      id: id,
      name: 'n-$id',
      status: AgentStatus.online,
      type: 'opencode',
      multiSession: true,
    );

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('抽屉网格渲染溢出 agent 与「编辑」入口;点 agent 切换并收起',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'token': 'fake-token',
      'nav_order_u1': [kNavTabMsg, kNavTabWanling, 'a1', 'a2', 'a3', 'a4'],
    });
    final api = MockApi();
    when(() => api.baseUrl).thenReturn('http://test.local');
    when(() => api.getMe()).thenAnswer((_) async => _testUser);
    when(() => api.getAgents()).thenAnswer((_) async =>
        [_agent('a1'), _agent('a2'), _agent('a3'), _agent('a4')]);
    when(() => api.getAgentSessions(any())).thenAnswer((_) async => []);
    when(() => api.getConversations()).thenAnswer((_) async => []);
    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(FakeWS()),
      sharedPrefsProvider.overrideWithValue(await SharedPreferences.getInstance()),
    ]);
    addTearDown(container.dispose);
    await container.read(authProvider.notifier).restoreSession();

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: HomePage()),
    ));
    await tester.pumpAndSettle();

    // 点底栏「更多」槽弹抽屉
    await tester.tap(find.text('更多'));
    await tester.pumpAndSettle();

    // 网格渲染溢出 agent(a3/a4)+编辑入口
    expect(find.text('n-a3'), findsOneWidget);
    expect(find.text('n-a4'), findsOneWidget);
    expect(find.text('编辑'), findsOneWidget);

    // 点 a3 → 抽屉收起,切到 a3 页(更多槽点亮态)
    await tester.tap(find.text('n-a3'));
    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsNothing);
    // 激活态:溢出 agent 激活时更多槽点亮(槽文案被 agent 名替代),
    // 激活 index = 可见槽数(更多槽自身下标)
    final navBar = find.byType(NavTabBar);
    expect(
        find.descendant(of: navBar, matching: find.text('n-a3')),
        findsOneWidget);
    expect(
        find.descendant(of: navBar, matching: find.text('更多')),
        findsNothing);
    expect(tester.widget<NavTabBar>(navBar).currentIndex, 4);
  });
}
