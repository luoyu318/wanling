// 小程序壳层返回键拦截(MiniProgramBackScope)行为测试。
// 重点覆盖双入口压栈场景:入口路由 /mini-program/:appid 的 push 不经 launcher
// 去重,快速双击列表 tile 会压入两个入口壳;验证连续返回键能清空壳层不卡死。
// 导航栈用真实 Navigator(残余壳兜底自弹发生在 navigator 层,不受 PopScope 门控);
// go_router 用 mocktail spy(真实 GoRouter 的 push 在 testWidgets 下不前进,见
// launcher 单测文件头说明)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:app/pages/mini_program_launch_page.dart';
import 'package:app/providers/mini_program_manager_provider.dart';
import 'package:app/router.dart' show routerProvider;
import 'package:app/services/mini_program_launcher.dart';
import 'package:app/services/mini_program_manager.dart';
import 'package:wanling_core/providers/mini_programs_provider.dart';

class _MockGoRouter extends Mock implements GoRouter {}

void main() {
  late _MockGoRouter router;
  late ProviderContainer container;

  setUp(() {
    resetLauncherForTest();
    router = _MockGoRouter();
    when(() => router.push(any<String>())).thenAnswer((_) async => null);
    when(() => router.canPop()).thenReturn(true);
    when(() => router.pop()).thenReturn(null);
    container = ProviderContainer(
      overrides: [routerProvider.overrideWithValue(router)],
    );
    addTearDown(container.dispose);
  });

  /// 泵「宿主页 + 双入口壳压栈」场景:两个壳页各自 bindLiveRoute(等价
  /// LaunchPage initState),manager 置同一前台实例。
  Future<void> pumpDoubleShellStack(WidgetTester tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('HOME', textDirection: TextDirection.ltr)),
        ),
      ),
    ));
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    for (final key in const ['L1', 'L2']) {
      bindLiveRoute();
      unawaited(nav.push(MaterialPageRoute<void>(
        builder: (_) => MiniProgramBackScope(key: Key(key)),
      )));
      await tester.pumpAndSettle();
    }
    container.read(miniProgramManagerProvider).open('a');
  }

  testWidgets('双入口双压栈:连续返回键清空壳层不卡死', (tester) async {
    await pumpDoubleShellStack(tester);
    expect(find.byKey(const Key('L2')), findsOneWidget);

    // back#1: 顶壳最小化 → sync 弹壳(flag 复位)。mock pop 不动真实栈,
    // 对应真实 app 中「弹掉一层壳后残余壳仍在栈上」的状态。
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
    await tester.pumpAndSettle();
    expect(container.read(miniProgramManagerProvider).hasForeground, isFalse);
    verify(() => router.pop()).called(1);
    expect(find.byKey(const Key('L2')), findsOneWidget);

    // back#2: 残余壳兜底自弹(sync 无壳可弹,Navigator.pop 不受 PopScope 门控)
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('L2')), findsNothing);

    // back#3: 底层残余壳同样可清,回到宿主页
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('L1')), findsNothing);
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets('单壳返回:sync 弹壳后不触发兜底自弹(无双弹)', (tester) async {
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('HOME', textDirection: TextDirection.ltr)),
        ),
      ),
    ));
    final nav = tester.state<NavigatorState>(find.byType(Navigator));
    bindLiveRoute();
    unawaited(nav.push(MaterialPageRoute<void>(
      builder: (_) => const MiniProgramBackScope(key: Key('ONLY')),
    )));
    await tester.pumpAndSettle();
    container.read(miniProgramManagerProvider).open('a');

    // 一次返回键:sync 弹壳(return),兜底不触发,真实栈未动(由真实 router 弹)
    await tester.state<NavigatorState>(find.byType(Navigator)).maybePop();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ONLY')), findsOneWidget);
    verify(() => router.pop()).called(1);
    expect(container.read(miniProgramManagerProvider).hasForeground, isFalse);
  });

  testWidgets('launch 页把 query conv/launch 透传给实例元数据(I2)', (tester) async {
    final manager = MiniProgramManager();
    final realRouter = GoRouter(
      initialLocation: '/mini-program/a?conv=c1&launch=%7B%22x%22%3A1%7D',
      routes: [
        GoRoute(
          path: '/mini-program/:appid',
          pageBuilder: (context, state) => NoTransitionPage<void>(
            key: state.pageKey,
            child: MiniProgramLaunchPage(
              appid: state.pathParameters['appid']!,
              conversationId: state.uri.queryParameters['conv'],
              launchParams: state.uri.queryParameters['launch'],
            ),
          ),
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
    final realContainer = ProviderContainer(overrides: [
      miniProgramManagerProvider.overrideWith((ref) => manager),
      routerProvider.overrideWithValue(realRouter),
      // 列表未加载 → name/iconUrl 空,仅 appid 拉起(深链常态)
      miniProgramsProvider.overrideWith((ref) async => const []),
    ]);
    addTearDown(realContainer.dispose);
    resetLauncherForTest();

    await tester.pumpWidget(UncontrolledProviderScope(
      container: realContainer,
      child: MaterialApp.router(routerConfig: realRouter),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();

    // 修复前:launch 页收下 conversationId/launchParams 后零消费,
    // embedded 恒收 null → getChatContext 返 null、卡片启动参数失效
    final inst = manager.instances['a'];
    expect(inst, isNotNull);
    expect(inst!.conversationId, 'c1');
    expect(inst.launchParams, '{"x":1}'); // URL 编码 JSON 解码无损
    expect(manager.foregroundAppid, 'a');
  });
}
