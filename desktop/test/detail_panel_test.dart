// desktop/test/detail_panel_test.dart
// Task 7:详情侧栏(信息/变更双 tab + diff 内嵌)。
// 策略:conversationProvider 种子 notifier + chatProvider stub api +
// sessionDiffProvider 种子 notifier(同 T3-T6 override 模式,不发网络),
// 断言面板开合动画 / tab 切换 / 3 文件(1 binary + 1 truncated + 1 正常)
// 列表与状态标记 + patch 展开。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/participant.dart';
import 'package:wanling_core/models/session_diff.dart';
import 'package:wanling_core/models/unread_info.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart';
import 'package:wanling_core/providers/conversation_provider.dart';
import 'package:wanling_core/providers/session_diff_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/services/noop_local_message_store.dart';
import 'package:wanling_core/services/websocket_service.dart';
import 'package:wanling_desktop/pages/messages_page.dart';
import 'package:wanling_desktop/providers/selected_conv_provider.dart';
import 'package:wanling_desktop/widgets/detail_panel.dart';

/// 种子会话:带 agent(供 agentId 解析)+ participants(成员区)+
/// sessionMeta(gitBranch/provider/model/mode)+ directory。
Conversation _conv() => Conversation(
      id: 'c1',
      type: 'agent_session',
      title: 'M2 桌面开发',
      participants: [
        Participant(
          memberId: 'u1',
          memberType: 'user',
          role: 'owner',
          username: 'tester',
          nickname: 'tester',
          avatarUrl: '',
        ),
        Participant(
          memberId: 'agent-1',
          memberType: 'agent',
          role: 'member',
          username: '万灵 Agent',
          nickname: '万灵 Agent',
          avatarUrl: '',
        ),
      ],
      lastMessageContent: const {
        'msg_type': 'text',
        'data': {'text': '最近一条消息'},
      },
      lastMessageAt: DateTime(2026, 1, 1, 10, 30),
      createdAt: DateTime(2026, 1, 1, 9),
      agent: AgentSummary(
        id: 'agent-1',
        name: '万灵 Agent',
        status: AgentStatus.online,
        type: 'hermes',
      ),
      sessionMeta: const SessionMeta(
        mode: 'build',
        modelId: 'glm-5.2',
        providerId: 'zhipu',
        modelName: 'GLM-5.2',
        providerName: '智谱',
        gitBranch: 'develop-v1.5.0',
      ),
      directory: '/home/k/proj',
    );

/// 种子 conversation notifier(autoload=false,直接灌数据)。
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

/// 空会话 stub api:ChatView 挂载后 chatProvider init 走此 stub,无网络。
class _EmptyChatApi extends ApiService {
  _EmptyChatApi() : super(baseUrl: '');

  @override
  Future<Conversation> getConversation(String convId) async => _conv();

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

/// 种子 diff notifier:跳过 load() 网络链,直接灌文件列表。
class _SeededDiffNotifier extends SessionDiffNotifier {
  _SeededDiffNotifier(List<SessionDiffFile> files)
      : super(ApiService(baseUrl: ''),
            agentId: 'agent-1',
            convId: 'c1') {
    state = AsyncValue.data(files);
  }
}

/// 3 文件种子:1 正常 + 1 binary + 1 truncated(session.diff 防护协议)。
List<SessionDiffFile> _diffFiles() => const [
      SessionDiffFile(
        file: 'lib/main.dart',
        patch: '@@ -1,3 +1,4 @@\n class App {\n-旧代码\n+新增导入\n+新增逻辑\n }\n',
        additions: 2,
        deletions: 1,
        status: 'modified',
      ),
      SessionDiffFile(
        file: 'assets/logo.png',
        patch: '',
        additions: 0,
        deletions: 0,
        status: 'added',
        binary: true,
      ),
      SessionDiffFile(
        file: 'logs/big.log',
        patch: '+line1\n+line2\n+line3\n+line4\n+line5\n',
        additions: 5,
        deletions: 0,
        status: 'added',
        truncated: true,
      ),
    ];

List<Override> _overrides() => [
      conversationProvider.overrideWith((ref) => _SeededConvNotifier([_conv()])),
      authProvider.overrideWith((ref) => AuthNotifier(ApiService(baseUrl: ''))),
      chatProvider.overrideWith(
        (ref, key) => ChatNotifier(
          _EmptyChatApi(),
          WebSocketService(),
          key.convId,
          key.agentId,
          'test-user',
        ),
      ),
      sessionDiffProvider.overrideWith(
        (ref, key) => _SeededDiffNotifier(_diffFiles()),
      ),
    ];

/// 选中会话 + 打开详情面板(pumpAndSettle 走完滑入动画)。
/// 卡片化后消息页无左栏列表,选中态直接写 provider(面板行为是测试焦点)。
Future<void> _openPanel(WidgetTester tester, ProviderContainer container) async {
  container.read(selectedConvProvider.notifier).state = 'c1';
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('详情'));
  await tester.pumpAndSettle();
}

