import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/participant.dart';
import 'package:app/pages/conversation_detail_page.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;
import 'package:wanling_core/services/api_service.dart';
import 'package:app/widgets/agent_badge.dart';
import 'package:app/widgets/avatar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

Widget _wrapWithRouter(ProviderContainer container, {String initialLocation = '/'}) {
  final router = GoRouter(
    initialLocation: initialLocation,
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => const SizedBox.shrink(),
      ),
      GoRoute(
        path: '/conversations/:id/detail',
        builder: (_, state) => ConversationDetailPage(
          convId: state.pathParameters['id']!,
        ),
      ),
      GoRoute(
        path: '/agent/:id',
        builder: (_, _) => const SizedBox.shrink(),
      ),
    ],
  );
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(routerConfig: router),
  );
}

Conversation _agentSessionConv({
  String? directory = '/home/user/projects/wanling',
  SessionMeta? sessionMeta,
  String? title = '重构认证模块',
}) {
  return Conversation(
    id: 'conv-1',
    type: 'agent_session',
    title: title,
    avatarUrl: null,
    agent: AgentSummary(
      id: 'agent-1',
      name: 'opencode',
      avatarUrl: null,
      status: AgentStatus.online,
      type: 'opencode',
    ),
    otherUser: null,
    participants: const [],
    lastMessageContent: null,
    lastMessageAt: DateTime.utc(2026, 7, 22),
    createdAt: DateTime.utc(2026, 7, 22),
    directory: directory,
    sessionMeta: sessionMeta,
  );
}

Conversation _dmUserAgentConv({
  String? agentBio = '我是你的 AI 助手，有什么可以帮你的吗？',
  AgentStatus agentStatus = AgentStatus.online,
}) {
  return Conversation(
    id: 'conv-dm',
    type: 'dm_user_agent',
    title: null,
    avatarUrl: null,
    agent: AgentSummary(
      id: 'agent-dm',
      name: '万灵助手',
      avatarUrl: null,
      status: agentStatus,
      type: 'hermes',
      bio: agentBio,
    ),
    otherUser: null,
    participants: const [],
    lastMessageContent: null,
    lastMessageAt: DateTime.utc(2026, 7, 22),
    createdAt: DateTime.utc(2026, 7, 22),
  );
}

Conversation _groupConv() {
  return Conversation(
    id: 'conv-group',
    type: 'group_user',
    title: '测试群',
    avatarUrl: null,
    agent: null,
    otherUser: null,
    participants: [
      Participant(
        memberId: 'u1', memberType: 'user', role: 'owner',
        username: 'alice', nickname: 'Alice', avatarUrl: '',
      ),
      Participant(
        memberId: 'u2', memberType: 'user', role: 'member',
        username: 'bob', nickname: 'Bob', avatarUrl: '',
      ),
    ],
    lastMessageContent: null,
    lastMessageAt: DateTime.utc(2026, 7, 22),
    createdAt: DateTime.utc(2026, 7, 22),
  );
}

