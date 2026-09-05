// MiniProgramHost 全局保活层 widget 测试:
// 1. 无实例只渲染 child
// 2. open 后替身视图挂载且前台 Offstage(false)
// 3. minimize 后 Offstage(true) 且视图仍在树上(保活),浮球出现
// 4. 多实例:后台 Offstage(true),前台 Offstage(false)
// 5. close 后实例视图从树上消失
// 6. 上滑关闭最后一个实例:任务视图自动关闭(不悬在空列表上)
// 7. 宿主回调联动 live 壳路由:上滑关闭弹壳 / 点卡片恢复压回
// 8. 最小化前抓 WebView 快照:registry 有 controller → 帧写入实例;
//    抓帧抛异常 → 最小化照常完成不崩(fail-safe)
//
// Mock 策略:manager 用真实例(纯状态);routerProvider 覆盖为真实 GoRouter
// (带 /mini-program-live/:appid 壳路由);WebView 不触平台通道——
// instanceViewBuilder 注入替身视图 Text('mp-<appid>')。
// 注:skipOffstage=false 断言「是否仍在树上」(保活视图默认 finder 会跳过)。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:app/pages/mini_program_launch_page.dart';
import 'package:app/pages/mini_program_page.dart';
import 'package:app/providers/mini_program_manager_provider.dart';
import 'package:app/router.dart' show routerProvider;
import 'package:app/services/mini_program_launcher.dart';
import 'package:app/services/mini_program_manager.dart';
import 'package:app/services/mini_program_snapshot.dart';
import 'package:app/widgets/mini_program_float_ball.dart';
import 'package:app/widgets/mini_program_host.dart';
import 'package:app/widgets/mini_program_task_view.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider, authProvider;
import 'package:wanling_core/providers/mini_programs_provider.dart';
import 'package:wanling_core/services/api_service.dart';

/// I1 联动测试用 Mock API(restoreSession 建登录态 / logout 清理)
class _MockApi extends Mock implements ApiService {}

final _testUser = User(
  id: 'u1',
  username: 'kira',
  avatarUrl: null,
  createdAt: DateTime.utc(2026, 6, 13),
);

/// 有状态替身视图:initState 计数,验证 keep-alive(元素树不被 diff 重建)。
class _StubView extends StatefulWidget {
  const _StubView({super.key, required this.appid});

  final String appid;

  @override
  State<_StubView> createState() => _StubViewState();
}

class _StubViewState extends State<_StubView> {
  int initCount = 0;

  @override
  void initState() {
    super.initState();
    initCount++;
  }

  @override
  Widget build(BuildContext context) => Text('mp-${widget.appid}');
}

/// 测试脚手架:真实 manager + 最小真实路由(含 live 壳) + Host 接线
/// (与 main.dart 的 MaterialApp.builder 同构,替身视图替代 WebView)。
class _Harness {
  final MiniProgramManager manager = MiniProgramManager();
  late final GoRouter router;
  late final ProviderContainer container;

  Future<void> pump(
    WidgetTester tester, {
    bool useRealEmbeddedPage = false,
    Widget Function(BuildContext, MiniProgramInstance)? instanceViewBuilder,
    List<Override> overrides = const [],
  }) async {
    router = GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) =>
              const Scaffold(body: Text('home-body')),
        ),
        GoRoute(
          path: '/mini-program-live/:appid',
          pageBuilder: (context, state) => NoTransitionPage<void>(
            key: state.pageKey,
            child: const MiniProgramLiveShellPage(),
          ),
        ),
      ],
    );
    // riverpod 2.6 的 ChangeNotifierProvider 无 overrideWithValue,用 overrideWith 注入预建实例
    container = ProviderContainer(overrides: [
      miniProgramManagerProvider.overrideWith((ref) => manager),
      routerProvider.overrideWithValue(router),
      // 真实 embedded 页用:小程序列表返空 → 页渲染「不存在」静态文案,
      // 不触 WebView 平台通道,也不会有 loading 态无限动画干扰 pumpAndSettle
      miniProgramsProvider.overrideWith((ref) async => const []),
      ...overrides,
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => MiniProgramHost(
          // 替身视图:替代真实 MiniProgramPage(WebView 需平台通道,测试不可用)
          instanceViewBuilder: useRealEmbeddedPage
              ? null
              : instanceViewBuilder ??
                  (context, inst) => Text('mp-${inst.appid}'),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ));
    // 先 pump 两帧让 FutureProvider 的 loading 微任务落地(loading 态的
    // 无限旋转动画会让 pumpAndSettle 挂起),再 settle
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
  }
}

