import 'package:app/widgets/chat/slash_handle.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SlashHandle 中点吸附逻辑', () {
    // 直接验证 attachSideForX 纯函数(易测)
    test('中点 < 50% 时贴左', () {
      expect(attachSideForX(0.3), AttachSide.left);
      expect(attachSideForX(0.49), AttachSide.left);
    });
    test('中点 ≥ 50% 时贴右', () {
      expect(attachSideForX(0.5), AttachSide.right);
      expect(attachSideForX(0.8), AttachSide.right);
    });
  });

  group('SlashHandle widget 渲染', () {
    testWidgets('visible=false 时不渲染', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SlashHandle(visible: false, onTrigger: () {}),
          ),
        ),
      );
      expect(find.byKey(const Key('slash-handle')), findsNothing);
    });

    testWidgets('visible=true 时渲染', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SlashHandle(visible: true, onTrigger: () {}),
          ),
        ),
      );
      expect(find.byKey(const Key('slash-handle')), findsOneWidget);
    });

    testWidgets('点按感应线触发 onTrigger', (tester) async {
      var triggered = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SlashHandle(visible: true, onTrigger: () => triggered++),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('slash-handle')));
      await tester.pump();
      expect(triggered, 1);
    });

    testWidgets('长按拖动后吸附到最近边', (tester) async {
      // 测试表面默认 800x600。SlashHandle 默认贴右(800-6-2=792)
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SlashHandle(visible: true, onTrigger: () {}),
          ),
        ),
      );

      // 起始位置:右半区
      final initialRect = tester.getRect(find.byKey(const Key('slash-handle')));
      expect(
        initialRect.center.dx,
        greaterThan(400),
        reason: '默认应在右半区',
      );

      // 长按(>kLongPressTimeout)+ 拖到左半区 + 释放
      // 用 gesture API 才能触发 onLongPressStart/Move/End(timedDrag 只触发 drag 系列)
      final gesture = await tester.startGesture(initialRect.center);
      await tester.pump(const Duration(milliseconds: 600));
      await gesture.moveBy(const Offset(-700, 50));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // 验证:松手后应吸附到左侧(_edgePadding=6,center≈7)
      final finalRect = tester.getRect(find.byKey(const Key('slash-handle')));
      expect(
        finalRect.center.dx,
        lessThan(400),
        reason: '应吸附到左侧',
      );
    });
  });
}
