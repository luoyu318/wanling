// messages_page_route_test.dart
//
// 验证一级消息列表行 onTap 按 agent.type 路由分支(spec §7.1):
//   - opencode agent 行 → /agent/:agentId/sessions(二级列表页)
//   - 其它 agent 行      → /chat/:convId(单聊页)
//
// 策略:widget test,直接 pump MessagesPage,通过 stub getConversations
// 注入两条可控会话(opencode + 普通),用 GoRouter 注册 marker 页面,
// 点击行后通过 marker 文案断言跳转目标。
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:app/pages/messages_page.dart';
import 'package:app/providers/auth_provider.dart' show apiProvider;
import 'package:app/providers/chat_provider.dart' show wsProvider;
import 'package:wanling_core/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

/// 测试用 Conversation fixture(避免每处重复构造)。
Conversation _mkConv({
  required String id,
  required String type,
  required AgentSummary agent,
}) {
  return Conversation(
    id: id,
    type: type,
    agent: agent,
    otherUser: null,
    participants: const [],
    lastMessageContent: null,
    lastMessageAt: DateTime.parse('2026-07-10T10:00:00Z'),
    createdAt: DateTime.parse('2026-07-10T09:00:00Z'),
  );
}

void main() {
  late MockApi api;
  late FakeWS ws;

  setUp(() {
    api = MockApi();
    // mocktail 未 stub 的非空 String getter 返 null 触发 type error,补 baseUrl stub。
    when(() => api.baseUrl).thenReturn('http://test.local');
    ws = FakeWS();
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  Widget buildApp(ProviderContainer container) {
    final router = GoRouter(
      initialLocation: '/',
      routes: [
        // MessagesPage 自身仅 ColoredBox,无 Material 祖先(生产环境挂在 HomePage
        // 的 Scaffold 里)。这里用 Scaffold 包一层让 InkWell 能找到 Material。
        GoRoute(
          path: '/',
          builder: (_, _) => const Scaffold(body: MessagesPage()),
        ),
        GoRoute(
          path: '/agent/:agentId/sessions',
          builder: (_, state) => Scaffold(
            body: Text('sessions-${state.pathParameters['agentId']}'),
          ),
        ),
        GoRoute(
          path: '/chat/:convId',
          builder: (_, state) => Scaffold(
            body: Text('chat-${state.pathParameters['convId']}'),
          ),
        ),
      ],
    );
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    );
  }

  group('messages_page onTap 按 agent.type 路由', () {
    testWidgets('opencode agent 行点击 → 二级列表页', (tester) async {
      final opencodeAgent = AgentSummary(
        id: 'a-oc',
        name: 'OpenCode 机器人',
        status: AgentStatus.online,
        type: 'opencode',
      );
      final conv = _mkConv(id: 'c-oc', type: 'dm_user_agent', agent: opencodeAgent);
      when(() => api.getConversations()).thenAnswer((_) async => [conv]);
      when(() => api.getAgentSessions('a-oc')).thenAnswer((_) async => []);

      final container = makeContainer();
      await tester.pumpWidget(buildApp(container));
      // 等 conversationProvider.load() 完成把列表渲染出来。
      await tester.pumpAndSettle();

      // 点击 opencode agent 行(按 displayName 定位)。
      await tester.tap(find.text('OpenCode 机器人'));
      await tester.pumpAndSettle();

      expect(find.text('sessions-a-oc'), findsOneWidget,
          reason: 'opencode agent 行点击应跳转到二级列表页');
    });

    testWidgets('普通 agent 行点击 → 单聊页', (tester) async {
      final normalAgent = AgentSummary(
        id: 'a-nm',
        name: '普通机器人',
        status: AgentStatus.online,
        type: '',
      );
      final conv = _mkConv(id: 'c-nm', type: 'dm_user_agent', agent: normalAgent);
      when(() => api.getConversations()).thenAnswer((_) async => [conv]);

      final container = makeContainer();
      await tester.pumpWidget(buildApp(container));
      await tester.pumpAndSettle();

      await tester.tap(find.text('普通机器人'));
      await tester.pumpAndSettle();

      expect(find.text('chat-c-nm'), findsOneWidget,
          reason: '普通 agent 行点击应跳转到单聊页');
    });
  });
}
