// 小程序导航观察者测试(C2):
// 机制:Host 层实例视图盖在 Navigator 之上,小程序前台时任何 context.push
// (openPage miniPrograms/agentDetail、通知点击进聊天、深链)都被 WebView 盖住,
// 零反馈(导航黑洞);返回键被 live 壳转 minimize,被 push 页面残留栈底。
// 修复:GoRouter 注册 MiniProgramAutoMinimizeObserver,非小程序路由 didPush 时
// 自动最小化前台实例(微信语义「去别处=收起」);小程序两类壳路由排除。
// 壳路由识别:router.dart 给两类壳路由显式 name=state.matchedLocation
// (go_router push 场景 pageKey 是唯一 id 而非路径,不能复用)。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:app/pages/mini_program_launch_page.dart';
import 'package:app/providers/mini_program_manager_provider.dart';
import 'package:app/router.dart' show routerProvider;
import 'package:app/services/mini_program_launcher.dart';
import 'package:app/services/mini_program_manager.dart';
import 'package:app/services/mini_program_nav_observer.dart';
import 'package:app/widgets/mini_program_host.dart';

/// 测试脚手架:真实 manager + 真实 GoRouter(壳路由带 name,对齐 router.dart
/// 定义)+ observer 挂载 + Host 接线(替身实例视图)。
class _Harness {
  final MiniProgramManager manager = MiniProgramManager();
  late final GoRouter router;
  late final ProviderContainer container;

  Future<void> pump(WidgetTester tester) async {
    router = GoRouter(
      initialLocation: '/',
      observers: [MiniProgramAutoMinimizeObserver()],
      routes: [
        GoRoute(
          path: '/',
          builder: (context, state) =>
              const Scaffold(body: Text('home-body')),
        ),
        GoRoute(
          path: '/other',
          builder: (context, state) =>
              const Scaffold(body: Text('other-body')),
        ),
        // 入口壳路由:name=matchedLocation(对齐 router.dart,observer 排除依据)
        GoRoute(
          path: '/mini-program/:appid',
          pageBuilder: (context, state) => NoTransitionPage<void>(
            key: state.pageKey,
            name: state.matchedLocation,
            child: const SizedBox.shrink(),
          ),
        ),
        // live 壳路由:同上
        GoRoute(
          path: '/mini-program-live/:appid',
          pageBuilder: (context, state) => NoTransitionPage<void>(
            key: state.pageKey,
            name: state.matchedLocation,
            child: const MiniProgramLiveShellPage(),
          ),
        ),
      ],
    );
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
          instanceViewBuilder: (context, inst) => Text('mp-${inst.appid}'),
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    ));
    await tester.pump();
    await tester.pump();
    await tester.pumpAndSettle();
  }
}

void main() {
  setUp(() {
    resetLauncherForTest();
  });

  testWidgets('前台实例时 push 非小程序路由 → 实例最小化,新页面可见无黑洞',
      (tester) async {
    final h = _Harness();
    await h.pump(tester);

    openMiniProgramWith(h.container, 'a');
    await tester.pumpAndSettle();
    expect(h.manager.foregroundAppid, 'a');
    expect(find.text('other-body'), findsNothing);

    // 注:GoRouter.push 的 Future 在路由 pop 时才完成,不能 await(挂起),
    // 用 unawaited + pumpAndSettle 推进帧
    unawaited(h.router.push('/other'));
    await tester.pumpAndSettle();

    // 修复前:实例仍前台,push 的页面被 WebView 盖住(导航黑洞)
    expect(h.manager.foregroundAppid, isNull);
    expect(find.text('other-body'), findsOneWidget);
    // 实例仍挂树上(Offstage 保活,不是销毁)
    expect(
      find
          .text('mp-a', skipOffstage: false)
          .evaluate()
          .isNotEmpty,
      isTrue,
    );
  });

  testWidgets('push 小程序壳路由(live 壳/入口壳) → 不触发最小化(排除生效)',
      (tester) async {
    final h = _Harness();
    await h.pump(tester);

    openMiniProgramWith(h.container, 'a');
    await tester.pumpAndSettle();
    expect(h.manager.foregroundAppid, 'a');

    // 入口壳 push:排除(压栈时实例尚未重开,收起反而误伤)
    unawaited(h.router.push('/mini-program/b'));
    await tester.pumpAndSettle();
    expect(h.manager.foregroundAppid, 'a');

    // live 壳 push(launcher 场景):排除,与收起互斥
    unawaited(h.router.push('/mini-program-live/b'));
    await tester.pumpAndSettle();
    expect(h.manager.foregroundAppid, 'a');
  });

  testWidgets('无前台实例时 push 非小程序路由 → 观察者幂等无副作用',
      (tester) async {
    final h = _Harness();
    await h.pump(tester);

    h.manager.open('a');
    h.manager.minimize();
    await tester.pumpAndSettle();

    unawaited(h.router.push('/other'));
    await tester.pumpAndSettle();

    expect(h.manager.foregroundAppid, isNull);
    expect(h.manager.instances.containsKey('a'), isTrue); // 不误销毁
    expect(find.text('other-body'), findsOneWidget);
  });
}
