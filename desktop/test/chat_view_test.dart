// desktop/test/chat_view_test.dart
// Task 5:聊天页消息列表 + 渲染管线接入。
// 策略:chatProvider override + _StubApi 假数据走 ChatNotifier 真实 _initialize
// 路径(与 T3/T4 种子 notifier 同族做法,ChatNotifier 无 autoload 开关,
// 改用 stub ApiService 让 init 干净落地),断言 core 渲染管线产物。
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
import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_core/services/noop_local_message_store.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/services/websocket_service.dart';
import 'package:wanling_core/widgets/image_thumb.dart';
import 'package:wanling_desktop/pages/chat/chat_view.dart';
import 'package:wanling_desktop/providers/detail_panel_provider.dart';

/// stub ApiService:init 路径(getConversation/getUnreadInfo/getMessagesBefore)
/// 全部内存返回,记录 loadMore 的 before 游标供断言。
class _StubApi extends ApiService {
  _StubApi({required this.conv, required this.messages}) : super(baseUrl: '');

  final Conversation conv;
  final List<ChatMessage> messages;
  final List<DateTime?> beforeCursors = [];

  @override
  Future<Conversation> getConversation(String convId) async => conv;

  @override
  Future<UnreadInfo> getUnreadInfo(String convId) async =>
      const UnreadInfo(unreadCount: 0);

  @override
  Future<List<ChatMessage>> getMessagesBefore(
    String conversationId, {
    DateTime? before,
    int limit = 20,
  }) async {
    beforeCursors.add(before);
    return messages;
  }
}

/// 种子 auth:登录态 user(id u1)+token,isMe 判定走真实 senderId 比较。
class _StubAuth extends AuthNotifier {
  _StubAuth() : super(ApiService(baseUrl: '')) {
    state = AuthState(
      user: _user('u1', 'tester'),
      token: 'test-token',
    );
  }

  static User _user(String id, String username) =>
      User(id: id, username: username, createdAt: DateTime(2026, 1, 1));
}

Conversation _conv({SessionMeta? meta}) => Conversation(
      id: 'conv-1',
      type: 'agent_session',
      title: 'M2 测试会话',
      participants: const [],
      lastMessageContent: const {
        'msg_type': 'text',
        'data': {'text': '最近一条'},
      },
      lastMessageAt: DateTime(2026, 1, 1, 10),
      createdAt: DateTime(2026, 1, 1, 9),
      sessionMeta: meta,
    );

ChatMessage _msg(
  String id,
  String senderType,
  Map<String, dynamic> content, {
  int minutesOffset = 0,
}) =>
    ChatMessage(
      id: id,
      conversationId: 'conv-1',
      senderType: senderType,
      senderId: senderType == 'user' ? 'u1' : 'agent-1',
      content: content,
      createdAt: DateTime(2026, 1, 1, 10, 30).add(
        Duration(minutes: minutesOffset),
      ),
    );

ChatMessage _textMsg(String id, String senderType, String text,
        {int minutesOffset = 0}) =>
    _msg(id, senderType, {
      'msg_type': 'text',
      'data': {'text': text},
    }, minutesOffset: minutesOffset);

ChatMessage _imageMsg(String id) => _msg(id, 'agent', {
      'msg_type': 'image',
      'data': {'file_id': 'file-img-1', 'width': 600, 'height': 400},
    }, minutesOffset: 1);

ChatMessage _cardMsg(String id) => _msg(id, 'agent', {
      'msg_type': 'card',
      'data': {
        'approval_id': 'appr-1',
        'card_type': 'command',
        'title': '执行命令确认',
        'preview': 'rm -rf /tmp/x',
        'state': 'approved',
        'decided_action': 'deny',
        'expires_at': '2026-01-01T11:00:00Z',
        'actions': [
          {
            'id': 'allow_once',
            'label': '本次允许',
            'icon': 'check',
            'style': 'primary',
          },
          {'id': 'deny', 'label': '拒绝', 'icon': 'close', 'style': 'danger'},
        ],
      },
    }, minutesOffset: 2);

