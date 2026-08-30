// HomePage 会话槽测试:渲染/点击路由(marker 路由)/更多抽屉 conv 项/隐藏会话收缩。
// harness 同 more_sheet_test:MockApi + FakeWS + restoreSession;路由用 marker 页,
// 不构建真实 ChatPage(避免聊天页 provider 链 stub 负担)。
import 'package:app/pages/home_page.dart';
import 'package:app/widgets/nav_tab_bar.dart';
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/models/user_summary.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;
import 'package:wanling_core/providers/conversation_provider.dart';
import 'package:wanling_core/providers/nav_order_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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

Conversation _friendConv() => Conversation(
      id: 'c-friend',
      type: 'dm_user_user',
      otherUser: UserSummary(username: 'f1', nickname: '好友A', avatarUrl: ''),
      participants: const [],
      lastMessageContent: null,
      lastMessageAt: DateTime.parse('2026-07-10T10:00:00Z'),
      createdAt: DateTime.parse('2026-07-10T09:00:00Z'),
      unreadCount: 3,
    );

Conversation _groupConv() => Conversation(
      id: 'c-group',
      type: 'group_user',
      title: '项目群',
      participants: const [],
      lastMessageContent: null,
      lastMessageAt: DateTime.parse('2026-07-10T10:00:00Z'),
      createdAt: DateTime.parse('2026-07-10T09:00:00Z'),
      // 未读 1:让消息 tab 总未读徽章(3+1=4)与会话槽角标(3)区分开,
      // 否则 NavTabBar 内 '3' 会匹配到两处,渲染断言无法 findsOneWidget。
      unreadCount: 1,
    );

Conversation _agentDmConv() => Conversation(
      id: 'c-dm',
      type: 'dm_user_agent',
      agent: AgentSummary(id: 'a1', name: '小灵', status: AgentStatus.online, type: ''),
      participants: const [],
      lastMessageContent: null,
      lastMessageAt: DateTime.parse('2026-07-10T10:00:00Z'),
      createdAt: DateTime.parse('2026-07-10T09:00:00Z'),
    );

Conversation _msConv() => Conversation(
      id: 'c-ms',
      type: 'dm_user_agent',
      // 名字 ≤5 字:底栏槽位标签超 5 字会截断加省略号, finder 需按截断后文案匹配。
      agent: AgentSummary(id: 'a-oc', name: '聚合机器人', status: AgentStatus.online, type: 'opencode'),
      participants: const [],
      lastMessageContent: null,
      lastMessageAt: DateTime.parse('2026-07-10T10:00:00Z'),
      createdAt: DateTime.parse('2026-07-10T09:00:00Z'),
    );

final _navFinder = find.byType(NavTabBar);

