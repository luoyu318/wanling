import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/mini_program_manager.dart';
import 'package:app/widgets/avatar.dart';
import 'package:app/widgets/mini_program_float_ball.dart';

Widget _host(List<MiniProgramInstance> instances, {VoidCallback? onTap}) {
  return MaterialApp(
    home: Stack(children: [
      const SizedBox.expand(),
      MiniProgramFloatBall(instances: instances, onTap: onTap ?? () {}),
    ]),
  );
}

Positioned _ballPositioned(WidgetTester tester) {
  return tester.widget<Positioned>(find.descendant(
    of: find.byType(MiniProgramFloatBall),
    matching: find.byType(Positioned),
  ));
}

void main() {
  // 默认测试 surface 800x600,_size=56,_reveal=56/3≈18.67。
  testWidgets('点击浮球触发 onTap', (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      home: Stack(children: [
        const SizedBox.expand(),
        MiniProgramFloatBall(
          instances: [MiniProgramInstance(appid: 'a', openedAt: DateTime.now())],
          onTap: () => tapped = true,
        ),
      ]),
    ));
    await tester.tap(find.byType(MiniProgramFloatBall));
    expect(tapped, isTrue);
  });

  testWidgets('长按进入拖拽(半透明解除),松手回吸附态', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Stack(children: [
        const SizedBox.expand(),
        MiniProgramFloatBall(
          instances: [MiniProgramInstance(appid: 'a', openedAt: DateTime.now())],
          onTap: () {},
        ),
      ]),
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
    await tester.pumpWidget(ProviderScope(child: _host([inst])));
    expect(find.byType(Avatar), findsOneWidget);
  });
}
