import 'package:app/widgets/long_press_detector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('按下不动 500ms 触发 onLongPressStart', (tester) async {
    var triggered = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LongPressDetector(
            onLongPressStart: (_) => triggered = true,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      ),
    );
    final gesture = await tester.startGesture(const Offset(50, 50));
    // 未到 500ms 不触发
    await tester.pump(const Duration(milliseconds: 400));
    expect(triggered, isFalse);
    // 到 500ms 触发
    await tester.pump(const Duration(milliseconds: 150));
    expect(triggered, isTrue);
    await gesture.up();
  });

  testWidgets('移动超阈值取消长按', (tester) async {
    var triggered = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LongPressDetector(
            onLongPressStart: (_) => triggered = true,
            child: const SizedBox(width: 200, height: 200),
          ),
        ),
      ),
    );
    // 用 TestGesture 精确控制 down/move 时序
    final gesture = await tester.startGesture(const Offset(50, 50));
    await tester.pump(const Duration(milliseconds: 300));
    // 移动 30px（> 18 阈值）→ 取消
    await gesture.moveBy(const Offset(30, 0));
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    expect(triggered, isFalse);
  });
}
