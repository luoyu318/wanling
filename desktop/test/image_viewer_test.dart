// desktop/test/image_viewer_test.dart
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_desktop/widgets/image_viewer.dart';

void main() {
  group('wheelZoom 纯函数', () {
    test('向上滚(负 delta)以焦点为锚放大,scale 增大', () {
      final m = Matrix4.identity();
      final out = wheelZoom(m, delta: -53, focal: const Offset(100, 100));
      expect(out.getMaxScaleOnAxis(), greaterThan(1));
    });

    test('向下滚(正 delta)缩小,scale 减小且不低于 minScale', () {
      final m = Matrix4.identity();
      final out = wheelZoom(m, delta: 53, focal: Offset.zero);
      expect(out.getMaxScaleOnAxis(), lessThan(1));
      expect(out.getMaxScaleOnAxis(), greaterThanOrEqualTo(0.5));
    });

    test('超限滚动钳制在 [minScale, maxScale]', () {
      var m = Matrix4.identity();
      // 连续放大 30 次后不超过 maxScale(8)。
      for (var i = 0; i < 30; i++) {
        m = wheelZoom(m, delta: -120, focal: Offset.zero);
      }
      expect(m.getMaxScaleOnAxis(), lessThanOrEqualTo(8.0));
      // 连续缩小后不低于 minScale(0.5)。
      var n = Matrix4.identity();
      for (var i = 0; i < 30; i++) {
        n = wheelZoom(n, delta: 120, focal: Offset.zero);
      }
      expect(n.getMaxScaleOnAxis(), greaterThanOrEqualTo(0.5));
    });
  });

  group('ImageViewerDialog widget', () {
    Future<ImageViewerState> _pump(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ImageViewerDialog(
            url: 'http://localhost:9/f.jpg',
            headers: {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      return tester.state<ImageViewerState>(find.byType(ImageViewerDialog));
    }

    testWidgets('渲染 InteractiveViewer + 关闭按钮,滚轮缩放改 transform', (tester) async {
      final state = await _pump(tester);

      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.byKey(const ValueKey('image_viewer_close')), findsOneWidget);
      expect(state.transformationController.value.getMaxScaleOnAxis(), 1.0);

      // 滚轮向上滚:经 Listener.onPointerSignal 触发缩放。
      await tester.sendEventToBinding(
        PointerScrollEvent(
          scrollDelta: const Offset(0, -53),
          position: tester.getCenter(find.byType(InteractiveViewer)),
        ),
      );
      await tester.pump();

      final scale = state.transformationController.value.getMaxScaleOnAxis();
      expect(scale, greaterThan(1.0));
    });

    testWidgets('点击关闭按钮 pop 掉全屏预览', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showImageViewer(
                  context,
                  url: 'http://localhost:9/f.jpg',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(ImageViewerDialog), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('image_viewer_close')));
      await tester.pumpAndSettle();
      expect(find.byType(ImageViewerDialog), findsNothing);
    });

    testWidgets('Esc 键关闭全屏预览', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showImageViewer(
                  context,
                  url: 'http://localhost:9/f.jpg',
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(ImageViewerDialog), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(ImageViewerDialog), findsNothing);
    });
  });
}
