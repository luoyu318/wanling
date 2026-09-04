// 小程序统一打开入口(launcher)单元测试。
// manager 用真实例(纯状态 ChangeNotifier);GoRouter 用 mocktail spy——
// framework Router 的事务机制在 testWidgets 下会丢弃 go_router push 的
// 异步更新(currentConfiguration 不前进),故不对接真实导航,只验证
// launcher 对 router 的调用契约与 manager 状态迁移。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import 'package:app/providers/mini_program_manager_provider.dart';
import 'package:app/router.dart' show routerProvider;
import 'package:app/services/mini_program_launcher.dart';

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

  test('openMiniProgramWith 置前台并压 live 壳,元信息透传', () {
    openMiniProgramWith(container, 'a', name: 'A', iconUrl: 'http://t/a.png');

    final manager = container.read(miniProgramManagerProvider);
    expect(manager.foregroundAppid, 'a');
    expect(manager.foreground?.name, 'A');
    expect(manager.foreground?.iconUrl, 'http://t/a.png');
    verify(() => router.push('/mini-program-live/a')).called(1);
  });

  test('壳已在栈上时再次 open 只切前台,不重复压栈', () {
    openMiniProgramWith(container, 'a');
    openMiniProgramWith(container, 'b');

    expect(container.read(miniProgramManagerProvider).foregroundAppid, 'b');
    verify(() => router.push(any<String>())).called(1);
  });

  test('bindLiveRoute 自报占位后 open 不压壳(launch 页场景)', () {
    bindLiveRoute();
    openMiniProgramWith(container, 'a');

    expect(container.read(miniProgramManagerProvider).foregroundAppid, 'a');
    verifyNever(() => router.push(any<String>()));
  });

  test('最小化 + sync 弹壳;实例保活只清前台', () {
    openMiniProgramWith(container, 'a');

    container.read(miniProgramManagerProvider).minimize();
    syncLiveRouteWith(container);

    final manager = container.read(miniProgramManagerProvider);
    expect(manager.hasForeground, isFalse);
    expect(manager.instances['a'], isNotNull);
    verify(() => router.pop()).called(1);
  });

  test('有前台但壳不在栈上时 sync 补压(宿主面板恢复场景)', () {
    openMiniProgramWith(container, 'a');
    container.read(miniProgramManagerProvider).minimize();
    syncLiveRouteWith(container);
    clearInteractions(router);

    container.read(miniProgramManagerProvider).restore('a');
    syncLiveRouteWith(container);

    verify(() => router.push('/mini-program-live/a')).called(1);
    verifyNever(() => router.pop());
  });

  test('无前台且壳不在栈上时 sync 幂等', () {
    syncLiveRouteWith(container);

    verifyNever(() => router.push(any<String>()));
    verifyNever(() => router.pop());
  });

  test('无前台且壳在栈上但 canPop=false 时 sync 只复位不 pop', () {
    bindLiveRoute();
    when(() => router.canPop()).thenReturn(false);

    container.read(miniProgramManagerProvider).minimize();
    syncLiveRouteWith(container);

    verifyNever(() => router.pop());
    // 复位后再 open 会正常压壳(状态已清)
    openMiniProgramWith(container, 'a');
    verify(() => router.push('/mini-program-live/a')).called(1);
  });
}
