// 端到端路由测试：覆盖未登录/已登录 redirect、底部 tab 切换、pin/unpin/长按进编辑页。
//
// 关键 Mock 策略：
// - apiProvider：用 mocktail 的 MockApi，stub getMe/getAgents/getConversations
// - wsProvider：用 FakeWS（test/helpers/fake_ws.dart），避免真实 WS 连接
//   wsProvider 在 auth.isAuthenticated 时会调用 connect()，连真实 WS 会失败/超时；
//   FakeWS.messages 返回空 Stream，conversationProvider 订阅后不会收到任何消息
// - SharedPreferences：用 setMockInitialValues 模拟 token 持久化
//   （pinned tab 用 `nav_pins_{ownerId}` 预种）
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/providers/auth_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;
import 'package:wanling_core/providers/nav_order_provider.dart';
import 'package:wanling_core/providers/saved_logins_provider.dart';
import 'package:app/router.dart';
import 'package:app/widgets/nav_tab_bar.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

/// 测试用 User fixture（避免每处重复构造）。
final _testUser = User(
  id: 'u1',
  username: 'kira',
  avatarUrl: null,
  createdAt: DateTime.utc(2026, 6, 13),
);

/// 多 session agent fixture（pinned 导航场景用）。
/// name 限制 ≤5 字符：NavTabBar 槽位 label 超 5 字符截断加省略号,
/// find.text 按 name 断言/点击时必须用未截断形态。
Agent _multiSessionAgent(String id, String name) => Agent(
      id: id,
      name: name,
      status: AgentStatus.online,
      type: 'opencode',
      multiSession: true,
    );