Future<ProviderContainer> _harness(
  WidgetTester tester, {
  required List<String> navOrder,
  List<Conversation> convs = const [],
}) async {
  SharedPreferences.setMockInitialValues({
    'token': 'fake-token',
    'nav_order_u1': navOrder,
  });
  final api = MockApi();
  when(() => api.baseUrl).thenReturn('http://test.local');
  when(() => api.getMe()).thenAnswer((_) async => _testUser);
  when(() => api.getAgents()).thenAnswer((_) async => [_agent('a9')]);
  when(() => api.getAgentSessions(any())).thenAnswer((_) async => []);
  when(() => api.getConversations()).thenAnswer((_) async => convs);
  when(() => api.hideConversation(any())).thenAnswer((_) async {});
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(path: '/', builder: (_, _) => const HomePage()),
      GoRoute(
        path: '/chat/:convId',
        builder: (_, state) => Scaffold(
          body: Text('chat-${state.pathParameters['convId']}'
              '?agent=${state.uri.queryParameters['agentId'] ?? 'null'}'),
        ),
      ),
      GoRoute(
        path: '/agent/:agentId/sessions',
        builder: (_, state) =>
            Scaffold(body: Text('sessions-${state.pathParameters['agentId']}')),
      ),
      GoRoute(
        path: '/nav-edit',
        builder: (_, _) => const Scaffold(body: Text('EDIT-PAGE')),
      ),
    ],
  );
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
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('会话槽渲染名字与未读角标', (tester) async {
    await _harness(
      tester,
      navOrder: [kNavTabMsg, 'conv:c-friend', 'conv:c-group', kNavTabWanling],
      convs: [_friendConv(), _groupConv()],
    );
    expect(find.descendant(of: _navFinder, matching: find.text('好友A')),
        findsOneWidget);
    expect(find.descendant(of: _navFinder, matching: find.text('项目群')),
        findsOneWidget);
    expect(find.descendant(of: _navFinder, matching: find.text('3')),
        findsOneWidget); // 未读角标(总未读 4 已由 fixture 错开,详见 _groupConv)
  });

  testWidgets('点击好友槽 → chat 路由无 agentId', (tester) async {
    await _harness(
      tester,
      navOrder: ['conv:c-friend', 'conv:c-group', kNavTabWanling, kNavTabMsg],
      convs: [_friendConv(), _groupConv()],
    );
    await tester.tap(find.descendant(of: _navFinder, matching: find.text('好友A')));
    await tester.pumpAndSettle();
    expect(find.text('chat-c-friend?agent=null'), findsOneWidget);
  });

  testWidgets('点击普通 agent 单聊槽 → chat 路由带 agentId', (tester) async {
    await _harness(
      tester,
      navOrder: ['conv:c-dm', kNavTabMsg, kNavTabWanling, 'conv:c-group'],
      convs: [_agentDmConv(), _groupConv()],
    );
    await tester.tap(find.descendant(of: _navFinder, matching: find.text('小灵')));
    await tester.pumpAndSettle();
    expect(find.text('chat-c-dm?agent=a1'), findsOneWidget);
  });

  testWidgets('点击 multi_session 聚合会话槽 → sessions 路由', (tester) async {
    await _harness(
      tester,
      navOrder: ['conv:c-ms', kNavTabMsg, kNavTabWanling, 'conv:c-group'],
      convs: [_msConv(), _groupConv()],
    );
    await tester.tap(
        find.descendant(of: _navFinder, matching: find.text('聚合机器人')));
    await tester.pumpAndSettle();
    expect(find.text('sessions-a-oc'), findsOneWidget);
  });

  testWidgets('更多抽屉 conv 项:点击跳聊天页,长按进编辑页', (tester) async {
    await _harness(
      tester,
      navOrder: [
        kNavTabMsg,
        kNavTabWanling,
        'conv:c-group',
        'a9',
        // conv 槽排第 5 位才会溢出进更多抽屉(可见槽数自动规则:5 项可见 4)
        'conv:c-friend',
      ],
      convs: [_friendConv(), _groupConv()],
    );
    // 5 项 → 可见 4 + 更多槽;弹抽屉
    await tester.tap(find.descendant(of: _navFinder, matching: find.text('更多')));
    await tester.pumpAndSettle();
    // 点击抽屉 conv 项(key: more-conv:<convId>) → 跳聊天页
    await tester.tap(find.byKey(const ValueKey('more-conv:c-friend')));
    await tester.pumpAndSettle();
    expect(find.text('chat-c-friend?agent=null'), findsOneWidget);
  });

  testWidgets('更多抽屉 conv 项:长按进编辑页', (tester) async {
    // seed 同「更多抽屉 conv 项」用例:conv:c-friend 排第 5 位溢出进抽屉
    await _harness(
      tester,
      navOrder: [
        kNavTabMsg,
        kNavTabWanling,
        'conv:c-group',
        'a9',
        'conv:c-friend',
      ],
      convs: [_friendConv(), _groupConv()],
    );
    await tester.tap(find.descendant(of: _navFinder, matching: find.text('更多')));
    await tester.pumpAndSettle();
    await tester.longPress(find.byKey(const ValueKey('more-conv:c-friend')));
    await tester.pumpAndSettle();
    expect(find.text('EDIT-PAGE'), findsOneWidget);
  });

  testWidgets('会话被删除(hide)后底栏槽自动收缩', (tester) async {
    final container = await _harness(
      tester,
      navOrder: ['conv:c-friend', 'conv:c-group', kNavTabMsg, kNavTabWanling],
      convs: [_friendConv(), _groupConv()],
    );
    expect(find.descendant(of: _navFinder, matching: find.text('好友A')),
        findsOneWidget);
    await container.read(conversationProvider.notifier).hide('c-friend');
    await tester.pumpAndSettle();
    expect(find.descendant(of: _navFinder, matching: find.text('好友A')),
        findsNothing);
    // 不降级渲染原始 id(fail-soft 兜底文案走 displayName ?? convId,
    // 会话已不在列表时槽位整体收缩,不允许残留 'c-friend' 字样)。
    expect(find.text('c-friend'), findsNothing);
  });
}
