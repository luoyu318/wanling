// AgentSessionsPage pin 按钮测试:
// - embedded: AppBar 带 pin 按钮,点击写 navOrderProvider
// - 非 embedded(路由模式): 同样出现 pin 按钮(支持新账号完成首次 pin),点击写 navOrderProvider
// Harness 与 e2e 同款:MockApi + FakeWS + restoreSession。
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;
import 'package:wanling_core/providers/nav_order_provider.dart';
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

Conversation _session({String id = 's1', bool pinned = false}) => Conversation(
      id: id,
      type: 'user_agent',
      title: '会话一',
      participants: const [],
      pinnedAt: pinned ? DateTime.now() : null,
      lastMessageContent: {
        'msg_type': 'text',
        'data': {'text': 'hi'},
      },
      lastMessageAt: DateTime.now().subtract(const Duration(minutes: 2)),
      createdAt: DateTime(2026, 8, 1),
    );

Future<ProviderContainer> _harness(WidgetTester tester,
    {required Widget child,
    Agent? agent,
    List<Conversation> convs = const []}) async {
  SharedPreferences.setMockInitialValues({'token': 'fake-token'});
  final api = MockApi();
  when(() => api.baseUrl).thenReturn('http://test.local');
  when(() => api.getMe()).thenAnswer((_) async => _testUser);
  when(() => api.getAgents()).thenAnswer((_) async => [agent ?? _agent('a1')]);
  when(() => api.getAgentSessions(any())).thenAnswer((_) async => convs);
  when(() => api.pinConversation(any())).thenAnswer((_) async {});
  when(() => api.unpinConversation(any())).thenAnswer((_) async {});
  when(() => api.hideConversation(any())).thenAnswer((_) async {});
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

    // 未 pin: dock 图标
    expect(find.byIcon(Icons.dock), findsOneWidget);

    await tester.tap(find.byIcon(Icons.dock));
    await tester.pumpAndSettle();
    expect(container.read(navOrderProvider), contains('a1'));
    // 已 pin: dock_outlined 图标
    expect(find.byIcon(Icons.dock_outlined), findsOneWidget);
    expect(find.byIcon(Icons.dock), findsNothing);

    // 再点取消 pin
    await tester.tap(find.byIcon(Icons.dock_outlined));
    await tester.pumpAndSettle();
    expect(container.read(navOrderProvider), isNot(contains('a1')));
  });

  testWidgets('路由模式:AppBar 出现 pin 按钮,点击后进入 pinned 列表',
      (tester) async {
    final container = await _harness(
      tester,
      child: const AgentSessionsPage(agentId: 'a1'),
    );

    // 未 pin: dock 图标
    expect(find.byIcon(Icons.dock), findsOneWidget);

    await tester.tap(find.byIcon(Icons.dock));
    await tester.pumpAndSettle();
    expect(container.read(navOrderProvider), contains('a1'));
    // 已 pin: dock_outlined 图标
    expect(find.byIcon(Icons.dock_outlined), findsOneWidget);
    expect(find.byIcon(Icons.dock), findsNothing);

    // 再点取消 pin
    await tester.tap(find.byIcon(Icons.dock_outlined));
    await tester.pumpAndSettle();
    expect(container.read(navOrderProvider), isNot(contains('a1')));
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

    expect(find.byIcon(Icons.dock_outlined), findsOneWidget);
  });

  testWidgets('非 multiSession agent:AppBar 不渲染 pin 按钮(防御门控)',
      (tester) async {
    final agent = Agent(
      id: 'a1',
      name: 'agent-a1',
      status: AgentStatus.online,
      type: 'hermes',
      multiSession: false,
    );
    await _harness(
      tester,
      agent: agent,
      child: AgentSessionsPage(agentId: agent.id, embedded: true),
    );

    // 设计边界:单会话 agent 不进底栏导航,pin 按钮不渲染
    expect(find.byIcon(Icons.dock_outlined), findsNothing);
    expect(find.byIcon(Icons.dock), findsNothing);
    // AppBar 其余动作(新建会话)不受影响(scope 到 AppBar,规避侧栏头部同名图标)
    expect(
        find.descendant(
            of: find.byType(AppBar), matching: find.byIcon(Icons.add)),
        findsOneWidget);
  });

  testWidgets('左滑露出 置顶/删除会话 两按钮(无固定底栏入口)', (tester) async {
    await _harness(
      tester,
      child: const AgentSessionsPage(agentId: 'a1', embedded: true),
      convs: [_session()],
    );

    await tester.drag(find.text('会话一'), const Offset(-300, 0));
    await tester.pumpAndSettle();

    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('删除会话'), findsOneWidget);
    expect(find.text('固定到底栏'), findsNothing);
  });

  testWidgets('左滑点击置顶调 pinConversation API,点击删除弹确认框',
      (tester) async {
    final container = await _harness(
      tester,
      child: const AgentSessionsPage(agentId: 'a1', embedded: true),
      convs: [_session()],
    );

    await tester.drag(find.text('会话一'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('置顶'));
    await tester.pumpAndSettle();
    verify(() => container.read(apiProvider).pinConversation('s1')).called(1);

    await tester.drag(find.text('会话一'), const Offset(-300, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除会话'));
    await tester.pumpAndSettle();
    expect(find.text('确认删除该会话?'), findsOneWidget);
  });
}
