// 会话长按菜单「固定到底栏」测试:未固定/已固定文案切换、写 navOrder、
// multi_session 聚合行固定 agent 槽。harness 同 messages_page_route_test 模式
// (stub getConversations 注入会话),sharedPrefs override 供 navOrderProvider。
import 'package:app/pages/messages_page.dart';
import 'package:app/widgets/conv_action_menu.dart';
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/conversation.dart';
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

Conversation _conv({required String id, AgentSummary? agent}) => Conversation(
      id: id,
      type: agent == null ? 'dm_user_user' : 'dm_user_agent',
      agent: agent,
      participants: const [],
      lastMessageContent: null,
      lastMessageAt: DateTime.parse('2026-07-10T10:00:00Z'),
      createdAt: DateTime.parse('2026-07-10T09:00:00Z'),
    );

/// 登录态 harness(ownerId=u1):匿名中间态 NavOrderNotifier 不读 seed,
/// 「已固定」用例必须走真实 key。
Future<ProviderContainer> _pump(WidgetTester tester,
    {required List<Conversation> convs,
    List<String> navOrder = const [kNavTabMsg, kNavTabWanling]}) async {
  SharedPreferences.setMockInitialValues({
    'token': 'fake-token',
    'nav_order_u1': navOrder,
  });
  final api = MockApi();
  when(() => api.baseUrl).thenReturn('http://test.local');
  when(() => api.getMe()).thenAnswer((_) async => _testUser);
  when(() => api.getConversations()).thenAnswer((_) async => convs);
  when(() => api.hideConversation(any())).thenAnswer((_) async {});
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
    child: const MaterialApp(home: Scaffold(body: MessagesPage())),
  ));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('长按会话 → 菜单首项「固定到底栏」,点击写入 navOrder', (tester) async {
    final container = await _pump(tester, convs: [_conv(id: 'c-friend')]);
    await tester.longPress(find.text('私聊'));
    await tester.pumpAndSettle();
    // 首项 nav,既有 置顶/删除会话 依序在后
    expect(find.text('固定到底栏'), findsOneWidget);
    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('删除会话'), findsOneWidget);
    // 顺序锁:三项 dy 严格递增(固定到底栏 < 置顶 < 删除会话)
    final navDy = tester.getTopLeft(find.text('固定到底栏')).dy;
    final pinDy = tester.getTopLeft(find.text('置顶')).dy;
    final hideDy = tester.getTopLeft(find.text('删除会话')).dy;
    expect(navDy, lessThan(pinDy));
    expect(pinDy, lessThan(hideDy));
    await tester.tap(find.text('固定到底栏'));
    await tester.pumpAndSettle();
    expect(container.read(navOrderProvider), contains('conv:c-friend'));
  });

  testWidgets('已固定会话菜单显示「从底栏移除」,点击解除', (tester) async {
    final container = await _pump(tester,
        convs: [_conv(id: 'c-friend')], navOrder: [kNavTabMsg, kNavTabWanling, 'conv:c-friend']);
    await tester.longPress(find.text('私聊'));
    await tester.pumpAndSettle();
    expect(find.text('从底栏移除'), findsOneWidget);
    await tester.tap(find.text('从底栏移除'));
    await tester.pumpAndSettle();
    expect(container.read(navOrderProvider), isNot(contains('conv:c-friend')));
  });

  testWidgets('multi_session 聚合行固定的是 agent 槽', (tester) async {
    final container = await _pump(tester, convs: [
      _conv(
          id: 'c-ms',
          agent: AgentSummary(
              id: 'a-oc', name: '多会话', status: AgentStatus.online, type: 'opencode')),
    ]);
    await tester.longPress(find.text('多会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('固定到底栏'));
    await tester.pumpAndSettle();
    expect(container.read(navOrderProvider), contains('a-oc'));
    expect(container.read(navOrderProvider), isNot(contains('conv:c-ms')));
  });

  testWidgets('showNavAction=false 隐藏固定项,置顶回调正常(agent_session 二级页)',
      (tester) async {
    // 不传 onNavPinToggle,用例跑通即证明 assert 未触发
    var pinToggled = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showConvActionMenu(
                context,
                const Offset(100, 100),
                isPinned: false,
                onPinToggle: () async {
                  pinToggled = true;
                },
                onHide: () async {},
                showNavAction: false,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('固定到底栏'), findsNothing);
    expect(find.text('从底栏移除'), findsNothing);
    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('删除会话'), findsOneWidget);
    await tester.tap(find.text('置顶'));
    await tester.pumpAndSettle();
    expect(pinToggled, isTrue);
  });

  testWidgets('置顶项 icon 统一 vertical_align_top(两态同 icon)', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showConvActionMenu(
                context,
                const Offset(100, 100),
                isPinned: false,
                onPinToggle: () async {},
                onHide: () async {},
                showNavAction: false,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // 未置顶态不再用 push_pin_outlined,统一上箭头顶横线。
    expect(find.byIcon(Icons.vertical_align_top), findsOneWidget);
    expect(find.byIcon(Icons.push_pin_outlined), findsNothing);
  });
}