void main() {
  setUp(() {
    // auth_provider.restoreSession 会调 SecureStorage.getAccessToken,
    // flutter_secure_storage 在 flutter test 环境无原生通道,
    // 不调 setMockInitialValues 会永远挂起导致 pumpAndSettle 死循环。
    FlutterSecureStorage.setMockInitialValues({});
  });

  // mocktail 未 stub 的非空 String getter 会返回 null 触发 type error，
  // 这里给所有 MockApi 实例补一个 baseUrl stub。auth_provider 的 service IPC
  // 调用会读 api.baseUrl。
  void stubBaseUrl(MockApi api) {
    when(() => api.baseUrl).thenReturn('http://test.local');
  }

  group('路由 redirect', () {
    testWidgets('未登录访问任意路由重定向到 /login', (tester) async {
      SharedPreferences.setMockInitialValues({}); // 无 token
      final api = MockApi();
      stubBaseUrl(api);
      final ws = FakeWS();

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        wsProvider.overrideWithValue(ws),
        sharedPrefsProvider
            .overrideWithValue(await SharedPreferences.getInstance()),
      ]);
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).restoreSession();

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (_, ref, _) {
          return MaterialApp.router(routerConfig: ref.watch(routerProvider));
        }),
      ));
      await tester.pumpAndSettle();

      // 应该看到登录页（用户名/密码两个输入框）
      expect(find.byType(TextField), findsWidgets);
    });

    testWidgets('已登录访问 /login 重定向到 /', (tester) async {
      SharedPreferences.setMockInitialValues({'token': 'fake-token'});
      final api = MockApi();
      stubBaseUrl(api);
      final ws = FakeWS();
      when(() => api.getMe()).thenAnswer((_) async => _testUser);
      // 重定向到 / 后首页会构建消息页(MESSAGES load)+底栏派生(agents load)，
      // 故 getConversations + getAgents 都需 stub。
      when(() => api.getConversations()).thenAnswer((_) async => []);
      when(() => api.getAgents()).thenAnswer((_) async => []);

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        wsProvider.overrideWithValue(ws),
        sharedPrefsProvider
            .overrideWithValue(await SharedPreferences.getInstance()),
      ]);
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).restoreSession();

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (_, ref, _) {
          return MaterialApp.router(routerConfig: ref.watch(routerProvider));
        }),
      ));
      await tester.pumpAndSettle();

      // 应该看到 HomePage 的动态底部导航
      expect(find.byType(NavTabBar), findsOneWidget);
      expect(find.text('消息'), findsWidgets);
      expect(find.text('万灵'), findsWidgets);
    });
  });

  group('底部导航切换', () {
    testWidgets('点击 tab 切换分支', (tester) async {
      SharedPreferences.setMockInitialValues({'token': 'fake-token'});
      final api = MockApi();
      stubBaseUrl(api);
      final ws = FakeWS();
      when(() => api.getMe()).thenAnswer((_) async => _testUser);
      // 进入 MessagesPage 会触发 conversationProvider.load；切到 AgentListPage
      // 时 AgentListNotifier 构造函数也会自动 load。stub 二者返回空。
      when(() => api.getAgents()).thenAnswer((_) async => []);
      when(() => api.getConversations()).thenAnswer((_) async => []);

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        wsProvider.overrideWithValue(ws),
        sharedPrefsProvider
            .overrideWithValue(await SharedPreferences.getInstance()),
      ]);
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).restoreSession();

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (_, ref, _) {
          return MaterialApp.router(routerConfig: ref.watch(routerProvider));
        }),
      ));
      await tester.pumpAndSettle();

      // 默认 / (PageView index 0 = 消息 tab)
      expect(find.text('消息'), findsWidgets);

      // 点击 Agent tab
      await tester.tap(find.text('万灵'));
      await tester.pumpAndSettle();
      // 应该看到 Agent 列表页面（空状态显示"暂无 Agent"）
      expect(find.text('暂无 Agent'), findsOneWidget);

      // 点击 消息 回第一个 tab
      await tester.tap(find.text('消息'));
      await tester.pumpAndSettle();
      expect(find.text('暂无 Agent'), findsNothing);
    });

    testWidgets('pinned 2 agent 平铺:槽位渲染 + 点击切换到 sessions 页',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'token': 'fake-token',
        'nav_pins_u1': ['a1', 'a2'],
      });
      final api = MockApi();
      stubBaseUrl(api);
      final ws = FakeWS();
      when(() => api.getMe()).thenAnswer((_) async => _testUser);
      when(() => api.getAgents()).thenAnswer((_) async => [
            _multiSessionAgent('a1', 'dev-1'),
            _multiSessionAgent('a2', 'dsh-1'),
          ]);
      when(() => api.getConversations()).thenAnswer((_) async => []);
      when(() => api.getAgentSessions(any()))
          .thenAnswer((_) async => []);

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        wsProvider.overrideWithValue(ws),
        sharedPrefsProvider
            .overrideWithValue(await SharedPreferences.getInstance()),
      ]);
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).restoreSession();

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (_, ref, _) {
          return MaterialApp.router(routerConfig: ref.watch(routerProvider));
        }),
      ));
      await tester.pumpAndSettle();

      // 底栏:消息/万灵/两个 agent 槽,无更多
      expect(find.byType(NavTabBar), findsOneWidget);
      expect(find.text('dev-1'), findsOneWidget);
      expect(find.text('dsh-1'), findsOneWidget);
      expect(find.text('更多'), findsNothing);

      // 点 agent 槽 → sessions 页空状态
      await tester.tap(find.text('dev-1'));
      await tester.pumpAndSettle();
      expect(find.text('暂无会话'), findsOneWidget);
    });

    testWidgets('pinned 4 agent:出现更多槽,抽屉点选溢出 agent', (tester) async {
      SharedPreferences.setMockInitialValues({
        'token': 'fake-token',
        'nav_pins_u1': ['a1', 'a2', 'a3', 'a4'],
      });
      final api = MockApi();
      stubBaseUrl(api);
      final ws = FakeWS();
      when(() => api.getMe()).thenAnswer((_) async => _testUser);
      when(() => api.getAgents()).thenAnswer((_) async => [
            _multiSessionAgent('a1', 'ag-1'),
            _multiSessionAgent('a2', 'ag-2'),
            _multiSessionAgent('a3', 'ag-3'),
            _multiSessionAgent('a4', 'ag-4'),
          ]);
      when(() => api.getConversations()).thenAnswer((_) async => []);
      when(() => api.getAgentSessions(any())).thenAnswer((_) async => []);

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        wsProvider.overrideWithValue(ws),
        sharedPrefsProvider
            .overrideWithValue(await SharedPreferences.getInstance()),
      ]);
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).restoreSession();

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (_, ref, _) {
          return MaterialApp.router(routerConfig: ref.watch(routerProvider));
        }),
      ));
      await tester.pumpAndSettle();

      // 可见:ag-1/ag-2 + 更多
      expect(find.text('ag-1'), findsOneWidget);
      expect(find.text('ag-2'), findsOneWidget);
      expect(find.text('更多'), findsOneWidget);

      // 点更多 → 抽屉列出溢出 agent
      await tester.tap(find.text('更多'));
      await tester.pumpAndSettle();
      expect(find.text('ag-3'), findsOneWidget);
      expect(find.text('ag-4'), findsOneWidget);

      // 点选 ag-4 → 更多槽激活显示其名
      await tester.tap(find.text('ag-4').last);
      await tester.pumpAndSettle();
      expect(find.text('暂无会话'), findsOneWidget);
      // 更多槽激活态:槽位文案从「更多」换成 ag-4 名。
      // ag-4 同时出现在 sessions AppBar 标题,故底栏断言必须 scoped 到 NavTabBar。
      expect(
          find.descendant(
              of: find.byType(NavTabBar), matching: find.text('ag-4')),
          findsOneWidget);
      expect(
          find.descendant(
              of: find.byType(NavTabBar), matching: find.text('更多')),
          findsNothing);
    });

    testWidgets('unpin 后底栏槽位即时消失且 prefs 持久化', (tester) async {
      SharedPreferences.setMockInitialValues({
        'token': 'fake-token',
        'nav_pins_u1': ['a1', 'a2'],
      });
      final api = MockApi();
      stubBaseUrl(api);
      final ws = FakeWS();
      when(() => api.getMe()).thenAnswer((_) async => _testUser);
      when(() => api.getAgents()).thenAnswer((_) async => [
            _multiSessionAgent('a1', 'ag-1'),
            _multiSessionAgent('a2', 'ag-2'),
          ]);
      when(() => api.getConversations()).thenAnswer((_) async => []);
      when(() => api.getAgentSessions(any())).thenAnswer((_) async => []);

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        wsProvider.overrideWithValue(ws),
        sharedPrefsProvider
            .overrideWithValue(await SharedPreferences.getInstance()),
      ]);
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).restoreSession();

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (_, ref, _) {
          return MaterialApp.router(routerConfig: ref.watch(routerProvider));
        }),
      ));
      await tester.pumpAndSettle();

      final navBar = find.byType(NavTabBar);
      expect(
          find.descendant(of: navBar, matching: find.text('ag-1')),
          findsOneWidget);

      // 进 a1 sessions 页(embedded AppBar 带实心 pin 按钮)
      await tester.tap(find.descendant(of: navBar, matching: find.text('ag-1')));
      await tester.pumpAndSettle();

      // 点 pin(已固定态 tooltip「从导航栏移除」)→ unpin
      await tester.tap(find.byTooltip('从导航栏移除'));
      await tester.pumpAndSettle();

      // 底栏即时收缩:ag-1 槽消失,ag-2 保留;unpin 的是当前正在看的 agent,
      // 身份基守卫判定当前 agent id 已不在列表 → 按设计文档回退消息 tab
      expect(find.descendant(of: navBar, matching: find.text('ag-1')),
          findsNothing);
      expect(find.descendant(of: navBar, matching: find.text('ag-2')),
          findsOneWidget);
      expect(tester.widget<NavTabBar>(navBar).currentIndex, 0);
      // prefs 持久化:SP 列表与 provider state 均已移除 a1(旧 nav_pins key 迁移后保留不动)
      expect(container.read(sharedPrefsProvider).getStringList('nav_order_u1'),
          [kNavTabMsg, kNavTabWanling, 'a2']);
      expect(container.read(navOrderProvider),
          [kNavTabMsg, kNavTabWanling, 'a2']);
    });

    testWidgets('unpin 当前正在看的唯一 pinned agent:不崩溃且回平铺消息页',
        (tester) async {
      // 按设计文档:unpin 正在看的 agent 页 → 回退消息 tab。身份基守卫判定
      // 当前 agent id 已不在收缩后的列表 → jumpToPage(0) 并重置 A 组内部
      // 索引为消息 tab(不再落万灵槽)。
      SharedPreferences.setMockInitialValues({
        'token': 'fake-token',
        'nav_pins_u1': ['a1'],
      });
      final api = MockApi();
      stubBaseUrl(api);
      final ws = FakeWS();
      when(() => api.getMe()).thenAnswer((_) async => _testUser);
      when(() => api.getAgents())
          .thenAnswer((_) async => [_multiSessionAgent('a1', 'ag-1')]);
      when(() => api.getConversations()).thenAnswer((_) async => []);
      when(() => api.getAgentSessions(any())).thenAnswer((_) async => []);

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        wsProvider.overrideWithValue(ws),
        sharedPrefsProvider
            .overrideWithValue(await SharedPreferences.getInstance()),
      ]);
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).restoreSession();

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (_, ref, _) {
          return MaterialApp.router(routerConfig: ref.watch(routerProvider));
        }),
      ));
      await tester.pumpAndSettle();

      final navBar = find.byType(NavTabBar);
      await tester.tap(find.descendant(of: navBar, matching: find.text('ag-1')));
      await tester.pumpAndSettle();
      expect(find.text('暂无会话'), findsOneWidget);

      await tester.tap(find.byTooltip('从导航栏移除'));
      await tester.pumpAndSettle(); // 守卫 jumpToPage(0),不崩溃即通过

      // 落点确定:回平铺消息页(sessions 页卸载),底栏无 agent 槽,
      // 守卫重置激活 tab → 消息(index 0)激活
      expect(find.text('暂无会话'), findsNothing);
      expect(find.descendant(of: navBar, matching: find.text('ag-1')),
          findsNothing);
      expect(tester.widget<NavTabBar>(navBar).currentIndex, 0);
      expect(container.read(navOrderProvider),
          [kNavTabMsg, kNavTabWanling]);
    });

    testWidgets('unpin 前面的 agent:当前 agent 页保持,跳到收缩后的新位置',
        (tester) async {
      // 身份基守卫核心场景:正在看 a2 时移除前面的 a1,a2 仍在列表,
      // 应回落其新位置(page 1)而非被弹回消息 tab。
      SharedPreferences.setMockInitialValues({
        'token': 'fake-token',
        'nav_pins_u1': ['a1', 'a2', 'a3'],
      });
      final api = MockApi();
      stubBaseUrl(api);
      final ws = FakeWS();
      when(() => api.getMe()).thenAnswer((_) async => _testUser);
      when(() => api.getAgents()).thenAnswer((_) async => [
            _multiSessionAgent('a1', 'ag-1'),
            _multiSessionAgent('a2', 'ag-2'),
            _multiSessionAgent('a3', 'ag-3'),
          ]);
      when(() => api.getConversations()).thenAnswer((_) async => []);
      when(() => api.getAgentSessions(any())).thenAnswer((_) async => []);

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        wsProvider.overrideWithValue(ws),
        sharedPrefsProvider
            .overrideWithValue(await SharedPreferences.getInstance()),
      ]);
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).restoreSession();

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (_, ref, _) {
          return MaterialApp.router(routerConfig: ref.watch(routerProvider));
        }),
      ));
      await tester.pumpAndSettle();

      final navBar = find.byType(NavTabBar);
      // 进第 2 个 pinned agent(ag-2,page 2)的 sessions 页
      await tester.tap(find.descendant(of: navBar, matching: find.text('ag-2')));
      await tester.pumpAndSettle();
      expect(find.text('暂无会话'), findsOneWidget);

      // 移除前面的 agent(模拟远端收缩):unpin a1
      container.read(navOrderProvider.notifier).unpin('a1');
      await tester.pumpAndSettle();

      // ag-2 仍在列表:停留其页(收缩后 page 1 → 槽位 2),不回 A 组;
      // 可见页 AppBar 标题为 ag-2(scoped 断言,规避保活页树中的同名文本)
      expect(container.read(navOrderProvider),
          [kNavTabMsg, kNavTabWanling, 'a2', 'a3']);
      expect(find.descendant(of: navBar, matching: find.text('ag-1')),
          findsNothing);
      expect(find.descendant(of: navBar, matching: find.text('ag-2')),
          findsOneWidget);
      expect(tester.widget<NavTabBar>(navBar).currentIndex, 2);
      expect(
          find.descendant(
              of: find.byType(AppBar), matching: find.text('ag-2')),
          findsOneWidget);
    });

    testWidgets('长按 agent 槽进入底栏编辑页', (tester) async {
      SharedPreferences.setMockInitialValues({
        'token': 'fake-token',
        'nav_pins_u1': ['a1', 'a2'],
      });
      final api = MockApi();
      stubBaseUrl(api);
      final ws = FakeWS();
      when(() => api.getMe()).thenAnswer((_) async => _testUser);
      when(() => api.getAgents()).thenAnswer((_) async => [
            _multiSessionAgent('a1', 'ag-1'),
            _multiSessionAgent('a2', 'ag-2'),
          ]);
      when(() => api.getConversations()).thenAnswer((_) async => []);
      when(() => api.getAgentSessions(any())).thenAnswer((_) async => []);

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        wsProvider.overrideWithValue(ws),
        sharedPrefsProvider
            .overrideWithValue(await SharedPreferences.getInstance()),
      ]);
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).restoreSession();

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (_, ref, _) {
          return MaterialApp.router(routerConfig: ref.watch(routerProvider));
        }),
      ));
      await tester.pumpAndSettle();

      // 底栏排序/编辑已收编编辑页:长按任意槽 push /nav-edit
      final navBar = find.byType(NavTabBar);
      await tester.longPress(
          find.descendant(of: navBar, matching: find.text('ag-1')));
      await tester.pumpAndSettle();
      expect(find.text('编辑底栏'), findsOneWidget);
    });

    testWidgets('agent 全前置排序:固定项恒在底栏,可见 agent 截取 2 个', (tester) async {
      // 回归:_visibleSlots 曾用序列前缀截取,agent 全前置时固定 tab 从底栏
      // 双双消失。现约定:固定项恒入栏,可见 agent 按 agents 子序列截取。
      SharedPreferences.setMockInitialValues({
        'token': 'fake-token',
        'nav_order_u1': ['a1', 'a2', 'a3', 'a4', kNavTabMsg, kNavTabWanling],
      });
      final api = MockApi();
      stubBaseUrl(api);
      final ws = FakeWS();
      when(() => api.getMe()).thenAnswer((_) async => _testUser);
      when(() => api.getAgents()).thenAnswer((_) async => [
            _multiSessionAgent('a1', 'ag-1'),
            _multiSessionAgent('a2', 'ag-2'),
            _multiSessionAgent('a3', 'ag-3'),
            _multiSessionAgent('a4', 'ag-4'),
          ]);
      when(() => api.getConversations()).thenAnswer((_) async => []);
      when(() => api.getAgentSessions(any())).thenAnswer((_) async => []);

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
        wsProvider.overrideWithValue(ws),
        sharedPrefsProvider
            .overrideWithValue(await SharedPreferences.getInstance()),
      ]);
      addTearDown(container.dispose);
      await container.read(authProvider.notifier).restoreSession();

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: Consumer(builder: (_, ref, _) {
          return MaterialApp.router(routerConfig: ref.watch(routerProvider));
        }),
      ));
      await tester.pumpAndSettle();

      // 固定项恒在底栏,溢出出更多槽(4 agent ≥ 阈值)
      final navBar = find.byType(NavTabBar);
      expect(
          find.descendant(of: navBar, matching: find.text('消息')),
          findsOneWidget);
      expect(
          find.descendant(of: navBar, matching: find.text('万灵')),
          findsOneWidget);
      expect(find.descendant(of: navBar, matching: find.text('更多')),
          findsOneWidget);
      // 仅前 2 个 agent 可见,溢出的 a3/a4 只在抽屉(不点开不渲染)
      expect(find.descendant(of: navBar, matching: find.text('ag-1')),
          findsOneWidget);
      expect(find.descendant(of: navBar, matching: find.text('ag-2')),
          findsOneWidget);
      expect(find.text('ag-3'), findsNothing);
      expect(find.text('ag-4'), findsNothing);
    });
  });
}
