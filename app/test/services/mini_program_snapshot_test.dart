// 小程序快照抓取编排测试(E):
// 1. minimizeWithSnapshot:抓帧成功 → 帧写入实例 + minimize 完成
// 2. 无 controller / takeScreenshot 返 null / 抛异常 → 最小化照常完成(fail-safe)
// 3. 抓帧期间实例已被关(竞态)→ 不崩,最小化完成
// 4. 注册表 register/unregister/reset
//
// Mock 策略:InAppWebViewController 用 mocktail 替身(只 stub takeScreenshot);
// manager 用真实例;live 壳同步走真实 launcher(routerProvider 覆盖为空壳路由)。
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:app/providers/mini_program_manager_provider.dart';
import 'package:app/router.dart' show routerProvider;
import 'package:app/services/mini_program_launcher.dart';
import 'package:app/services/mini_program_manager.dart';
import 'package:app/services/mini_program_snapshot.dart';

class _MockController extends Mock implements InAppWebViewController {}

/// 挂起编排的 pause/resume 走 unawaited(生产签名 Future),替身默认返 null
/// 会炸 unawaited 的类型校验,统一 stub 成 no-op Future。
void _stubLifecycle(_MockController c) {
  when(() => c.pause()).thenAnswer((_) async {});
  when(() => c.resume()).thenAnswer((_) async {});
  when(() => c.pauseTimers()).thenAnswer((_) async {});
  when(() => c.resumeTimers()).thenAnswer((_) async {});
  // 壳返回键先问 WebView 历史(false → 落到最小化,对齐既有断言语义)
  when(() => c.canGoBack()).thenAnswer((_) async => false);
  when(() => c.goBack()).thenAnswer((_) async {});
}

class _Harness {
  final MiniProgramManager manager = MiniProgramManager();
  late final ProviderContainer container;

  void pump() {
    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (context, state) =>
            const Scaffold(body: Text('home-body')),
      ),
    ]);
    container = ProviderContainer(overrides: [
      miniProgramManagerProvider.overrideWith((ref) => manager),
      routerProvider.overrideWithValue(router),
    ]);
    addTearDown(container.dispose);
  }
}

void main() {
  setUp(() {
    resetLauncherForTest();
    resetMiniProgramControllersForTest();
  });

  group('注册表', () {
    test('register 写入 / unregister 移除 / reset 清空', () {
      final c = _MockController();
      _stubLifecycle(c);
      registerMiniProgramController('a', c);
      expect(miniProgramControllerRegistry['a'], same(c));

      unregisterMiniProgramController('a');
      expect(miniProgramControllerRegistry.containsKey('a'), isFalse);

      registerMiniProgramController('b', c);
      resetMiniProgramControllersForTest();
      expect(miniProgramControllerRegistry, isEmpty);
    });
  });

  group('captureSnapshot(尽力而为)', () {
    test('无 controller 注册 → null', () async {
      expect(await captureSnapshot('a'), isNull);
    });

    test('takeScreenshot 返帧 → 透传;返 null → null;抛异常 → null 不炸', () async {
      final c = _MockController();
      _stubLifecycle(c);
      registerMiniProgramController('a', c);
      final frame = Uint8List.fromList([9, 9]);

      when(() => c.takeScreenshot()).thenAnswer((_) async => frame);
      expect(await captureSnapshot('a'), same(frame));

      when(() => c.takeScreenshot()).thenAnswer((_) async => null);
      expect(await captureSnapshot('a'), isNull);

      when(() => c.takeScreenshot()).thenThrow(Exception('渲染层挂了'));
      expect(await captureSnapshot('a'), isNull);
    });
  });

  group('minimizeWithSnapshot(统一收起路径)', () {
    test('抓帧成功:帧写入实例 + 前台清空(最小化完成)', () async {
      final h = _Harness()..pump();
      h.manager.open('a');
      final frame = Uint8List.fromList([1, 2, 3]);
      final c = _MockController();
      _stubLifecycle(c);
      registerMiniProgramController('a', c);
      when(() => c.takeScreenshot()).thenAnswer((_) async => frame);

      final r = await minimizeWithSnapshot(h.container);

      expect(r.frame, same(frame));
      expect(r.popped, isFalse);
      expect(h.manager.foregroundAppid, isNull);
      expect(h.manager.instances['a']!.snapshot, same(frame));
    });

    test('无 controller:最小化照常完成,无帧', () async {
      final h = _Harness()..pump();
      h.manager.open('a');

      final r = await minimizeWithSnapshot(h.container);

      expect(r.frame, isNull);
      expect(r.popped, isFalse);
      expect(h.manager.foregroundAppid, isNull);
      expect(h.manager.instances['a']!.snapshot, isNull);
    });

    test('takeScreenshot 抛异常:最小化照常完成,不崩(fail-safe)', () async {
      final h = _Harness()..pump();
      h.manager.open('a');
      final c = _MockController();
      _stubLifecycle(c);
      registerMiniProgramController('a', c);
      when(() => c.takeScreenshot()).thenThrow(Exception('crash'));

      final r = await minimizeWithSnapshot(h.container);

      expect(r.frame, isNull);
      expect(r.popped, isFalse);
      expect(h.manager.foregroundAppid, isNull);
      expect(h.manager.instances.containsKey('a'), isTrue);
    });

    test('无前台实例:直接最小化 no-op 语义,不抓帧', () async {
      final h = _Harness()..pump();

      final r = await minimizeWithSnapshot(h.container);

      expect(r.frame, isNull);
      expect(r.popped, isFalse);
      expect(h.manager.hasForeground, isFalse);
    });
  });
}
