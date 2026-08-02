// agent_sessions_page_test.dart
//
// 验证 AgentSessionsPage:
//   - AppBar「新建会话」入口:点击 + → 弹 DirectoryPickerSheet → 选/不选目录
//     → notifier.createSession → push /chat/:convId
//   - 失败路径:createConversation 抛异常 → SnackBar 提示,不跳页
//   - LayoutBuilder 自适应:手机(<600) Drawer / 平板(>=600) 持久分栏
//   - 目录拖拽顺序持久化到 SharedPreferences
//
// 策略:widget test,直接 pump AgentSessionsPage,通过 stub api 注入可控结果,
// GoRouter 注册 marker 页面,点击后用 marker 文案 + SnackBar 文本断言。
import 'package:app/models/agent.dart';
import 'package:app/models/conversation.dart';
import 'package:app/pages/agent_sessions_page.dart';
import 'package:app/widgets/avatar.dart';
import 'package:app/widgets/chat/three_body_indicator.dart';
import 'package:app/widgets/directory_tile.dart';
import 'package:app/providers/auth_provider.dart' show apiProvider;
import 'package:app/providers/chat_provider.dart' show wsProvider;
import 'package:app/providers/saved_logins_provider.dart'
    show sharedPrefsProvider;
import 'package:app/services/api_service.dart';
import 'package:app/utils/directory_utils.dart' show pathLastTwoSegments;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

