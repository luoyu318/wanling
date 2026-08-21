// desktop/test/subagent_detail_test.dart
// 子 Agent 详情页 + 路由参数校验测试。
// 策略:真实 routerProvider 挂全壳(镜像 shell_test override 模式),
// apiProvider override 成 _StubApi(getSubagentMessages 内存返回/可抛错),
// wsProvider override 成裸 WebSocketService(不连网),路由 push 进入断言。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart';
import 'package:wanling_core/providers/conversation_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/services/noop_local_message_store.dart';
import 'package:wanling_core/services/websocket_service.dart';
import 'package:wanling_core/utils/secure_storage.dart';
import 'package:wanling_desktop/pages/subagent_detail_page.dart';
import 'package:wanling_desktop/router.dart';
import 'package:wanling_desktop/shell/app_canvas.dart' show windowActionsProvider;
import 'package:wanling_desktop/shell/window_actions.dart';

/// stub ApiService:getSubagentMessages 内存返回(可抛错),记录调用参数。
class _StubApi extends ApiService {
  _StubApi({this.messages = const [], this.error}) : super(baseUrl: '');

  final List<ChatMessage> messages;
  final Object? error;

  /// 调用记录:(conversationId, rootMsgId)。
  final calls = <(String, String)>[];

  @override
  Future<List<ChatMessage>> getSubagentMessages(
    String conversationId,
    String rootMsgId, {
    int limit = 100,
  }) async {
    calls.add((conversationId, rootMsgId));
    if (error != null) throw error!;
    return messages;
  }
}

/// 已登录 auth 种子(镜像 shell_test)。
class _LoggedInAuth extends AuthNotifier {
  _LoggedInAuth() : super(ApiService(baseUrl: '')) {
    state = AuthState(token: 'test-token');
  }
}

/// 空会话种子:autoload=false 跳过 load/WS,防测试发网络。
class _EmptyConvNotifier extends ConversationListNotifier {
  _EmptyConvNotifier()
      : super(
          ApiService(baseUrl: ''),
          WebSocketService(),
          'test-user',
          NoopLocalMessageStore(),
          autoload: false,
        );
}

/// 空 savedLogins 种子(镜像 shell_test)。
class _EmptySavedLogins extends SavedLoginsNotifier {
  _EmptySavedLogins(SharedPreferences prefs)
      : super(
          prefs: prefs,
          storage: SecureStorage(deviceId: 'test'),
          onLogout: ({bool silent = false}) async {},
          onLogin: (u, p) async {},
          onSwitchingChange: (s) {},
        );
}

/// 窗口操作 fake(镜像 shell_test):标题栏系统按钮渲染依赖非 null actions。
class _FakeWindowActions implements WindowActions {
  @override
  Future<void> minimize() async {}
  @override
  Future<void> toggleMaximize() async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> dragWindow() async {}
  @override
  Future<bool> get isMaximized async => false;
  @override
  Stream<void> get onStateChanged => const Stream.empty();
}

ChatMessage _ev(
  String id,
  Map<String, dynamic> content, {
  int minutes = 0,
}) =>
    ChatMessage(
      id: id,
      conversationId: 'conv-1',
      senderType: 'agent',
      senderId: 'agent-1',
      content: content,
      createdAt: DateTime(2026, 1, 1, 10, 30).add(Duration(minutes: minutes)),
    );

const _taskCardId = '11111111-1111-1111-1111-111111111111';
const _convId = '22222222-2222-2222-2222-222222222222';

Future<ProviderContainer> _container(_StubApi api) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [
      authProvider.overrideWith((ref) => _LoggedInAuth()),
      conversationProvider.overrideWith((ref) => _EmptyConvNotifier()),
      savedLoginsProvider.overrideWith((ref) => _EmptySavedLogins(prefs)),
      windowActionsProvider.overrideWithValue(_FakeWindowActions()),
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(WebSocketService()),
    ],
  );
}

