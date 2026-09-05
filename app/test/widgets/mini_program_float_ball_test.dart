import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:app/services/mini_program_manager.dart';
import 'package:app/widgets/avatar.dart';
import 'package:app/widgets/mini_program_float_ball.dart';
import 'package:wanling_core/models/mini_program_info.dart';
import 'package:wanling_core/providers/auth_provider.dart' show apiProvider;
import 'package:wanling_core/providers/mini_programs_provider.dart';
import 'package:wanling_core/services/api_service.dart';

class MockApi extends Mock implements ApiService {}

MiniProgramInfo _mp(String appid, String name, String icon) =>
    MiniProgramInfo(
      id: 'id-$appid',
      appid: appid,
      ownerId: 'u1',
      name: name,
      version: 1,
      status: 'published',
      sha256: 'x',
      size: 1,
      icon: icon,
    );

/// 测试宿主:默认 override 小程序注册列表(空)与 api(测试环境无网,
/// FloatBall watch miniProgramsProvider 未挡会发真请求挂 pending timer)。
Widget _host(
  List<MiniProgramInstance> instances, {
  VoidCallback? onTap,
  List<MiniProgramInfo> programs = const [],
  String baseUrl = 'http://test.local',
}) {
  final api = MockApi();
  when(() => api.baseUrl).thenReturn(baseUrl);
  return ProviderScope(
    overrides: [
      apiProvider.overrideWithValue(api),
      miniProgramsProvider.overrideWith((ref) async => programs),
    ],
    child: MaterialApp(
      home: Stack(children: [
        const SizedBox.expand(),
        MiniProgramFloatBall(instances: instances, onTap: onTap ?? () {}),
      ]),
    ),
  );
}

Positioned _ballPositioned(WidgetTester tester) {
  return tester.widget<Positioned>(find.descendant(
    of: find.byType(MiniProgramFloatBall),
    matching: find.byType(Positioned),
  ));
}

void main() {
  setUp(() {
    // Avatar 内部 watch settingsProvider/authProvider(直连 SharedPreferences
    // 与 secure storage),不 mock 会在 flutter test 环境挂起
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
  });

  // 默认测试 surface 800x600,_size=56,_reveal=56/3≈18.67。
  testWidgets('点击浮球触发 onTap', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_host(
      [MiniProgramInstance(appid: 'a', openedAt: DateTime.now())],
      onTap: () => tapped = true,
    ));
    await tester.tap(find.byType(MiniProgramFloatBall));
    expect(tapped, isTrue);
  });

  testWidgets('长按进入拖拽(半透明解除),松手回吸附态', (tester) async {
    await tester.pumpWidget(_host(
      [MiniProgramInstance(appid: 'a', openedAt: DateTime.now())],
      onTap: () {},
    ));
    final center = tester.getCenter(find.byType(MiniProgramFloatBall));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600)); // 越过长按阈值
    await gesture.moveBy(const Offset(-100, 80));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    // 松手后仍在树上(吸附),且无异常
    expect(find.byType(MiniProgramFloatBall), findsOneWidget);
  });

  testWidgets('长按拖拽被取消 → 复位就近吸附,不卡拖拽态', (tester) async {
    await tester.pumpWidget(_host([
      MiniProgramInstance(appid: 'a', openedAt: DateTime.now()),
    ]));
    final center = tester.getCenter(find.byType(MiniProgramFloatBall));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600)); // 越过长按阈值
    await gesture.moveBy(const Offset(-100, 80));
    await tester.pump();
    // 系统事件打断(如系统弹窗)→ 手势取消
    await gesture.cancel();
    await tester.pumpAndSettle();
    final p = _ballPositioned(tester);
    // 拖拽态解除:回到吸附态露出宽度
    expect(p.width, closeTo(56.0 / 3, 0.01));
    // 拖后球心在右半屏 → 就近吸附右缘
    expect(p.left, closeTo(800 - 56.0 / 3, 0.01));
  });

  testWidgets('初始吸附右缘,露 1/3 宽', (tester) async {
    await tester.pumpWidget(_host([
      MiniProgramInstance(appid: 'a', openedAt: DateTime.now()),
    ]));
    final p = _ballPositioned(tester);
    const reveal = 56.0 / 3;
    expect(p.left, closeTo(800 - reveal, 0.01));
    expect(p.width, closeTo(reveal, 0.01));
    expect(p.height, 56);
  });

  testWidgets('长按拖到左半屏松手,就近吸附左缘', (tester) async {
    await tester.pumpWidget(_host([
      MiniProgramInstance(appid: 'a', openedAt: DateTime.now()),
    ]));
    final center = tester.getCenter(find.byType(MiniProgramFloatBall));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600));
    // 拖到 x=340,球中心 368 < 400(半屏) → 吸附左
    await gesture.moveBy(const Offset(-400, 0));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    final p = _ballPositioned(tester);
    expect(p.left, 0);
    expect(p.width, closeTo(56.0 / 3, 0.01));
  });

  testWidgets('多实例拖拽中显示数量角标,松手消失', (tester) async {
    await tester.pumpWidget(_host([
      MiniProgramInstance(appid: 'a', openedAt: DateTime.now()),
      MiniProgramInstance(appid: 'b', openedAt: DateTime.now()),
    ]));
    expect(find.text('2'), findsNothing);
    final center = tester.getCenter(find.byType(MiniProgramFloatBall));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(find.text('2'), findsOneWidget);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('2'), findsNothing);
  });

  testWidgets('iconUrl 非空渲染 Avatar 图像', (tester) async {
    final inst = MiniProgramInstance(appid: 'a', openedAt: DateTime.now())
      ..name = '测试'
      ..iconUrl = 'https://example.com/icon.png';
    await tester.pumpWidget(_host([inst]));
    expect(find.byType(Avatar), findsOneWidget);
  });

  testWidgets('实例 name/iconUrl 空 + provider 有数据 → 渲染注册名与完整 icon URL(D)',
      (tester) async {
    await tester.pumpWidget(_host(
      [MiniProgramInstance(appid: 'a', openedAt: DateTime.now())],
      programs: [_mp('a', '跳跳球大冒险', '/api/files/icon-a.png')],
    ));
    await tester.pump();

    // 打开瞬间快照为空:浮球必须显示 provider 回填的真名/真 URL
    final avatar = tester.widget<Avatar>(find.byType(Avatar));
    expect(avatar.name, '跳跳球大冒险');
    expect(avatar.url, 'http://test.local/api/files/icon-a.png');
  });

  testWidgets('provider 未加载(空列表)→ 回退快照/首字母色块(D)', (tester) async {
    await tester.pumpWidget(_host(
      [MiniProgramInstance(appid: 'ghost-app', openedAt: DateTime.now())],
    ));
    await tester.pump();

    // 无 icon URL → Avatar 不渲染(首字母色块分支,名字回退 appid 取首字母)
    expect(find.byType(Avatar), findsNothing);
    expect(find.text('G'), findsOneWidget);
  });
}
