// AgentSessionsPage embedded 模式测试:
// - embedded: AppBar 带 pin 按钮,点击写 pinnedNavTabsProvider
// - 非 embedded(路由模式): 不出现 pin 按钮(存量行为不变)
// Harness 与 e2e 同款:MockApi + FakeWS + restoreSession。
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;
import 'package:wanling_core/providers/pinned_nav_tabs_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:app/pages/agent_sessions_page.dart';
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
      name: 'agent-$id',
      status: AgentStatus.online,
      type: 'opencode',
      multiSession: true,
    );

Future<ProviderContainer> _harness(WidgetTester tester,
    {required Widget child}) async {
  SharedPreferences.setMockInitialValues({'token': 'fake-token'});
  final api = MockApi();
  when(() => api.baseUrl).thenReturn('http://test.local');
  when(() => api.getMe()).thenAnswer((_) async => _testUser);
  when(() => api.getAgents()).thenAnswer((_) async => [_agent('a1')]);
  when(() => api.getAgentSessions(any())).thenAnswer((_) async => []);
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
    child: MaterialApp(home: child),
  ));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('embedded: AppBar 出现 pin 按钮,点击后进入 pinned 列表',
      (tester) async {
    final container = await _harness(
      tester,
      child: const AgentSessionsPage(agentId: 'a1', embedded: true),
    );

    // 未 pin:outlined 图标
    expect(find.byIcon(Icons.push_pin_outlined), findsOneWidget);

    await tester.tap(find.byIcon(Icons.push_pin_outlined));
    await tester.pumpAndSettle();
    expect(container.read(pinnedNavTabsProvider), contains('a1'));
    // 已 pin:实心图标
    expect(find.byIcon(Icons.push_pin), findsOneWidget);
    expect(find.byIcon(Icons.push_pin_outlined), findsNothing);

    // 再点取消 pin
    await tester.tap(find.byIcon(Icons.push_pin));
    await tester.pumpAndSettle();
    expect(container.read(pinnedNavTabsProvider), isNot(contains('a1')));
  });

  testWidgets('路由模式:不出现 pin 按钮', (tester) async {
    await _harness(
      tester,
      child: const AgentSessionsPage(agentId: 'a1'),
    );
    expect(find.byIcon(Icons.push_pin), findsNothing);
    expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
  });

  testWidgets('embedded: pin 状态持久化还原后图标为实心', (tester) async {
    // 直接预置 pin 列表验证图标态(覆盖 provider 重读路径)
    SharedPreferences.setMockInitialValues({
      'token': 'fake-token',
      'nav_pins_u1': ['a1'],
    });
    final api = MockApi();
    when(() => api.baseUrl).thenReturn('http://test.local');
    when(() => api.getMe()).thenAnswer((_) async => _testUser);
    when(() => api.getAgents()).thenAnswer((_) async => [_agent('a1')]);
    when(() => api.getAgentSessions(any())).thenAnswer((_) async => []);

    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(FakeWS()),
      sharedPrefsProvider
          .overrideWithValue(await SharedPreferences.getInstance()),
    ]);
    addTearDown(container.dispose);
    await container.read(authProvider.notifier).restoreSession();

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: AgentSessionsPage(agentId: 'a1', embedded: true),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.push_pin), findsOneWidget);
  });
}
