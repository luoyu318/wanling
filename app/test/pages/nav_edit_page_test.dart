// NavEditPage widget 测试:白条/网格渲染、白条内换位(含固定项)、跨区拖拽、减号 unpin、完成 pop。
// Harness 与 agent_sessions_embedded_test 同款:MockApi + FakeWS + restoreSession。
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/models/user_summary.dart';
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
/// [seed] 可覆盖 nav_order_u1(如 agent 前置序列场景)。
/// [convs] 预种会话列表(effectiveNavOrderProvider 依赖 conversationProvider,
/// ConversationListNotifier 构造即 load,必须 stub getConversations)。
Future<ProviderContainer> _harness(WidgetTester tester,
    {List<String>? seed, List<Conversation> convs = const []}) async {
  SharedPreferences.setMockInitialValues({
    'token': 'fake-token',
    'nav_order_u1':
        seed ?? [kNavTabMsg, kNavTabWanling, 'a1', 'a2', 'a3', 'a4'],
  });
  final api = MockApi();
  when(() => api.baseUrl).thenReturn('http://test.local');
  when(() => api.getMe()).thenAnswer((_) async => _testUser);
  when(() => api.getAgents())
      .thenAnswer((_) async => [_agent('a1'), _agent('a2'), _agent('a3'), _agent('a4')]);
  when(() => api.getAgentSessions(any())).thenAnswer((_) async => []);
  when(() => api.getConversations()).thenAnswer((_) async => convs);
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

  testWidgets('跨区拖拽:网格 agent 拖到白条槽上,可见性互换并扩容', (tester) async {
    final container = await _harness(tester);
    final a3Center = tester.getCenter(find.text('n-a3'));
    final a1Center = tester.getCenter(find.text('n-a1'));
    final gesture = await tester.startGesture(a3Center);
    await tester.pump(const Duration(seconds: 1));
    await gesture.moveBy(a1Center - a3Center);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    // a3 插到序列位 2,其余顺移:a2 掉溢出区;可见数上限 4,set(5) 被 clamp
    expect(container.read(navOrderProvider),
        [kNavTabMsg, kNavTabWanling, 'a3', 'a1', 'a2', 'a4']);
    expect(container.read(navVisibleCountProvider), 4);
  });

  testWidgets('池项拖到白条空白处放手:按落点 x 计算插入槽位', (tester) async {
    final container = await _harness(tester);
    // 白条槽宽:barRect 宽/5,落点选第 4 槽(a2,序列位 3)中部
    // → floor 后 idx=3 → a3 插到 a2 前
    final a3Center = tester.getCenter(find.text('n-a3'));
    final barBox = tester.getRect(find.byKey(const ValueKey('nav-edit-bar')));
    final dropX = barBox.left + 8 + (barBox.width - 16) / 5 * 3.2;
    final gesture = await tester.startGesture(a3Center);
    await tester.pump(const Duration(seconds: 1));
    // 用绝对坐标 moveTo:先水平移到目标 x,再垂直落到白条中线
    await gesture.moveTo(Offset(dropX, a3Center.dy));
    await tester.pump();
    await gesture.moveTo(Offset(dropX, barBox.center.dy));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(container.read(navOrderProvider),
        [kNavTabMsg, kNavTabWanling, 'a1', 'a3', 'a2', 'a4']);
    // 可见数已在上限 4:set(5) 被 clamp,新项挤进白条末位原项掉池(交换语义)
    expect(container.read(navVisibleCountProvider), 4);
  });

  testWidgets('agent 前置序列:白条=前 4 agent,消息/万灵进网格池仍可达', (tester) async {
    await _harness(tester,
        seed: ['a1', 'a2', 'a3', 'a4', kNavTabMsg, kNavTabWanling]);
    // 白条 = 序列前缀(4 agent)+更多格
    expect(find.text('更多'), findsOneWidget);
    expect(find.text('n-a1'), findsOneWidget);
    expect(find.text('n-a2'), findsOneWidget);
    // 消息/万灵被截进网格池(图标方块,无减号),各恰一次
    expect(find.text('消息'), findsOneWidget);
    expect(find.text('万灵'), findsOneWidget);
    expect(find.byKey(const ValueKey('unpin-$kNavTabMsg')), findsNothing);
    expect(find.byKey(const ValueKey('unpin-$kNavTabWanling')), findsNothing);
  });

  testWidgets('白条项拖到池区放手:收进更多(插入池首,可见数-1)', (tester) async {
    final container = await _harness(tester);
    final msgCenter = tester.getCenter(find.text('消息'));
    final a3Center = tester.getCenter(find.text('n-a3'));
    final gesture = await tester.startGesture(msgCenter);
    await tester.pump(const Duration(seconds: 1));
    await gesture.moveBy(a3Center - msgCenter);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    // 池格不再接受白条来源项 → 拖出白条放手 = 收进更多:
    // msg move 到池首(原 visible-1=3),可见数 4→3
    expect(container.read(navOrderProvider),
        [kNavTabWanling, 'a1', 'a2', kNavTabMsg, 'a3', 'a4']);
    expect(container.read(navVisibleCountProvider), 3);
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

  testWidgets('会话槽:池渲染名字/未读,减号 unpin 生效', (tester) async {
    // conv:c1 垫在 a1/a2 之后(5 项,visible=4)使其溢出进网格池;
    // 简报原 seed 3 项全可见落白条,grid key 永远找不到,按测试语义适配。
    final container = await _harness(
      tester,
      seed: [kNavTabMsg, kNavTabWanling, 'a1', 'a2', 'conv:c1'],
      convs: [
        Conversation(
          id: 'c1',
          type: 'dm_user_user',
          otherUser: UserSummary(username: 'f1', nickname: '好友A', avatarUrl: ''),
          participants: const [],
          lastMessageContent: null,
          lastMessageAt: DateTime.parse('2026-07-10T10:00:00Z'),
          createdAt: DateTime.parse('2026-07-10T09:00:00Z'),
          unreadCount: 2,
        ),
      ],
    );
    expect(find.byKey(const ValueKey('grid-conv:c1')), findsOneWidget);
    expect(find.text('好友A'), findsOneWidget);
    expect(find.text('2'), findsOneWidget); // 未读角标
    await tester.tap(find.byKey(const ValueKey('unpin-conv:c1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grid-conv:c1')), findsNothing);
    expect(container.read(navOrderProvider),
        [kNavTabMsg, kNavTabWanling, 'a1', 'a2']);
  });
}
