// app/test/utils/chat/render_box_utils_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/utils/chat/render_box_utils.dart';

void main() {
  group('globalRectOf', () {
    testWidgets('未挂载 key 返回 null', (tester) async {
      final key = GlobalKey();
      expect(globalRectOf(key), isNull);
    });

    testWidgets('null key 返回 null', (tester) async {
      expect(globalRectOf(null), isNull);
    });

    testWidgets('已挂载 widget 返回 Rect', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(width: 100, height: 50, child: Container(key: key)),
          ),
        ),
      );
      final rect = globalRectOf(key);
      expect(rect, isNotNull);
      expect(rect!.width, 100);
      expect(rect.height, 50);
    });
  });

  group('listViewRect', () {
    testWidgets('已挂载返回 Rect', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              key: key,
              children: const [SizedBox(height: 100)],
            ),
          ),
        ),
      );
      final ctx = tester.element(find.byType(ListView));
      final rect = listViewRect(key, ctx);
      expect(rect.width, greaterThan(0));
      expect(rect.height, greaterThan(0));
    });

    testWidgets('拿不到 box 时用 MediaQuery 全屏兜底', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Container()),
        ),
      );
      final ctx = tester.element(find.byType(Scaffold));
      // key 未挂载到任何 widget,listViewRect 应 fallback 到 MediaQuery.size
      final rect = listViewRect(key, ctx);
      expect(rect, equals(const Offset(0, 0) & const Size(800, 600)));
    });
  });
}