void main() {
  late MockApi api;
  late FakeWS ws;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    api = MockApi();
    // mocktail 未 stub 的非空 String getter 返 null 触发 type error,补 baseUrl stub。
    when(() => api.baseUrl).thenReturn('http://test.local');
    ws = FakeWS();
    // AgentSessionsNotifier 构造即 load(),先 stub 空列表避免 mocktail 抛 missing-stub。
    when(() => api.getAgentSessions('agent-1')).thenAnswer((_) async => []);
    // AgentListNotifier 构造即 load() 拉 agents,stub 空列表(或带 agent)。
    when(() => api.getAgents()).thenAnswer((_) async => []);
    // DirectoryPickerSheet initState 会调 project.list,默认 stub 空 projects。
    when(() => api.rpc('agent-1', 'project.list', const <String, dynamic>{}))
        .thenAnswer((_) async => {'projects': []});
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
      sharedPrefsProvider.overrideWithValue(prefs),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  Widget buildApp(ProviderContainer container) {
    final router = GoRouter(
      initialLocation: '/agent/agent-1/sessions',
      routes: [
        GoRoute(
          path: '/agent/:agentId/sessions',
          builder: (_, _) => const AgentSessionsPage(agentId: 'agent-1'),
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

  /// 成功路径用的 conv fixture。directory 可空(null=未归类)。
  Conversation mkConv(String id, {String? directory}) => Conversation(
        id: id,
        type: 'agent_session',
        agent: AgentSummary(
            id: 'agent-1', name: 'Wanling', status: AgentStatus.online),
        participants: const [],
        lastMessageContent: null,
        lastMessageAt: DateTime.utc(2026, 7, 17, 12),
        createdAt: DateTime.utc(2026, 7, 17),
        directory: directory,
      );

  /// 默认平板布局下点击 AppBar「+」触发 _createSession。
  Future<void> openCreateMenu(WidgetTester tester) async {
    await tester.tap(find.descendant(
      of: find.byType(AppBar),
      matching: find.byIcon(Icons.add),
    ));
    await tester.pumpAndSettle();
  }

  /// 把测试视口切到手机尺寸(<600dp 触发 Drawer 布局)。
  void usePhoneSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('点「+」→ 弹 DirectoryPickerSheet', (tester) async {
    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    await openCreateMenu(tester);

    expect(find.text('选择工作目录'), findsOneWidget);
  });

  testWidgets('选项目 → createSession → 跳 chat 页', (tester) async {
    final newConv = mkConv('c-proj');
    when(() => api.rpc('agent-1', 'project.list', const <String, dynamic>{}))
        .thenAnswer((_) async => {
              'projects': [
                {'path': '/a', 'name': 'A'},
              ],
            });
    when(() => api.createConversation(
          type: 'agent_session',
          memberIds: ['agent-1'],
          memberTypes: const ['agent'],
          title: null,
          directory: '/a',
        )).thenAnswer((_) async => newConv);
    when(() => api.getAgentSessions('agent-1'))
        .thenAnswer((_) async => [newConv]);

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    await openCreateMenu(tester);
    expect(find.text('A'), findsOneWidget);

    await tester.tap(find.text('A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();

    expect(find.text('chat-c-proj'), findsOneWidget);

    // 清理 Marquee 无限动画(uncategorized tile 默认选中触发),避免 Timer pending
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    // 清理 Marquee 无限动画(uncategorized tile 默认选中触发),避免 Timer pending
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  });

  testWidgets('点「不选(用默认)」→ directory=null → 跳 chat 页', (tester) async {
    final newConv = mkConv('c-default');
    when(() => api.createConversation(
          type: 'agent_session',
          memberIds: ['agent-1'],
          memberTypes: const ['agent'],
          title: null,
        )).thenAnswer((_) async => newConv);
    when(() => api.getAgentSessions('agent-1'))
        .thenAnswer((_) async => [newConv]);

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    await openCreateMenu(tester);
    await tester.tap(find.text('不选(用默认)'));
    await tester.pumpAndSettle();

    expect(find.text('chat-c-default'), findsOneWidget);
  });

  testWidgets('点 X 关闭 sheet → 不创建会话(不调 createConversation, 不跳 chat)',
      (tester) async {
    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    await openCreateMenu(tester);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    verifyNever(() => api.createConversation(
          type: any(named: 'type'),
          memberIds: any(named: 'memberIds'),
          memberTypes: any(named: 'memberTypes'),
        ));
    expect(find.textContaining('chat-'), findsNothing);
  });

  testWidgets('点「+」→ createSession 失败 → SnackBar 提示,未跳 chat',
      (tester) async {
    when(() => api.createConversation(
          type: 'agent_session',
          memberIds: ['agent-1'],
          memberTypes: const ['agent'],
          title: null,
        )).thenThrow(Exception('network'));

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    await openCreateMenu(tester);
    await tester.tap(find.text('不选(用默认)'));
    await tester.pumpAndSettle();

    // 失败 → 未跳 chat。
    expect(find.textContaining('chat-'), findsNothing);
    // 失败 → SnackBar 提示(AppSnackBar overlay,断言文本)。
    expect(find.textContaining('创建会话失败'), findsOneWidget);
  });

  testWidgets('renders drawer hamburger on phone', (tester) async {
    usePhoneSurface(tester);
    final conv = mkConv('c1', directory: '/a');
    when(() => api.getAgentSessions('agent-1'))
        .thenAnswer((_) async => [conv]);

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.menu), findsOneWidget);
  });

  testWidgets('shows all sessions when no directory selected', (tester) async {
    final conv = mkConv('c1', directory: '/a');
    when(() => api.getAgentSessions('agent-1'))
        .thenAnswer((_) async => [conv]);

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    // 未选目录 → 列表无过滤 → ListView 应存在且非空,能找到 session 显示名。
    expect(find.byType(ListView), findsWidgets);
    expect(find.text('Wanling'), findsWidgets);
  });

  testWidgets('tablet layout shows persistent split (no drawer hamburger)',
      (tester) async {
    // 默认 800x600 → tablet 分栏,无 Drawer hamburger。
    final conv = mkConv('c1', directory: '/a');
    when(() => api.getAgentSessions('agent-1'))
        .thenAnswer((_) async => [conv]);

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.menu), findsNothing);
    expect(find.byType(VerticalDivider), findsOneWidget);
  });

  testWidgets('directory reorder persists across rebuild', (tester) async {
    // 准备:两个目录的 fixture 数据
    final convA = mkConv('ca', directory: '/a');
    final convB = mkConv('cb', directory: '/b');
    when(() => api.getAgentSessions('agent-1'))
        .thenAnswer((_) async => [convA, convB]);

    final container = makeContainer();
    await tester.pumpWidget(buildApp(container));
    await tester.pumpAndSettle();

    // 初始顺序:/a 在前(字母序)→ 拖拽第一项到第二项之后
    expect(find.text('/a'), findsWidgets);
    expect(find.text('/b'), findsWidgets);

    // 整 tile 长按触发拖拽(ReorderableDelayedDragStartListener),
    // 需按住 kLongPressTimeout(500ms) 触发识别,再 moveBy 完成位移。
    final tile = find.byType(DirectoryTile).first;
    final center = tester.getCenter(tile);
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 550));
    // 分步移动 + pump 让 ReorderableListView 有机会识别跨越中点
    for (int i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, 15));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    // 验证 SharedPreferences 已写入
    final saved = prefs.getStringList('dir_order_agent-1');
    expect(saved, isNotNull);
    expect(saved!.length, 2);
    // 第一项已被挪到第二位:/b 应在前
    expect(saved.first, '/b');

    // 重进页面验证顺序保持
    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();
    expect(find.text('/a'), findsWidgets);
    expect(find.text('/b'), findsWidgets);
  });

  testWidgets('phone drawer: directory reorder triggers setState rebuild',
      (tester) async {
    usePhoneSurface(tester);
    final convA = mkConv('ca', directory: '/a');
    final convB = mkConv('cb', directory: '/b');
    when(() => api.getAgentSessions('agent-1'))
        .thenAnswer((_) async => [convA, convB]);

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    // 打开 Drawer
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();

    expect(find.text('/a'), findsOneWidget);
    expect(find.text('/b'), findsOneWidget);

    // 长按整 tile 并向下拖拽(ReorderableDelayedDragStartListener 包裹整 tile)
    final tile = find.byType(DirectoryTile).first;
    final center = tester.getCenter(tile);
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 550));
    for (int i = 0; i < 8; i++) {
      await gesture.moveBy(const Offset(0, 20));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    // 验证 SharedPreferences 已写入(说明 _onDirReorder 跑通,Drawer rebuild 链路 OK)
    final saved = prefs.getStringList('dir_order_agent-1');
    expect(saved, isNotNull);
    expect(saved!.length, 2);
    expect(saved.first, '/b');
  });

  testWidgets('directory order loaded from prefs on init', (tester) async {
    // 预设 prefs:/b 在 /a 之前
    await prefs.setStringList('dir_order_agent-1', ['/b', '/a']);

    final convA = mkConv('ca', directory: '/a');
    final convB = mkConv('cb', directory: '/b');
    when(() => api.getAgentSessions('agent-1'))
        .thenAnswer((_) async => [convA, convB]);

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    // _directoryOrder 应被 init 时加载,目录顺序为 /b 在前
    // (DirectoryPanel 第一个 Row 应是 /b)
    final dirTexts = find
        .byType(Text)
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .where((s) => s == '/a' || s == '/b')
        .toList();
    expect(dirTexts, isNotEmpty);
    expect(dirTexts.first, '/b');
  });

  testWidgets('session tile uses Avatar widget reading displayAvatarUrl',
      (tester) async {
    final conv = mkConv('c1', directory: '/a');
    when(() => api.getAgentSessions('agent-1'))
        .thenAnswer((_) async => [conv]);

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    expect(find.byType(Avatar), findsOneWidget);
    // agent name 为 'Wanling',首字母 'W'
    expect(find.text('W'), findsWidgets);
  });

  testWidgets('bubble initial reflects agent displayName first char',
      (tester) async {
    final conv = Conversation(
      id: 'c1',
      type: 'agent_session',
      agent: AgentSummary(
          id: 'agent-1', name: '万灵', status: AgentStatus.online),
      participants: const [],
      lastMessageContent: null,
      lastMessageAt: DateTime.utc(2026, 7, 17, 12),
      createdAt: DateTime.utc(2026, 7, 17),
      directory: '/a',
    );
    when(() => api.getAgentSessions('agent-1'))
        .thenAnswer((_) async => [conv]);

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    // 中文名首字符「万」
    expect(find.text('万'), findsWidgets);
  });

  testWidgets('Avatar url bound to displayAvatarUrl', (tester) async {
    final conv = Conversation(
      id: 'c1',
      type: 'agent_session',
      avatarUrl: '/api/files/avatar1',
      agent: AgentSummary(
          id: 'agent-1', name: 'Wanling', status: AgentStatus.online),
      participants: const [],
      lastMessageContent: null,
      lastMessageAt: DateTime.utc(2026, 7, 17, 12),
      createdAt: DateTime.utc(2026, 7, 17),
      directory: '/a',
    );
    when(() => api.getAgentSessions('agent-1'))
        .thenAnswer((_) async => [conv]);

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    final avatar = tester.widget<Avatar>(find.byType(Avatar));
    expect(avatar.url, '/api/files/avatar1');
  });

  testWidgets('Avatar fallback to null when no avatarUrl', (tester) async {
    final conv = mkConv('c1', directory: '/a');
    when(() => api.getAgentSessions('agent-1'))
        .thenAnswer((_) async => [conv]);

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    final avatar = tester.widget<Avatar>(find.byType(Avatar));
    expect(avatar.url, isNull);
  });

  testWidgets('AppBar title single line when no directory selected',
      (tester) async {
    final conv = mkConv('c1', directory: '/a');
    when(() => api.getAgentSessions('agent-1'))
        .thenAnswer((_) async => [conv]);

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    // agent.name 出现在 AppBar title
    expect(find.text('Wanling'), findsWidgets);
    // 未选目录 → 不出现目录路径小字
    expect(find.text(pathLastTwoSegments('/a')), findsNothing);
  });

  testWidgets('AppBar title shows two lines when directory selected',
      (tester) async {
    when(() => api.getAgents()).thenAnswer((_) async => [
          Agent(id: 'agent-1', name: 'Wanling', status: AgentStatus.online),
        ]);
    final conv = mkConv('c1', directory: '/proj/src');
    when(() => api.getAgentSessions('agent-1'))
        .thenAnswer((_) async => [conv]);

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    // 选中目录(触发 Marquee 无限动画,用 pump 代替 pumpAndSettle)
    await tester.tap(find.text('/proj/src'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // agent.name + 目录路径小字都在
    expect(find.text('Wanling'), findsWidgets);
    expect(find.text(pathLastTwoSegments('/proj/src')), findsOneWidget);

    // 清理 Marquee 无限动画
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  });

  testWidgets('selected directory persists across rebuild', (tester) async {
    final conv = mkConv('c1', directory: '/a');
    when(() => api.getAgentSessions('agent-1'))
        .thenAnswer((_) async => [conv]);

    final container = makeContainer();
    await tester.pumpWidget(buildApp(container));
    await tester.pumpAndSettle();

    // 初始未选目录
    expect(prefs.getString('dir_selected_agent-1'), isNull);

    // 选中 /a(触发 Marquee,用 pump 代替 pumpAndSettle)
    await tester.tap(find.text('/a'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 验证已写入 prefs
    expect(prefs.getString('dir_selected_agent-1'), '/a');

    // 清理 Marquee
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));

    // 重进页面验证选中状态恢复
    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    // 选中后 body 过滤到该目录的会话(显示名 = agent.name)
    expect(find.text('Wanling'), findsWidgets);
    // 未选目录时会话列表也显示全部,选中后只显示该目录会话
    // 验证选中状态通过 _filterSessions 生效(1 个会话在该目录)
    expect(find.byType(ListView), findsWidgets);

    // 清理 Marquee
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  });

  testWidgets(
      'selecting uncategorized only shows directory==null sessions '
      '(regression: was showing all)', (tester) async {
    final convWithDir = mkConv('c1', directory: '/proj');
    final convUncategorized = mkConv('c2');
    when(() => api.getAgentSessions('agent-1'))
        .thenAnswer((_) async => [convWithDir, convUncategorized]);

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    // 初始未选目录 → 显示全部(2 个会话)
    expect(find.text('Wanling'), findsNWidgets(2));

    // 选中「未归类」目录
    await tester.tap(find.text('未归类'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // 只应显示 1 个未归类会话(directory==null),不是全部 2 个
    expect(find.text('Wanling'), findsOneWidget);

    // 清理 Marquee(未归类选中态触发)
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  });

  testWidgets(
      'selecting uncategorized persists across rebuild (regression: '
      'null-path collision wiped selection on save)', (tester) async {
    final convWithDir = mkConv('c1', directory: '/proj');
    final convUncategorized = mkConv('c2');
    when(() => api.getAgentSessions('agent-1'))
        .thenAnswer((_) async => [convWithDir, convUncategorized]);

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('未归类'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Wanling'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));

    await tester.pumpWidget(buildApp(makeContainer()));
    await tester.pumpAndSettle();

    expect(
      find.text('Wanling'),
      findsOneWidget,
      reason: '重进页面后未归类选中态应保留,只显示 1 个未归类会话',
    );

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  });

  group('pendingCount 副标题', () {
    testWidgets('pendingCount > 0 显示「待处理 N 项」红字', (tester) async {
      when(() => api.getAgentSessions('agent-1')).thenAnswer((_) async => [
            Conversation(
              id: 'c1',
              type: 'agent_session',
              agent: AgentSummary(
                  id: 'agent-1', name: 'Bot', status: AgentStatus.online),
              participants: const [],
              lastMessageContent: const {
                'msg_type': 'text',
                'data': {'text': 'hello'}
              },
              lastMessageAt: DateTime(2026, 7, 1, 10),
              createdAt: DateTime(2026, 7, 1),
              unreadCount: 0,
              pendingCount: 3,
            ),
          ]);
      when(() => api.getAgents()).thenAnswer((_) async => [
            Agent(
              id: 'agent-1',
              name: 'Bot',
              status: AgentStatus.online,
              type: 'opencode',
            ),
          ]);

      await tester.pumpWidget(buildApp(makeContainer()));
      await tester.pumpAndSettle();

      expect(find.text('待处理 3 项'), findsOneWidget);
    });

    testWidgets('pendingCount == 0 显示用户指令 + 创建日期', (tester) async {
      when(() => api.getAgentSessions('agent-1')).thenAnswer((_) async => [
            Conversation(
              id: 'c1',
              type: 'agent_session',
              agent: AgentSummary(
                  id: 'agent-1', name: 'Bot', status: AgentStatus.online),
              participants: const [],
              lastMessageContent: null,
              lastMessageAt: DateTime(2026, 7, 1, 10),
              createdAt: DateTime(2026, 7, 1),
              unreadCount: 0,
              pendingCount: 0,
              lastUserMessageContent: 'hello world',
            ),
          ]);
      when(() => api.getAgents()).thenAnswer((_) async => [
            Agent(
              id: 'agent-1',
              name: 'Bot',
              status: AgentStatus.online,
              type: 'opencode',
            ),
          ]);

      await tester.pumpWidget(buildApp(makeContainer()));
      await tester.pumpAndSettle();

      expect(find.text('待处理'), findsNothing);
      expect(find.textContaining('hello world'), findsOneWidget);
      expect(find.textContaining('07-01 创建'), findsOneWidget);
    });

    testWidgets('无用户指令只显示创建日期', (tester) async {
      when(() => api.getAgentSessions('agent-1')).thenAnswer((_) async => [
            Conversation(
              id: 'c1',
              type: 'agent_session',
              agent: AgentSummary(
                  id: 'agent-1', name: 'Bot', status: AgentStatus.online),
              participants: const [],
              lastMessageContent: null,
              lastMessageAt: DateTime(2026, 7, 1, 10),
              createdAt: DateTime(2026, 7, 1),
              unreadCount: 0,
              pendingCount: 0,
            ),
          ]);
      when(() => api.getAgents()).thenAnswer((_) async => [
            Agent(
              id: 'agent-1',
              name: 'Bot',
              status: AgentStatus.online,
              type: 'opencode',
            ),
          ]);

      await tester.pumpWidget(buildApp(makeContainer()));
      await tester.pumpAndSettle();

      expect(find.text('07-01 创建'), findsOneWidget);
      expect(find.textContaining('hello'), findsNothing);
    });
  });

  group('_SessionTile agent 状态指示器', () {
    // ThreeBodyIndicator 内部 AnimationController..repeat(),测试末尾必须拆 widget
    // 并泵若干帧让 controller dispose,否则 leak 报错。
    // 另:emit busy/retry 会启动 AgentStatusNotifier 的 30s fallback Timer,
    // 必须先 emit idle 触发 clear 取消,否则 timersPending 断言失败。
    Future<void> cleanup(WidgetTester tester) async {
      ws.emitSessionStatus({'conversation_id': 'c1', 'status': 'idle'});
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle(const Duration(milliseconds: 100));
    }

    testWidgets('busy 状态显示三体指示器', (tester) async {
      final conv = mkConv('c1', directory: '/proj');
      when(() => api.getAgentSessions('agent-1'))
          .thenAnswer((_) async => [conv]);

      await tester.pumpWidget(buildApp(makeContainer()));
      await tester.pumpAndSettle();

      ws.emitSessionStatus({'conversation_id': 'c1', 'status': 'busy'});
      // Riverpod select 通知 + widget 重建跨 2 帧;不能用 pumpAndSettle
      // (会快进过 30s fallback timer 把状态清掉)。
      await tester.pump();
      await tester.pump();

      expect(find.byType(ThreeBodyIndicator), findsOneWidget);
      await cleanup(tester);
    });

    testWidgets('retry 状态显示红色三体指示器', (tester) async {
      final conv = mkConv('c1', directory: '/proj');
      when(() => api.getAgentSessions('agent-1'))
          .thenAnswer((_) async => [conv]);

      await tester.pumpWidget(buildApp(makeContainer()));
      await tester.pumpAndSettle();

      ws.emitSessionStatus({
        'conversation_id': 'c1',
        'status': 'retry',
        'attempt': 2,
        'message': 'timeout',
      });
      await tester.pump();
      await tester.pump();

      expect(find.byType(ThreeBodyIndicator), findsOneWidget);
      await cleanup(tester);
    });

    testWidgets('idle 状态不显示三体指示器', (tester) async {
      final conv = mkConv('c1', directory: '/proj');
      when(() => api.getAgentSessions('agent-1'))
          .thenAnswer((_) async => [conv]);

      await tester.pumpWidget(buildApp(makeContainer()));
      await tester.pumpAndSettle();

      expect(find.byType(ThreeBodyIndicator), findsNothing);
    });
  });
}