/// 桌面默认测试视口 800x600(<1000 走浮层),此 helper 切宽窗走内联布局。
void _setWideSurface(WidgetTester tester, {Size size = const Size(1400, 900)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpPage(WidgetTester tester, ProviderContainer container) =>
    tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        // 卡片化后页面无 Scaffold,Material 祖先由 AppCanvas 的 Scaffold
        // 提供;测试补 Scaffold 对齐生产结构(InkWell 需要 Material)。
        child: const MaterialApp(home: Scaffold(body: MessagesPage())),
      ),
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('宽窗(≥1000):详情 toggle 面板滑入/收起,信息 tab 默认展示会话信息', (tester) async {
    _setWideSurface(tester);
    final container = ProviderContainer(overrides: _overrides());
    addTearDown(container.dispose);
    await _pumpPage(tester, container);
    await tester.pumpAndSettle();

    // 初始:面板不可见
    expect(find.byType(DetailPanel), findsNothing);

    await _openPanel(tester, container);

    // 动画后可见
    expect(find.byType(DetailPanel), findsOneWidget);
    // 信息 tab 默认:会话信息字段(标题在 ChatAppBar/面板两处)
    expect(find.text('M2 桌面开发'), findsNWidgets(2));
    expect(find.textContaining('万灵 Agent'), findsWidgets);
    expect(find.text('工作目录'), findsOneWidget);
    expect(find.text('/home/k/proj'), findsOneWidget);
    expect(find.text('Git 分支'), findsOneWidget);
    expect(find.text('develop-v1.5.0'), findsNWidgets(2)); // AppBar 徽标 + 面板行
    expect(find.text('成员 (2)'), findsOneWidget);

    // 再点「详情」收起,动画后面板不可见
    await tester.tap(find.byTooltip('详情'));
    await tester.pumpAndSettle();
    expect(find.byType(DetailPanel), findsNothing);
  });

  testWidgets('变更 tab:3 文件列表含 binary/truncated 标记,展开正常 patch 着色行', (tester) async {
    _setWideSurface(tester);
    final container = ProviderContainer(overrides: _overrides());
    addTearDown(container.dispose);
    await _pumpPage(tester, container);
    await tester.pumpAndSettle();
    await _openPanel(tester, container);

    // 切到「变更」tab
    await tester.tap(find.text('变更'));
    await tester.pumpAndSettle();

    // 摘要 + 3 文件 + 状态标记
    expect(find.text('3 文件 · +7 −1'), findsOneWidget);
    expect(find.textContaining('lib/main.dart'), findsOneWidget);
    expect(find.textContaining('assets/logo.png'), findsOneWidget);
    expect(find.textContaining('logs/big.log'), findsOneWidget);
    expect(find.text('二进制'), findsOneWidget);
    expect(find.text('已截断'), findsOneWidget);

    // 展开正常文件:等宽 patch 行(hunk 头 + +/- 行)可见
    await tester.tap(find.textContaining('lib/main.dart'));
    await tester.pumpAndSettle();
    expect(find.textContaining('@@ -1,3 +1,4 @@'), findsOneWidget);
    expect(find.textContaining('-旧代码'), findsOneWidget);
    expect(find.textContaining('+新增导入'), findsOneWidget);

    // 展开 binary 文件:显示「二进制文件」占位,不渲染 patch
    await tester.tap(find.textContaining('assets/logo.png'));
    await tester.pumpAndSettle();
    expect(find.text('二进制文件'), findsOneWidget);

    // 展开 truncated 文件:显示「已截断,共 N 行」提示(N=接收行数 5)
    await tester.tap(find.textContaining('logs/big.log'));
    await tester.pumpAndSettle();
    expect(find.text('已截断，共 5 行'), findsOneWidget);
    expect(find.textContaining('+line5'), findsOneWidget);
  });

  testWidgets('信息 ↔ 变更 tab 来回切换,内容保持正确', (tester) async {
    _setWideSurface(tester);
    final container = ProviderContainer(overrides: _overrides());
    addTearDown(container.dispose);
    await _pumpPage(tester, container);
    await tester.pumpAndSettle();
    await _openPanel(tester, container);

    expect(find.text('成员 (2)'), findsOneWidget); // 信息 tab 内容
    await tester.tap(find.text('变更'));
    await tester.pumpAndSettle();
    expect(find.textContaining('assets/logo.png'), findsOneWidget);

    await tester.tap(find.text('信息'));
    await tester.pumpAndSettle();
    expect(find.text('成员 (2)'), findsOneWidget);
    expect(find.textContaining('assets/logo.png'), findsNothing);
  });

  testWidgets('窄窗(<1000):面板以浮层覆盖展示,底层聊天区保留', (tester) async {
    // 默认视口 800x600 即窄窗路径
    final container = ProviderContainer(overrides: _overrides());
    addTearDown(container.dispose);
    await _pumpPage(tester, container);
    await tester.pumpAndSettle();

    await _openPanel(tester, container);

    expect(find.byType(DetailPanel), findsOneWidget);
    // 浮层不销毁底层:ChatView 仍在树上(Stack 覆盖,不是 Row 挤压替换)
    expect(find.byType(Stack), findsWidgets);
    expect(find.text('成员 (2)'), findsOneWidget);

    await tester.tap(find.byTooltip('详情'));
    await tester.pumpAndSettle();
    expect(find.byType(DetailPanel), findsNothing);
  });

  test('SessionDiffFile.fromJson 解析 binary/truncated 防护字段(缺省 false)', () {
    final withFlags = SessionDiffFile.fromJson(const {
      'file': 'a.png',
      'patch': '',
      'additions': 0,
      'deletions': 0,
      'status': 'added',
      'binary': true,
      'truncated': true,
    });
    expect(withFlags.binary, isTrue);
    expect(withFlags.truncated, isTrue);
    expect(withFlags.toJson()['binary'], isTrue); // omitempty:仅 true 时序列化

    final legacy = SessionDiffFile.fromJson(const {
      'file': 'a.go',
      'patch': '@@ -1 +1 @@',
      'additions': 5,
      'deletions': 2,
      'status': 'modified',
    });
    expect(legacy.binary, isFalse);
    expect(legacy.truncated, isFalse);
    expect(legacy.toJson().containsKey('binary'), isFalse);
  });
}