Future<void> _pumpAndPush(
  WidgetTester tester,
  ProviderContainer container,
  String location,
) async {
  final router = container.read(routerProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  router.push(location);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('有效参数:push 路由挂载详情页,事件列表渲染 + api 按正确参数拉取', (tester) async {
    final api = _StubApi(messages: [
      _ev('m1', {
        'msg_type': 'tool_card',
        'data': {'name': 'read_file', 'status': 'completed'},
      }),
      _ev('m2', {
        'msg_type': 'reasoning',
        'data': {'text': '用户要求查看配置文件'},
      }, minutes: 1),
      // step_finish 过程态应被过滤,不渲染
      _ev('m3', {
        'msg_type': 'step_finish',
        'data': {'finished': true},
      }, minutes: 2),
    ]);
    final container = await _container(api);
    addTearDown(container.dispose);

    await _pumpAndPush(
      tester,
      container,
      '/chat/subagent/$_taskCardId?convId=$_convId&title=${Uri.encodeComponent('部署任务')}',
    );

    expect(find.byType(SubagentDetailPage), findsOneWidget);
    // 顶栏:标题 + 返回/刷新按钮。
    expect(find.text('部署任务'), findsOneWidget);
    expect(find.byKey(const ValueKey('subagent_back')), findsOneWidget);
    expect(find.byKey(const ValueKey('subagent_refresh')), findsOneWidget);
    // 事件列表:2 个可见事件(类型标签),step_finish 被过滤。
    expect(find.byKey(const ValueKey('subagent_event_list')), findsOneWidget);
    expect(find.text('工具卡'), findsOneWidget);
    expect(find.text('思考'), findsOneWidget);
    expect(find.text('read_file'), findsOneWidget);
    expect(find.text('完成'), findsOneWidget);
    // api 按 (convId, taskCardId) 拉取。
    expect(api.calls, [(_convId, _taskCardId)]);
  });

  testWidgets('非法参数:非 UUID taskCardId 渲染参数错误页,不调 api', (tester) async {
    final api = _StubApi(messages: const []);
    final container = await _container(api);
    addTearDown(container.dispose);

    await _pumpAndPush(
      tester,
      container,
      '/chat/subagent/not-a-uuid?convId=$_convId',
    );

    expect(find.byType(SubagentDetailPage), findsNothing);
    expect(find.byKey(const ValueKey('subagent_param_error')), findsOneWidget);
    expect(find.text('参数错误'), findsOneWidget);
    expect(find.text('链接参数格式错误(需合法 UUID)'), findsOneWidget);
    // fail-fast:校验失败不放行到 api。
    expect(api.calls, isEmpty);
  });

  testWidgets('缺参:无 convId 渲染参数错误页', (tester) async {
    final api = _StubApi(messages: const []);
    final container = await _container(api);
    addTearDown(container.dispose);

    await _pumpAndPush(tester, container, '/chat/subagent/$_taskCardId');

    expect(find.byType(SubagentDetailPage), findsNothing);
    expect(find.byKey(const ValueKey('subagent_param_error')), findsOneWidget);
    expect(find.text('链接缺少必要参数(convId / taskCardId)'), findsOneWidget);
    expect(api.calls, isEmpty);
  });

  testWidgets('加载失败:渲染错误视图,重试再次拉取', (tester) async {
    final api = _StubApi(error: Exception('boom'));
    final container = await _container(api);
    addTearDown(container.dispose);

    await _pumpAndPush(
      tester,
      container,
      '/chat/subagent/$_taskCardId?convId=$_convId',
    );

    expect(find.byType(SubagentDetailPage), findsOneWidget);
    expect(find.byKey(const ValueKey('subagent_error_view')), findsOneWidget);
    expect(find.textContaining('加载失败'), findsOneWidget);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('subagent_error_view')), findsOneWidget);
    expect(api.calls.length, 2);
  });

  testWidgets('空子树:渲染空态文案', (tester) async {
    final api = _StubApi(messages: const []);
    final container = await _container(api);
    addTearDown(container.dispose);

    await _pumpAndPush(
      tester,
      container,
      '/chat/subagent/$_taskCardId?convId=$_convId',
    );

    expect(find.byType(SubagentDetailPage), findsOneWidget);
    expect(find.text('暂无子 Agent 内容'), findsOneWidget);
  });

  testWidgets('返回按钮:pop 回上一页(消息页)', (tester) async {
    final api = _StubApi(messages: const []);
    final container = await _container(api);
    addTearDown(container.dispose);

    await _pumpAndPush(
      tester,
      container,
      '/chat/subagent/$_taskCardId?convId=$_convId',
    );
    expect(find.byType(SubagentDetailPage), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('subagent_back')));
    await tester.pumpAndSettle();
    expect(find.byType(SubagentDetailPage), findsNothing);
    expect(find.text('选择一个会话开始聊天'), findsOneWidget);
  });
}