void main() {
  late MockApi api;
  late FakeWS ws;

  setUp(() {
    api = MockApi();
    ws = FakeWS();
    registerFallbackValue(Conversation(
      id: '', type: '', participants: const [],
      lastMessageContent: null,
      lastMessageAt: DateTime.utc(2026, 7, 22),
      createdAt: DateTime.utc(2026, 7, 22),
    ));
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  testWidgets('agent_session: 渲染 Session 卡片（会话名称 + 编辑图标 + AgentBadge）',
      (tester) async {
    when(() => api.getConversation('conv-1'))
        .thenAnswer((_) async => _agentSessionConv());

    final container = makeContainer();
    await tester.pumpWidget(_wrapWithRouter(container,
        initialLocation: '/conversations/conv-1/detail'));
    await tester.pumpAndSettle();

    expect(find.text('重构认证模块'), findsOneWidget);
    expect(find.byType(AgentBadge), findsOneWidget);
    expect(find.byIcon(Icons.edit), findsOneWidget);
    expect(find.byType(Avatar), findsOneWidget);
  });

  testWidgets('agent_session: 渲染会话环境（工作目录/Git分支/Provider/Model/Mode）',
      (tester) async {
    when(() => api.getConversation('conv-1')).thenAnswer((_) async =>
        _agentSessionConv(
          directory: '/home/user/projects/wanling',
          sessionMeta: const SessionMeta(
            mode: 'plan',
            modelId: 'claude-sonnet-4',
            providerId: 'anthropic',
            modelName: 'claude-sonnet-4',
            providerName: 'Anthropic',
            gitBranch: 'main',
            tokensTotal: 1284503,
            contextUsed: 47832,
            contextLimit: 200000,
          ),
        ));

    final container = makeContainer();
    await tester.pumpWidget(_wrapWithRouter(container,
        initialLocation: '/conversations/conv-1/detail'));
    await tester.pumpAndSettle();

    expect(find.text('工作目录'), findsOneWidget);
    expect(find.text('/home/user/projects/wanling'), findsOneWidget);
    expect(find.text('Git 分支'), findsOneWidget);
    expect(find.text('main'), findsOneWidget);
    expect(find.text('Provider'), findsOneWidget);
    expect(find.text('Anthropic'), findsOneWidget);
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('claude-sonnet-4'), findsOneWidget);
    expect(find.text('Mode'), findsOneWidget);
    expect(find.text('plan'), findsOneWidget);
  });

  testWidgets('agent_session: 渲染上下文使用卡片（进度条 + 百分比 + 累计 tokens）',
      (tester) async {
    when(() => api.getConversation('conv-1')).thenAnswer((_) async =>
        _agentSessionConv(
          sessionMeta: const SessionMeta(
            mode: 'code',
            modelId: 'm1', providerId: 'p1',
            tokensTotal: 1284503,
            contextUsed: 47832,
            contextLimit: 200000,
          ),
        ));

    final container = makeContainer();
    await tester.pumpWidget(_wrapWithRouter(container,
        initialLocation: '/conversations/conv-1/detail'));
    await tester.pumpAndSettle();

    expect(find.text('上下文使用'), findsOneWidget);
    expect(find.textContaining('47.8k'), findsOneWidget);
    expect(find.textContaining('200k'), findsOneWidget);
    expect(find.textContaining('24%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('1.28M'), findsOneWidget);
  });

  testWidgets('agent_session: sessionMeta 为 null 时环境卡片整段不渲染',
      (tester) async {
    when(() => api.getConversation('conv-1'))
        .thenAnswer((_) async => _agentSessionConv(sessionMeta: null));

    final container = makeContainer();
    await tester.pumpWidget(_wrapWithRouter(container,
        initialLocation: '/conversations/conv-1/detail'));
    await tester.pumpAndSettle();

    expect(find.text('工作目录'), findsNothing);
    expect(find.text('上下文使用'), findsNothing);
  });

  testWidgets('agent_session: 渲染置顶/隐藏会话操作 tile', (tester) async {
    when(() => api.getConversation('conv-1'))
        .thenAnswer((_) async => _agentSessionConv());

    final container = makeContainer();
    await tester.pumpWidget(_wrapWithRouter(container,
        initialLocation: '/conversations/conv-1/detail'));
    await tester.pumpAndSettle();

    expect(find.text('置顶会话'), findsOneWidget);
    expect(find.text('隐藏会话'), findsOneWidget);
    expect(find.text('删除会话'), findsOneWidget);
  });

  testWidgets('agent_session: 删除按钮弹"删除会话"弹窗(非"退出群聊")',
      (tester) async {
    when(() => api.getConversation('conv-1'))
        .thenAnswer((_) async => _agentSessionConv());

    final container = makeContainer();
    await tester.pumpWidget(_wrapWithRouter(container,
        initialLocation: '/conversations/conv-1/detail'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除会话'));
    await tester.pumpAndSettle();

    expect(find.text('删除会话?'), findsOneWidget);
    expect(find.text('退出群聊?'), findsNothing);
  });

  testWidgets('dm_user_agent: 渲染 Agent 卡片（名称 + AgentBadge + 在线状态 + bio）',
      (tester) async {
    when(() => api.getConversation('conv-dm'))
        .thenAnswer((_) async => _dmUserAgentConv());

    final container = makeContainer();
    await tester.pumpWidget(_wrapWithRouter(container,
        initialLocation: '/conversations/conv-dm/detail'));
    await tester.pumpAndSettle();

    expect(find.text('万灵助手'), findsOneWidget);
    expect(find.byType(AgentBadge), findsOneWidget);
    expect(find.text('在线'), findsOneWidget);
    expect(find.text('我是你的 AI 助手，有什么可以帮你的吗？'), findsOneWidget);
  });

  testWidgets('dm_user_agent: 渲染「查看 Agent 完整资料」入口',
      (tester) async {
    when(() => api.getConversation('conv-dm'))
        .thenAnswer((_) async => _dmUserAgentConv());

    final container = makeContainer();
    await tester.pumpWidget(_wrapWithRouter(container,
        initialLocation: '/conversations/conv-dm/detail'));
    await tester.pumpAndSettle();

    expect(find.text('查看 Agent 完整资料'), findsOneWidget);
  });

  testWidgets('dm_user_agent: bio 为 null 时不渲染 bio 行', (tester) async {
    when(() => api.getConversation('conv-dm'))
        .thenAnswer((_) async => _dmUserAgentConv(agentBio: null));

    final container = makeContainer();
    await tester.pumpWidget(_wrapWithRouter(container,
        initialLocation: '/conversations/conv-dm/detail'));
    await tester.pumpAndSettle();

    expect(find.text('万灵助手'), findsOneWidget);
    expect(find.textContaining('我是你的 AI 助手'), findsNothing);
  });

  testWidgets('group_user: 群聊分支仍渲染群资料/成员/退群（回归测试）', (tester) async {
    when(() => api.getConversation('conv-group'))
        .thenAnswer((_) async => _groupConv());

    final container = makeContainer();
    await tester.pumpWidget(_wrapWithRouter(container,
        initialLocation: '/conversations/conv-group/detail'));
    await tester.pumpAndSettle();

    expect(find.text('测试群'), findsWidgets);
    expect(find.text('成员 (2)'), findsOneWidget);
    expect(find.text('退出群聊'), findsOneWidget);
  });
}
