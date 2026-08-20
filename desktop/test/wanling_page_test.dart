// desktop/test/wanling_page_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/unread_info.dart';
import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/providers/agent_provider.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart';
import 'package:wanling_core/providers/conversation_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/services/noop_local_message_store.dart';
import 'package:wanling_core/services/websocket_service.dart';
import 'package:wanling_desktop/pages/messages_page.dart';
import 'package:wanling_desktop/pages/wanling_page.dart';
import 'package:wanling_desktop/providers/no_conversation_hint_provider.dart';
import 'package:wanling_desktop/providers/selected_conv_provider.dart';
import 'package:wanling_desktop/router.dart';

/// 种子 agent notifier:autoload=false 跳过 load/WS 订阅,直接灌假数据。
class _SeededAgentNotifier extends AgentListNotifier {
  _SeededAgentNotifier(List<Agent> seed)
      : super(
          ApiService(baseUrl: ''),
          WebSocketService(),
          store: NoopLocalMessageStore(),
          ownerId: 'test-user',
          autoload: false,
        ) {
    state = seed;
  }
}

/// 种子会话 notifier(镜像 messages_page_test 模式)。
class _SeededConvNotifier extends ConversationListNotifier {
  _SeededConvNotifier(List<Conversation> seed)
      : super(
          ApiService(baseUrl: ''),
          WebSocketService(),
          'test-user',
          NoopLocalMessageStore(),
          autoload: false,
        ) {
    state = seed;
  }
}

/// 已登录 auth 种子(镜像 shell_test 模式)。
class _LoggedInAuth extends AuthNotifier {
  _LoggedInAuth() : super(ApiService(baseUrl: '')) {
    state = AuthState(token: 'test-token');
  }
}

/// 空消息 chat stub:跳转 /messages 后 ChatView 挂载用(镜像 messages_page_test)。
class _EmptyChatApi extends ApiService {
  _EmptyChatApi() : super(baseUrl: '');

  @override
  Future<Conversation> getConversation(String convId) async =>
      _conv(convId, DateTime(2026, 1, 1));

  @override
  Future<UnreadInfo> getUnreadInfo(String convId) async =>
      const UnreadInfo(unreadCount: 0);

  @override
  Future<List<ChatMessage>> getMessagesBefore(
    String conversationId, {
    DateTime? before,
    int limit = 20,
  }) async => const [];
}

Agent _agent(String id, String name, AgentStatus status, {String? bio}) =>
    Agent(id: id, name: name, status: status, bio: bio);

Conversation _conv(String id, DateTime at, {AgentSummary? agent}) => Conversation(
      id: id,
      type: 'dm_user_agent',
      participants: const [],
      agent: agent,
      lastMessageContent: const {
        'msg_type': 'text',
        'data': {'text': 'hi'},
      },
      lastMessageAt: at,
      createdAt: at,
    );

List<Override> _overrides({
  required List<Agent> agents,
  required List<Conversation> convs,
}) =>
    [
      agentListProvider.overrideWith((ref) => _SeededAgentNotifier(agents)),
      conversationProvider.overrideWith((ref) => _SeededConvNotifier(convs)),
      authProvider.overrideWith((ref) => _LoggedInAuth()),
      chatProvider.overrideWith(
        (ref, key) => ChatNotifier(
          _EmptyChatApi(),
          WebSocketService(),
          key.convId,
          key.agentId,
          'test-user',
        ),
      ),
    ];

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('万灵页:2 agent 卡片渲染+在线状态徽标', (tester) async {
    final agents = [
      _agent('a1', 'OpenCode 主力', AgentStatus.online, bio: '写代码的'),
      _agent('a2', '闲聊助手', AgentStatus.offline),
    ];
    final container = ProviderContainer(overrides: _overrides(agents: agents, convs: []));
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: WanlingPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('OpenCode 主力'), findsOneWidget);
    expect(find.text('闲聊助手'), findsOneWidget);
    expect(find.text('在线'), findsOneWidget);
    expect(find.text('离线'), findsOneWidget);
    expect(find.text('写代码的'), findsOneWidget);

    // 状态徽标颜色:online 绿点 / offline 灰点(对齐 app 端色值)。
    final onlineDot = tester.widget<Container>(
      find.byKey(const ValueKey('agent_status_dot_a1')),
    );
    final offlineDot = tester.widget<Container>(
      find.byKey(const ValueKey('agent_status_dot_a2')),
    );
    final onlineColor = (onlineDot.decoration as BoxDecoration).color;
    final offlineColor = (offlineDot.decoration as BoxDecoration).color;
    expect(onlineColor, const Color(0xFF07C160));
    expect(offlineColor, const Color(0xFFCCCCCC));
  });

  testWidgets('万灵页:点击 agent 卡片选中该 agent 最新会话并跳 /messages', (tester) async {
    final agents = [_agent('a1', 'OpenCode 主力', AgentStatus.online)];
    final a1 = AgentSummary(id: 'a1', name: 'OpenCode 主力', status: AgentStatus.online);
    final convs = [
      _conv('conv-old', DateTime(2026, 1, 1), agent: a1),
      _conv('conv-new', DateTime(2026, 1, 2), agent: a1),
    ];
    final container = ProviderContainer(overrides: _overrides(agents: agents, convs: convs));
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: container.read(routerProvider)),
      ),
    );
    await tester.pumpAndSettle();
    container.read(routerProvider).go('/wanling');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('agent_a1')));
    await tester.pumpAndSettle();

    // 选中最新会话(lastMessageAt 最大者)。
    expect(container.read(selectedConvProvider), 'conv-new');
    // 路由切到 /messages(消息页挂载 + ChatView 接线)。
    expect(find.byType(MessagesPage), findsOneWidget);
  });

  testWidgets('万灵页:agent 无会话时点击仍跳 /messages 并写入提示', (tester) async {
    final agents = [_agent('a2', '闲聊助手', AgentStatus.offline)];
    final container = ProviderContainer(overrides: _overrides(agents: agents, convs: []));
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(routerConfig: container.read(routerProvider)),
      ),
    );
    await tester.pumpAndSettle();
    container.read(routerProvider).go('/wanling');
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('agent_a2')));
    await tester.pumpAndSettle();

    // 仍切到消息页(不弹「暂无会话」对话框)。
    expect(find.byType(MessagesPage), findsOneWidget);
    expect(find.text('与该万灵暂无会话'), findsNothing);
    // 未选中任何会话 → 消息页空态,提示状态被写入并展示。
    expect(container.read(selectedConvProvider), isNull);
    expect(
      container.read(noConversationHintProvider),
      '该 Agent 暂无会话，可从消息页发起',
    );
    expect(find.text('该 Agent 暂无会话，可从消息页发起'), findsOneWidget);
  });
}
