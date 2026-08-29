// NavEditPage widget 测试:白条/网格渲染、白条内换位(含固定项)、跨区拖拽、减号 unpin、完成 pop。
// Harness 与 agent_sessions_embedded_test 同款:MockApi + FakeWS + restoreSession。
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;
import 'package:wanling_core/providers/nav_order_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:app/pages/nav_edit_page.dart';
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

/// 预种 4 个溢出场景 agent:白条=[msg,wanling,a1,a2]+更多格,网格=[a3,a4]。
Future<ProviderContainer> _harness(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({
    'token': 'fake-token',
    'nav_order_u1': [kNavTabMsg, kNavTabWanling, 'a1', 'a2', 'a3', 'a4'],
  });
  final api = MockApi();
  when(() => api.baseUrl).thenReturn('http://test.local');
  when(() => api.getMe()).thenAnswer((_) async => _testUser);
  when(() => api.getAgents())
      .thenAnswer((_) async => [_agent('a1'), _agent('a2'), _agent('a3'), _agent('a4')]);
  when(() => api.getAgentSessions(any())).thenAnswer((_) async => []);
  final ws = FakeWS();
  final container = ProviderContainer(overrides: [
    apiProvider.overrideWithValue(api),
    wsProvider.overrideWithValue(ws),
    sharedPrefsProvider.overrideWithValue(await SharedPreferences.getInstance()),
  ]);
  addTearDown(container.dispose);
  await container.read(authProvider.notifier).restoreSession();
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: const MaterialApp(home: NavEditPage()),
  ));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('渲染:白条显示 msg/wanling/a1/a2+更多格,网格显示溢出 a3/a4',
      (tester) async {
    await _harness(tester);
    expect(find.text('更多'), findsOneWidget); // 白条更多格
    expect(find.text('n-a1'), findsOneWidget);
    expect(find.text('n-a3'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
  });

  testWidgets('白条内拖拽 agent 到固定项槽:任意排序生效', (tester) async {
    final container = await _harness(tester);
    final a1Center = tester.getCenter(find.text('n-a1'));
    final msgCenter = tester.getCenter(find.text('消息'));
    final gesture = await tester.startGesture(a1Center);
    await tester.pump(const Duration(seconds: 1));
    await gesture.moveBy(msgCenter - a1Center);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    // move 语义:a1 落到消息槽(位 0),其余顺移——固定项可被换到任意位。
    expect(container.read(navOrderProvider),
        ['a1', kNavTabMsg, kNavTabWanling, 'a2', 'a3', 'a4']);
  });

  testWidgets('跨区拖拽:网格 agent 拖进白条,可见性互换', (tester) async {
    final container = await _harness(tester);
    final a3Center = tester.getCenter(find.text('n-a3'));
    final a1Center = tester.getCenter(find.text('n-a1'));
    final gesture = await tester.startGesture(a3Center);
    await tester.pump(const Duration(seconds: 1));
    await gesture.moveBy(a1Center - a3Center);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    // a3 插到序列位 2,其余顺移:a2 掉溢出区
    expect(container.read(navOrderProvider),
        [kNavTabMsg, kNavTabWanling, 'a3', 'a1', 'a2', 'a4']);
  });

  testWidgets('减号 unpin:列表收缩且白条刷新', (tester) async {
    final container = await _harness(tester);
    await tester.tap(find.byKey(const ValueKey('unpin-a3')));
    await tester.pumpAndSettle();
    expect(container.read(navOrderProvider), isNot(contains('a3')));
    expect(find.text('n-a3'), findsNothing);
  });

  testWidgets('固定项方块无减号(不可移除)', (tester) async {
    await _harness(tester);
    expect(find.byKey(const ValueKey('unpin-$kNavTabMsg')), findsNothing);
    expect(find.byKey(const ValueKey('unpin-$kNavTabWanling')), findsNothing);
  });

  testWidgets('点完成 pop 页面', (tester) async {
    final container = await _harness(tester);
    // 用 Navigator 观察 pop:包一层 home route 计数
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    expect(find.text('完成'), findsNothing); // 页面已退出
    expect(container.read(navOrderProvider).length, 6); // 数据未被破坏
  });
}