/// 实例视图的 Offstage(skipOffstage=false:保活中的后台视图默认 finder 会跳过)
Offstage _offstageOf(WidgetTester tester, String appid) =>
    tester.widget<Offstage>(find.ancestor(
      of: find.text('mp-$appid', skipOffstage: false),
      matching: find.byType(Offstage),
    ));

/// 视图是否仍在树上(含 Offstage 保活态)
bool _mountedOnTree(WidgetTester tester, String appid) => find
    .text('mp-$appid', skipOffstage: false)
    .evaluate()
    .isNotEmpty;

void main() {
  setUp(() {
    // launcher 的 live 壳占位是模块级状态,用例间复位
    resetLauncherForTest();
    // Host initState 的 authProvider 监听会实例化 auth/api/settings provider 链,
    // settingsProvider.load() 读 SharedPreferences,测试环境需 mock
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  testWidgets('无实例:只渲染 child,无浮球/任务视图', (tester) async {
    final h = _Harness();
    await h.pump(tester);

    expect(find.text('home-body'), findsOneWidget);
    expect(_mountedOnTree(tester, 'a'), isFalse);
    expect(find.byType(MiniProgramFloatBall), findsNothing);
    expect(find.byType(MiniProgramTaskView), findsNothing);
  });

  testWidgets('open 后替身视图挂载,前台 Offstage(false)', (tester) async {
    final h = _Harness();
    await h.pump(tester);

    h.manager.open('a');
    await tester.pumpAndSettle();

    expect(find.text('mp-a'), findsOneWidget);
    expect(_offstageOf(tester, 'a').offstage, isFalse);
  });

  testWidgets('minimize 后视图保活(Offstage true)且浮球出现', (tester) async {
    final h = _Harness();
    await h.pump(tester);

    h.manager.open('a');
    await tester.pumpAndSettle();
    h.manager.minimize();
    await tester.pumpAndSettle();

    // 仍在树上 = 保活;只是不可见
    expect(_mountedOnTree(tester, 'a'), isTrue);
    expect(_offstageOf(tester, 'a').offstage, isTrue);
    expect(find.byType(MiniProgramFloatBall), findsOneWidget);
    expect(find.byType(MiniProgramTaskView), findsNothing);
  });

  testWidgets('多实例:后台 Offstage(true),前台 Offstage(false)', (tester) async {
    final h = _Harness();
    await h.pump(tester);

    h.manager.open('a');
    h.manager.open('b'); // b 前台
    await tester.pumpAndSettle();

    expect(_mountedOnTree(tester, 'a'), isTrue);
    expect(_mountedOnTree(tester, 'b'), isTrue);
    expect(_offstageOf(tester, 'a').offstage, isTrue);
    expect(_offstageOf(tester, 'b').offstage, isFalse);
  });

  testWidgets('close 后实例视图从树上消失', (tester) async {
    final h = _Harness();
    await h.pump(tester);

    h.manager.open('a');
    await tester.pumpAndSettle();
    expect(find.text('mp-a'), findsOneWidget);

    h.manager.close('a');
    await tester.pumpAndSettle();

    // skipOffstage=false:连 Offstage 保活形态都不在树上(彻底销毁)
    expect(_mountedOnTree(tester, 'a'), isFalse);
    expect(find.byType(MiniProgramFloatBall), findsNothing);
  });

  testWidgets('上滑关闭最后一个实例:任务视图自动关闭,不悬在空列表上', (tester) async {
    final h = _Harness();
    await h.pump(tester);

    h.manager.open('a');
    await tester.pumpAndSettle();
    h.manager.minimize();
    await tester.pumpAndSettle();

    await tester.tap(find.byType(MiniProgramFloatBall));
    await tester.pumpAndSettle();
    expect(find.byType(MiniProgramTaskView), findsOneWidget);

    await tester.drag(
        find.byKey(const ValueKey('dismiss-a')), const Offset(0, -400));
    await tester.pumpAndSettle();

    expect(find.byType(MiniProgramTaskView), findsNothing);
    expect(_mountedOnTree(tester, 'a'), isFalse);
    expect(find.byType(MiniProgramFloatBall), findsNothing);
  });

  testWidgets('宿主回调联动 live 壳路由:上滑关闭弹壳,点卡片恢复压回', (tester) async {
    final h = _Harness();
    await h.pump(tester);

    // open a、b:launcher 压壳一次,前台 b
    openMiniProgramWith(h.container, 'a');
    openMiniProgramWith(h.container, 'b');
    await tester.pumpAndSettle();
    expect(find.byType(MiniProgramLiveShellPage), findsOneWidget);

    // 直驱最小化(替身视图无法触达 _minimize;壳残余态与双入口兜底场景同构)
    h.manager.minimize();
    await tester.pumpAndSettle();

    await tester.tap(find.byType(MiniProgramFloatBall));
    await tester.pumpAndSettle();
    expect(find.byType(MiniProgramTaskView), findsOneWidget);

    // 上滑关 'b' → host._close → sync 弹壳(无前台 + 壳在栈)。
    // 注:list 按打开时间倒序 [b, a],'b' 是第 0 页(屏内),'a' 在屏外页不可拖。
    await tester.drag(
        find.byKey(const ValueKey('dismiss-b')), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(find.byType(MiniProgramLiveShellPage), findsNothing);

    // 点卡片 'a' 恢复 → host.onRestore → sync 重新压壳
    await tester.tap(find.byKey(const ValueKey('mp-task-card-a')));
    await tester.pumpAndSettle();
    expect(find.byType(MiniProgramLiveShellPage), findsOneWidget);
    // 任务视图已关,前台 a 视图可见
    expect(find.byType(MiniProgramTaskView), findsNothing);
    expect(find.text('mp-a'), findsOneWidget);
    expect(_offstageOf(tester, 'a').offstage, isFalse);
  });

  testWidgets('先开 a 后开 b:a 的实例状态不重建(Offstage 按 appid 键控)', (tester) async {
    final h = _Harness();
    await h.pump(
      tester,
      instanceViewBuilder: (context, inst) => _StubView(
        key: ValueKey('stub-${inst.appid}'),
        appid: inst.appid,
      ),
    );

    h.manager.open('a');
    await tester.pumpAndSettle();
    _StubViewState stateOf(String appid) => tester.state<_StubViewState>(
        find.byKey(ValueKey('stub-$appid'), skipOffstage: false));
    final aStateBefore = stateOf('a');
    expect(aStateBefore.initCount, 1);
    h.manager.open('b'); // 前插,list 从 [a] 变 [b, a],a 槽位后移
    await tester.pumpAndSettle();

    // 无 key 时槽位被 b 原位复用,a 子树重建:新 State 也是 initCount=1,
    // 必须用跨前后的 State 同一性判别
    expect(identical(stateOf('a'), aStateBefore), isTrue);

    h.manager.close('b'); // a 从槽位 0 移除,位移回头部
    await tester.pumpAndSettle();

    expect(stateOf('a').initCount, 1);
    expect(identical(stateOf('a'), aStateBefore), isTrue);
  });

  testWidgets('embedded 回调接线:onMinimize 保最小化,onClose 销毁(壳路由随动)', (tester) async {
    // 真实 embedded 页(列表返空 → 「不存在」静态文案),不经替身,
    // 从树上捕获页配置直接调回调——onMinimize/onClose 参数交换会被区分
    final h = _Harness();
    await h.pump(tester, useRealEmbeddedPage: true);

    openMiniProgramWith(h.container, 'a');
    await tester.pumpAndSettle();
    expect(find.byType(MiniProgramLiveShellPage), findsOneWidget);

    final page = tester.widget<MiniProgramPage>(find.byType(MiniProgramPage));

    // 页内最小化(浮窗/入口页返回/openPage home 同一回调)
    page.onMinimize!();
    await tester.pumpAndSettle();
    expect(h.manager.foregroundAppid, isNull);
    expect(h.manager.instances.containsKey('a'), isTrue); // minimize 保留实例
    expect(find.byType(MiniProgramLiveShellPage), findsNothing); // minimize→弹壳

    // 恢复走宿主 TaskView 链路:浮球 → 点卡片 onRestore(壳压回)
    await tester.tap(find.byType(MiniProgramFloatBall));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mp-task-card-a')));
    await tester.pumpAndSettle();
    expect(h.manager.foregroundAppid, 'a');
    expect(find.byType(MiniProgramLiveShellPage), findsOneWidget);

    // 页内关闭(胶囊 ◉ / JS wanlingClose 同一回调)
    page.onClose!();
    await tester.pumpAndSettle();
    expect(h.manager.instances.containsKey('a'), isFalse); // close 销毁实例
    expect(find.byType(MiniProgramLiveShellPage), findsNothing);
  });

  testWidgets('logout/切账号 → closeAll 清空保活实例,浮球/任务视图消失(I1)',
      (tester) async {
    SharedPreferences.setMockInitialValues({'token': 'fake-token'});
    final api = _MockApi();
    when(() => api.baseUrl).thenReturn('http://test.local');
    when(() => api.getMe()).thenAnswer((_) async => _testUser);
    when(() => api.logout()).thenAnswer((_) async {});
    final h = _Harness();
    await h.pump(tester, overrides: [apiProvider.overrideWithValue(api)]);

    // 建立登录态(restoreSession 走真实 auth notifier,Mock API 供数据)
    await h.container.read(authProvider.notifier).restoreSession();
    expect(h.container.read(authProvider).isAuthenticated, isTrue);

    // 保活实例 a 最小化挂后台,浮球出现
    openMiniProgramWith(h.container, 'a');
    h.manager.minimize();
    await tester.pumpAndSettle();
    expect(find.byType(MiniProgramFloatBall), findsOneWidget);

    // 登出(手动登出/401 踢出/切换账号的 logout 段同一状态流转)
    await h.container.read(authProvider.notifier).logout();
    await tester.pumpAndSettle();

    // 修复前:实例残留,前台 WebView 盖住登录页;重登后旧实例直接恢复
    expect(h.container.read(miniProgramManagerProvider).list, isEmpty);
    expect(find.byType(MiniProgramFloatBall), findsNothing);
    expect(_mountedOnTree(tester, 'a'), isFalse);
  });

  testWidgets('logout 时任务视图展开中 → 一并收起,不悬在空列表上(I1)',
      (tester) async {
    SharedPreferences.setMockInitialValues({'token': 'fake-token'});
    final api = _MockApi();
    when(() => api.baseUrl).thenReturn('http://test.local');
    when(() => api.getMe()).thenAnswer((_) async => _testUser);
    when(() => api.logout()).thenAnswer((_) async {});
    final h = _Harness();
    await h.pump(tester, overrides: [apiProvider.overrideWithValue(api)]);
    await h.container.read(authProvider.notifier).restoreSession();

    openMiniProgramWith(h.container, 'a');
    h.manager.minimize();
    await tester.pumpAndSettle();
    // 展开任务视图
    await tester.tap(find.byType(MiniProgramFloatBall));
    await tester.pumpAndSettle();
    expect(find.byType(MiniProgramTaskView), findsOneWidget);

    await h.container.read(authProvider.notifier).logout();
    await tester.pumpAndSettle();

    expect(find.byType(MiniProgramTaskView), findsNothing);
    expect(h.container.read(miniProgramManagerProvider).list, isEmpty);
  });

  testWidgets('参数变化重开 → 实例销毁重建,嵌入视图整棵换新(I2)', (tester) async {
    final h = _Harness();
    await h.pump(
      tester,
      instanceViewBuilder: (context, inst) => _StubView(
        key: ValueKey('stub-${inst.appid}'),
        appid: inst.appid,
      ),
    );

    openMiniProgramWith(h.container, 'a', conversationId: 'c1');
    await tester.pumpAndSettle();
    _StubViewState stateOf() => tester.state<_StubViewState>(
        find.byKey(const ValueKey('stub-a'), skipOffstage: false));
    final first = stateOf();

    // 同 appid 换参数重开(卡片语境):销毁重建,WebView/JS 状态随子树换新
    openMiniProgramWith(h.container, 'a', conversationId: 'c2');
    await tester.pumpAndSettle();

    expect(identical(stateOf(), first), isFalse);
    expect(h.manager.instances['a']!.conversationId, 'c2');
    expect(h.manager.foregroundAppid, 'a');
  });

  testWidgets('embedded 页收到 conv/launch 元数据,恢复 getChatContext 契约(I2)',
      (tester) async {
    final h = _Harness();
    await h.pump(tester, useRealEmbeddedPage: true);

    openMiniProgramWith(
      h.container,
      'a',
      conversationId: 'c1',
      launchParams: '{"x":1}',
    );
    await tester.pumpAndSettle();

    // 修复前:embedded 构造恒传 null → wanlingGetChatContext 返 null
    final page = tester.widget<MiniProgramPage>(find.byType(MiniProgramPage));
    expect(page.conversationId, 'c1');
    expect(page.launchParams, '{"x":1}');
  });

  group('最小化前抓 WebView 快照(E)', () {
    setUp(() => resetMiniProgramControllersForTest());

    testWidgets('registry 有 controller → onMinimize 抓帧写入实例', (tester) async {
      final h = _Harness();
      await h.pump(tester, useRealEmbeddedPage: true);

      openMiniProgramWith(h.container, 'a');
      await tester.pumpAndSettle();

      // 嵌入页测试不触 WebView 平台通道 → 手动注册替身 controller 模拟页面注册
      final fake = _MockShotController();
      final frame = Uint8List.fromList([7, 7, 7]);
      when(() => fake.takeScreenshot()).thenAnswer((_) async => frame);
      registerMiniProgramController('a', fake);

      final page = tester.widget<MiniProgramPage>(find.byType(MiniProgramPage));
      page.onMinimize!();
      await tester.pumpAndSettle();

      verify(() => fake.takeScreenshot()).called(1);
      expect(h.manager.foregroundAppid, isNull);
      expect(h.manager.instances['a']!.snapshot, same(frame));
    });

    testWidgets('抓帧抛异常 → 最小化照常完成,不崩(fail-safe)', (tester) async {
      final h = _Harness();
      await h.pump(tester, useRealEmbeddedPage: true);

      openMiniProgramWith(h.container, 'a');
      await tester.pumpAndSettle();

      final fake = _MockShotController();
      when(() => fake.takeScreenshot()).thenThrow(Exception('crash'));
      registerMiniProgramController('a', fake);

      final page = tester.widget<MiniProgramPage>(find.byType(MiniProgramPage));
      page.onMinimize!();
      await tester.pumpAndSettle();

      expect(h.manager.foregroundAppid, isNull);
      expect(h.manager.instances.containsKey('a'), isTrue);
      expect(find.byType(MiniProgramFloatBall), findsOneWidget);
    });
  });
}

/// 快照抓帧用替身 controller(只 stub takeScreenshot)。
class _MockShotController extends Mock implements InAppWebViewController {}
