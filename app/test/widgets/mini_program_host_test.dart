// MiniProgramHost 全局保活层 widget 测试:
// 1. 无实例只渲染 child
// 2. open 后替身视图挂载且前台 Offstage(false)
// 3. minimize 后 Offstage(true) 且视图仍在树上(保活),浮球出现
// 4. 多实例:后台 Offstage(true),前台 Offstage(false)
// 5. close 后实例视图从树上消失
// 6. 上滑关闭最后一个实例:任务视图自动关闭(不悬在空列表上)
// 7. 宿主回调联动 live 壳路由:上滑关闭弹壳 / 点卡片恢复压回
//
// Mock 策略:manager 用真实例(纯状态);routerProvider 覆盖为真实 GoRouter
// (带 /mini-program-live/:appid 壳路由);WebView 不触平台通道——
// instanceViewBuilder 注入替身视图 Text('mp-<appid>')。
// 注:skipOffstage=false 断言「是否仍在树上」(保活视图默认 finder 会跳过)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:app/pages/mini_program_launch_page.dart';
import 'package:app/providers/mini_program_manager_provider.dart';
import 'package:app/router.dart' show routerProvider;
import 'package:app/services/mini_program_launcher.dart';
import 'package:app/services/mini_program_manager.dart';
import 'package:app/widgets/mini_program_float_ball.dart';
import 'package:app/widgets/mini_program_host.dart';
import 'package:app/widgets/mini_program_task_view.dart';

/// 测试脚手架:真实 manager + 最小真实路由(含 live 壳) + Host 接线
/// (与 main.dart 的 MaterialApp.builder 同构,替身视图替代 WebView)。
class _Harness {
  final MiniProgramManager manager = MiniProgramManager();
  late final GoRouter router;
  late final ProviderContainer container;

  Future<void> pump(WidgetTester tester) async {
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
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        builder: (context, child) => MiniProgramHost(
          child: child ?? const SizedBox.shrink(),
          // 替身视图:替代真实 MiniProgramPage(WebView 需平台通道,测试不可用)
          instanceViewBuilder: (context, inst) =>
              Text('mp-${inst.appid}'),
        ),
      ),
    ));
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
}
