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
import 'package:wanling_core/providers/agent_sessions_provider.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart';
import 'package:wanling_core/providers/conversation_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/services/noop_local_message_store.dart';
import 'package:wanling_core/services/websocket_service.dart';
import 'package:wanling_desktop/pages/chat/chat_view.dart';
import 'package:wanling_desktop/pages/wanling_page.dart';
import 'package:wanling_desktop/providers/no_conversation_hint_provider.dart';
import 'package:wanling_desktop/providers/selected_conv_provider.dart';

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

/// 种子 agent session 二级列表 notifier(构造即 load,种子同步覆盖)。
class _SeededSessionsNotifier extends AgentSessionsNotifier {
  _SeededSessionsNotifier(List<Conversation> seed, String agentId)
      : super(ApiService(baseUrl: ''), WebSocketService(), 'test-user', agentId) {
    state = seed;
  }
}

/// 已登录 auth 种子(镜像 shell_test 模式)。
class _LoggedInAuth extends AuthNotifier {
  _LoggedInAuth() : super(ApiService(baseUrl: '')) {
    state = AuthState(token: 'test-token');
  }
}

/// 空消息 chat stub:右栏 ChatView 挂载用(镜像 messages_page_test)。
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

Agent _agent(String id, String name, AgentStatus status,
        {String? bio, String type = ''}) =>
    Agent(id: id, name: name, status: status, bio: bio, type: type);

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
  Map<String, List<Conversation>> sessions = const {},
}) =>
    [
      agentListProvider.overrideWith((ref) => _SeededAgentNotifier(agents)),
      conversationProvider.overrideWith((ref) => _SeededConvNotifier(convs)),
      agentSessionsProvider.overrideWith(
        (ref, agentId) =>
            _SeededSessionsNotifier(sessions[agentId] ?? const [], agentId),
      ),
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

Future<void> _pumpPage(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: WanlingPage()),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

    await _pumpPage(tester, container);

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

    // 右栏聊天区空态。
    expect(find.text('选择左侧会话开始聊天'), findsOneWidget);
  });

  testWidgets('万灵页:非 opencode agent 点击右栏直接打开最新会话(不跳 /messages)', (tester) async {
    final agents = [_agent('a1', 'OpenCode 主力', AgentStatus.online)];
    final a1 = AgentSummary(id: 'a1', name: 'OpenCode 主力', status: AgentStatus.online);
    final convs = [
      _conv('conv-old', DateTime(2026, 1, 1), agent: a1),
      _conv('conv-new', DateTime(2026, 1, 2), agent: a1),
    ];
    final container = ProviderContainer(overrides: _overrides(agents: agents, convs: convs));
    addTearDown(container.dispose);

    await _pumpPage(tester, container);

    await tester.tap(find.byKey(const ValueKey('agent_a1')));
    await tester.pumpAndSettle();

    // 选中最新会话(lastMessageAt 最大者),右栏挂 ChatView。
    expect(container.read(selectedConvProvider), 'conv-new');
    expect(container.read(selectedAgentIdProvider), 'a1');
    expect(find.byType(ChatView), findsOneWidget);
  });

  testWidgets('万灵页:非 opencode agent 无会话时右栏空态提示', (tester) async {
    final agents = [_agent('a2', '闲聊助手', AgentStatus.offline)];
    final container = ProviderContainer(overrides: _overrides(agents: agents, convs: []));
    addTearDown(container.dispose);

    await _pumpPage(tester, container);

    await tester.tap(find.byKey(const ValueKey('agent_a2')));
    await tester.pumpAndSettle();

    // 未选中任何会话 → 右栏空态,提示状态被写入并展示。
    expect(container.read(selectedConvProvider), isNull);
    expect(
      container.read(noConversationHintProvider),
      '该 Agent 暂无会话，可从消息页发起',
    );
    expect(find.text('该 Agent 暂无会话，可从消息页发起'), findsOneWidget);
  });

  testWidgets('万灵页:opencode agent 点击进左栏二级 session 列表,点 session 右栏打开聊天', (tester) async {
    final agents = [
      _agent('oc1', 'OpenCode 主力', AgentStatus.online, type: 'opencode'),
    ];
    final sessions = [
      _conv('s1', DateTime(2026, 1, 2)),
      _conv('s2', DateTime(2026, 1, 1)),
    ];
    final container = ProviderContainer(
      overrides: _overrides(agents: agents, convs: [], sessions: {'oc1': sessions}),
    );
    addTearDown(container.dispose);

    await _pumpPage(tester, container);

    // 点击 opencode agent:左栏切二级列表(带返回头),不选会话。
    await tester.tap(find.byKey(const ValueKey('agent_oc1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent_session_s1')), findsOneWidget);
    expect(find.byKey(const ValueKey('agent_session_s2')), findsOneWidget);
    expect(find.byKey(const ValueKey('agent_sessions_back')), findsOneWidget);
    expect(container.read(selectedConvProvider), isNull);

    // 点击 session:选中会话 + agentId 兜底写入,右栏挂 ChatView。
    await tester.tap(find.byKey(const ValueKey('agent_session_s1')));
    await tester.pumpAndSettle();
    expect(container.read(selectedConvProvider), 's1');
    expect(container.read(selectedAgentIdProvider), 'oc1');
    expect(find.byType(ChatView), findsOneWidget);

    // 返回头回到一级列表。
    await tester.tap(find.byKey(const ValueKey('agent_sessions_back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('agent_oc1')), findsOneWidget);
    expect(find.byKey(const ValueKey('agent_session_s1')), findsNothing);
    // 已选会话保留(右栏聊天不丢)。
    expect(container.read(selectedConvProvider), 's1');
  });
}
