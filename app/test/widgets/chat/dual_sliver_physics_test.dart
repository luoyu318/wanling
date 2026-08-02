import 'package:app/widgets/chat/dual_sliver_physics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

DualSliverClampingPhysics _physics({required bool liveEmpty}) =>
    DualSliverClampingPhysics(getLiveEmpty: () => liveEmpty);

ScrollMetrics _metrics({
  required double pixels,
  required double minScrollExtent,
  required double maxScrollExtent,
  required double viewportDimension,
  AxisDirection axisDirection = AxisDirection.down,
}) {
  return FixedScrollMetrics(
    pixels: pixels,
    minScrollExtent: minScrollExtent,
    maxScrollExtent: maxScrollExtent,
    viewportDimension: viewportDimension,
    axisDirection: axisDirection,
    devicePixelRatio: 3.0,
  );
}

void main() {
  group('adjustPositionForNewDimensions(键盘 resize 保持底部锚定)', () {
    test('viewport 缩小(live 非空,用户在底部)→ pixels 跟着增大,底部边缘守恒', () {
      final physics = _physics(liveEmpty: false);
      final oldPos = _metrics(
        pixels: 500,
        minScrollExtent: 0,
        maxScrollExtent: 500,
        viewportDimension: 600,
      );
      final newPos = _metrics(
        pixels: 500,
        minScrollExtent: 0,
        maxScrollExtent: 500,
        viewportDimension: 300,
      );
      final result = physics.adjustPositionForNewDimensions(
        oldPosition: oldPos,
        newPosition: newPos,
        isScrolling: false,
        velocity: 0,
      );
      // 旧底部边缘 = 500 + 600 = 1100,但 maxScroll=500 → clamp 到 500(仍在底部)
      expect(result, 500);
    });

    test('viewport 缩小(live 非空,用户看历史)→ 像素位置随 viewport 同步上移', () {
      final physics = _physics(liveEmpty: false);
      final oldPos = _metrics(
        pixels: 200,
        minScrollExtent: 0,
        maxScrollExtent: 500,
        viewportDimension: 600,
      );
      final newPos = _metrics(
        pixels: 200,
        minScrollExtent: 0,
        maxScrollExtent: 500,
        viewportDimension: 300,
      );
      final result = physics.adjustPositionForNewDimensions(
        oldPosition: oldPos,
        newPosition: newPos,
        isScrolling: false,
        velocity: 0,
      );
      // 旧底部边缘 = 200 + 600 = 800;新 pixels = 800 - 300 = 500 → clamp 到 maxScroll=500
      expect(result, 500);
    });

    test('viewport 缩小(live 非空,用户看历史,缩后不触底)→ 保持底部边缘精确守恒', () {
      final physics = _physics(liveEmpty: false);
      final oldPos = _metrics(
        pixels: 100,
        minScrollExtent: 0,
        maxScrollExtent: 2000,
        viewportDimension: 600,
      );
      final newPos = _metrics(
        pixels: 100,
        minScrollExtent: 0,
        maxScrollExtent: 2000,
        viewportDimension: 400,
      );
      final result = physics.adjustPositionForNewDimensions(
        oldPosition: oldPos,
        newPosition: newPos,
        isScrolling: false,
        velocity: 0,
      );
      // 旧底部边缘 = 100 + 600 = 700;新 pixels = 700 - 400 = 300(在 [0,2000] 内)
      expect(result, 300);
    });

    test('viewport 变大(键盘收起,live 非空)→ pixels 减小,底部边缘守恒', () {
      final physics = _physics(liveEmpty: false);
      final oldPos = _metrics(
        pixels: 300,
        minScrollExtent: 0,
        maxScrollExtent: 2000,
        viewportDimension: 400,
      );
      final newPos = _metrics(
        pixels: 300,
        minScrollExtent: 0,
        maxScrollExtent: 2000,
        viewportDimension: 600,
      );
      final result = physics.adjustPositionForNewDimensions(
        oldPosition: oldPos,
        newPosition: newPos,
        isScrolling: false,
        velocity: 0,
      );
      // 旧底部边缘 = 300 + 400 = 700;新 pixels = 700 - 600 = 100
      expect(result, 100);
    });

    test('viewport 缩小(live 空,center 几何)→ 像素位置随 viewport 同步,守恒负方向底部边缘', () {
      final physics = _physics(liveEmpty: true);
      // 真机数据:oldPx=-830, oldMin=-11767, oldVd=710, effectiveMax=max(-11767,-710)=-710
      // 用户在 -830,在 [-11767, -710] 内(看历史)
      final oldPos = _metrics(
        pixels: -830,
        minScrollExtent: -11767,
        maxScrollExtent: 0,
        viewportDimension: 710,
      );
      final newPos = _metrics(
        pixels: -830,
        minScrollExtent: -11767,
        maxScrollExtent: 0,
        viewportDimension: 400,
      );
      final result = physics.adjustPositionForNewDimensions(
        oldPosition: oldPos,
        newPosition: newPos,
        isScrolling: false,
        velocity: 0,
      );
      // 旧底部边缘 = -830 + 710 = -120;新 pixels = -120 - 400 = -520
      // live 空 effectiveMax = max(-11767, -400) = -400,-520 在 [-11767, -400] 内
      expect(result, -520);
    });

    test('viewport 缩小(live 空,用户在 effectiveMax 边界)→ clamp 到新 effectiveMax', () {
      final physics = _physics(liveEmpty: true);
      final oldPos = _metrics(
        pixels: -600,
        minScrollExtent: -2000,
        maxScrollExtent: 0,
        viewportDimension: 600,
      );
      final newPos = _metrics(
        pixels: -600,
        minScrollExtent: -2000,
        maxScrollExtent: 0,
        viewportDimension: 400,
      );
      final result = physics.adjustPositionForNewDimensions(
        oldPosition: oldPos,
        newPosition: newPos,
        isScrolling: false,
        velocity: 0,
      );
      // 旧底部边缘 = -600 + 600 = 0;新 pixels = 0 - 400 = -400
      // live 空 effectiveMax = max(-2000, -400) = -400,刚好 clamp
      expect(result, -400);
    });

    test('viewport 未变(content 变化,如新消息到达)→ 返回 super(默认行为,保持 pixels)', () {
      final physics = _physics(liveEmpty: false);
      final oldPos = _metrics(
        pixels: 200,
        minScrollExtent: 0,
        maxScrollExtent: 500,
        viewportDimension: 600,
      );
      final newPos = _metrics(
        pixels: 200,
        minScrollExtent: 0,
        maxScrollExtent: 800,
        viewportDimension: 600,
      );
      final result = physics.adjustPositionForNewDimensions(
        oldPosition: oldPos,
        newPosition: newPos,
        isScrolling: false,
        velocity: 0,
      );
      // viewport 未变 → 走默认(返回 newPosition.pixels = 200),不干预
      expect(result, 200);
    });

    test('viewport 变大(键盘收起)+ live 非空 + 内容不足一屏(贴底 px=0) → 保持贴底 px=0',
        () {
      // 场景:首次进入发一条消息(live 非空),内容 < 键盘收起后的 viewport,
      // maxScrollExtent=0,旧 px=0(贴底=内容顶部)。键盘收起 vd 500→800,
      // 「底部边缘守恒」把 px 推到负值(-300)会让 live sliver 移出视口下方露空屏;
      // 正确是保持 px=0(live sliver 全部展示)。
      final physics = _physics(liveEmpty: false);
      final oldPos = _metrics(
        pixels: 0,
        minScrollExtent: -300,
        maxScrollExtent: 0,
        viewportDimension: 500,
      );
      final newPos = _metrics(
        pixels: 0,
        minScrollExtent: -300,
        maxScrollExtent: 0,
        viewportDimension: 800,
      );
      final result = physics.adjustPositionForNewDimensions(
        oldPosition: oldPos,
        newPosition: newPos,
        isScrolling: false,
        velocity: 0,
      );
      expect(result, 0,
          reason: '贴底场景键盘收起应保持新底部(px=0),而非守恒到负值把 live 推出视口');
    });
  });
}