ProviderContainer _pumpChat(
  WidgetTester tester, {
  required _StubApi api,
}) {
  // 种子 conversationProvider 空列表(防真网络;ChatView 的 agentId 兜底 null)。
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith((ref) => _StubAuth()),
      conversationProvider.overrideWith(
        (ref) => ConversationListNotifier(
          ApiService(baseUrl: ''),
          WebSocketService(),
          'u1',
          NoopLocalMessageStore(),
          autoload: false,
        ),
      ),
      chatProvider.overrideWith(
        (ref, key) => ChatNotifier(
          api,
          WebSocketService(),
          key.convId,
          key.agentId,
          'u1',
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpView(WidgetTester tester, ProviderContainer container) =>
    tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ChatView(convId: 'conv-1'))),
      ),
    );

void main() {
  setUpAll(() {
    // 渲染管线注册:生产在 desktop main.dart,测试环境手动注册。
    registerBuiltinRenderers();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('三条消息(text/image/card)经 core 渲染管线渲染 + gitBranch 徽标 + 详情开关', (tester) async {
    final api = _StubApi(
      conv: _conv(
        meta: const SessionMeta(
          mode: 'build',
          modelId: 'glm-5.2',
          providerId: 'zhipu',
          gitBranch: 'develop-v1.5.0',
        ),
      ),
      // getMessagesBefore 返回 newest-first(DESC),与真实 API 口径一致。
      messages: [_cardMsg('m3'), _imageMsg('m2'), _textMsg('m1', 'user', '你好，万灵')],
    );
    final container = _pumpChat(tester, api: api);
    await _pumpView(tester, container);
    await tester.pumpAndSettle();

    // 标题栏:会话名 + git 分支徽标
    expect(find.text('M2 测试会话'), findsOneWidget);
    expect(find.textContaining('develop-v1.5.0'), findsOneWidget);

    // 三个消息行(text 走 Text、image 走 ImageThumb、card 走 ApprovalCard 标题)
    expect(find.text('你好，万灵'), findsOneWidget);
    expect(find.byType(ImageThumb), findsOneWidget);
    expect(find.text('执行命令确认'), findsOneWidget);

    // 详情开关:初始关,点「详情」后 provider 翻转
    expect(container.read(detailPanelOpenProvider), isFalse);
    await tester.tap(find.byTooltip('详情'));
    await tester.pumpAndSettle();
    expect(container.read(detailPanelOpenProvider), isTrue);
  });

  testWidgets('hasMore 时显示上下文加载按钮,点击带 oldest createdAt 游标调 loadMore', (tester) async {
    // 高视口让 30 条消息不满一屏:加载按钮(列表顶 sliver)无需滚动即可见,
    // 同时贴底 jumpTo 不会触发顶部自动 loadMore(实现有 !_isAtBottom 守卫)。
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 30 条(= ChatNotifier._pageSize)→ init 后 hasMore=true。
    final msgs = List.generate(
      30,
      (i) => _textMsg('m${(i + 1).toString().padLeft(2, '0')}', 'agent', '消息 $i',
          minutesOffset: i),
    );
    final api = _StubApi(conv: _conv(), messages: msgs.reversed.toList());
    final container = _pumpChat(tester, api: api);
    await _pumpView(tester, container);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('load_more')), findsOneWidget);
    expect(api.beforeCursors.length, 1); // 仅 init 拉取,loadMore 未触发
    expect(api.beforeCursors.single, isNull); // init 无 before 游标

    await tester.tap(find.byKey(const ValueKey('load_more')));
    await tester.pumpAndSettle();

    // loadMore 用最老消息 createdAt 作 before 游标(m01 = minutesOffset 0)。
    expect(api.beforeCursors.length, 2);
    expect(
      api.beforeCursors.last,
      DateTime(2026, 1, 1, 10, 30),
    );
  });
}
