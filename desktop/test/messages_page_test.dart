// desktop/test/messages_page_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/unread_info.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart';
import 'package:wanling_core/providers/conversation_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/services/noop_local_message_store.dart';
import 'package:wanling_core/services/websocket_service.dart';
import 'package:wanling_desktop/pages/chat/chat_view.dart';
import 'package:wanling_desktop/pages/messages_page.dart';
import 'package:wanling_desktop/providers/no_conversation_hint_provider.dart';
import 'package:wanling_desktop/providers/selected_conv_provider.dart';

/// 构造测试会话。字段按 core Conversation 实际必填参数:
/// id/type/participants/lastMessageContent/lastMessageAt/createdAt。
Conversation _conv(String id, String name, {int unread = 0}) => Conversation(
  id: id,
  type: 'dm_user_agent',
  title: name,
  participants: const [],
  lastMessageContent: const {
    'msg_type': 'text',
    'data': {'text': '最近一条消息'},
  },
  lastMessageAt: DateTime(2026, 1, 1, 10, 30),
  createdAt: DateTime(2026, 1, 1, 9),
  unreadCount: unread,
);

/// 种子 notifier:autoload=false 跳过 load/WS 订阅副作用,直接灌假数据。
/// core 的 conversationProvider 是 StateNotifierProvider,测试用 overrideWith
/// 替换 create(与 app 测试 override apiProvider/wsProvider 同族做法)。
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

/// 空会话 stub api:点击会话后 ChatView 挂载,chatProvider._initialize
/// 走此 stub(无消息),避免测试环境真实网络请求。
class _EmptyChatApi extends ApiService {
  _EmptyChatApi() : super(baseUrl: '');

  @override
  Future<Conversation> getConversation(String convId) async =>
      _conv(convId, '测试会话');

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

List<Override> _overrides(List<Conversation> seed) => [
  conversationProvider.overrideWith((ref) => _SeededConvNotifier(seed)),
  // messages_page 渲染摘要需要 currentUserId(撤回文案),override 掉
  // authProvider 避免拉进 settingsProvider→SharedPreferences 链。
  authProvider.overrideWith((ref) => AuthNotifier(ApiService(baseUrl: ''))),
  // 右侧聊天区:ChatView 挂载后 watch chatProvider,stub 掉网络链。
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

/// 读列表项根 Container 的背景色(null=未选中)。
Color? _itemColor(WidgetTester tester, String convId) =>
    tester.widget<Container>(find.byKey(ValueKey('conv_$convId'))).color;

void main() {
  setUp(() {
    // ChatView 直接 watch settingsProvider(→SharedPreferences),mock 掉插件链。
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('会话列表渲染:多条会话+摘要+未读角标+点击选中高亮', (tester) async {
    final convs = [_conv('c1', 'M2 桌面开发'), _conv('c2', '部署问题', unread: 3)];
    final container = ProviderContainer(overrides: _overrides(convs));
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: MessagesPage()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('M2 桌面开发'), findsOneWidget);
    expect(find.text('部署问题'), findsOneWidget);
    expect(find.text('最近一条消息'), findsNWidgets(2)); // 两条会话的摘要
    expect(find.text('3'), findsOneWidget); // 未读角标
    expect(_itemColor(tester, 'c1'), isNull); // 初始无选中
    expect(_itemColor(tester, 'c2'), isNull);
    expect(container.read(selectedConvProvider), isNull);

    await tester.tap(find.text('部署问题'));
    await tester.pumpAndSettle();

    // 选中态真断言:provider 状态 + 视觉高亮(仅被点项)。
    expect(container.read(selectedConvProvider), 'c2');
    expect(_itemColor(tester, 'c2'), isNotNull);
    expect(_itemColor(tester, 'c1'), isNull);
    // 右侧聊天区接线:选中后 ChatView 挂载(stub api → 空消息占位)。
    expect(find.byType(ChatView), findsOneWidget);
    expect(find.text('暂无消息'), findsOneWidget);
  });

  testWidgets('搜索过滤:输入关键词后仅显示匹配会话', (tester) async {
    final convs = [_conv('c1', 'M2 桌面开发'), _conv('c2', '部署问题')];
    final container = ProviderContainer(overrides: _overrides(convs));
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: MessagesPage()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '部署');
    await tester.pumpAndSettle();

    expect(find.text('部署问题'), findsOneWidget);
    expect(find.text('M2 桌面开发'), findsNothing);
  });

  testWidgets('消息页:空态展示无会话提示,切到会话后清除', (tester) async {
    const hint = '该 Agent 暂无会话，可从消息页发起';
    final convs = [_conv('c1', 'M2 桌面开发'), _conv('c2', '部署问题')];
    final container = ProviderContainer(overrides: [
      ..._overrides(convs),
      noConversationHintProvider.overrideWith((ref) => hint),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: MessagesPage()),
      ),
    );
    await tester.pumpAndSettle();

    // 未选中会话 → 空态展示提示文案。
    expect(find.text('选择一个会话开始聊天'), findsOneWidget);
    expect(find.text(hint), findsOneWidget);

    // 切到具体会话 → 提示被清除且不再展示。
    await tester.tap(find.text('M2 桌面开发'));
    await tester.pumpAndSettle();

    expect(find.text(hint), findsNothing);
    expect(container.read(noConversationHintProvider), isNull);
  });
}
