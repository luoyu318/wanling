import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/widgets/chat/selection_bottom_bar.dart';

void main() {
  Future<void> pumpIt(
    WidgetTester tester, {
    required int selectedCount,
    VoidCallback? onBatchCopy,
    VoidCallback? onConfirmDelete,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionBottomBar(
            selectedCount: selectedCount,
            onBatchCopy: onBatchCopy,
            onConfirmDelete: onConfirmDelete,
          ),
        ),
      ),
    );
  }

  group('SelectionBottomBar', () {
    testWidgets('selectedCount=0 两按钮置灰且 onPressed=null', (tester) async {
      await pumpIt(tester, selectedCount: 0);
      final copyBtn = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.content_copy),
      );
      final delBtn = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.delete_outline),
      );
      expect(copyBtn.onPressed, isNull);
      expect(delBtn.onPressed, isNull);
      expect(copyBtn.color, Colors.grey);
      expect(delBtn.color, Colors.grey);
    });

    testWidgets('selectedCount=3 两按钮 enabled 且颜色正确', (tester) async {
      await pumpIt(
        tester,
        selectedCount: 3,
        onBatchCopy: () {},
        onConfirmDelete: () {},
      );
      final copyBtn = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.content_copy),
      );
      final delBtn = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.delete_outline),
      );
      expect(copyBtn.onPressed, isNotNull);
      expect(delBtn.onPressed, isNotNull);
      expect(copyBtn.color, Colors.black87);
      expect(delBtn.color, const Color(0xFFFA5151));
    });

    testWidgets('点复制按钮触发 onBatchCopy', (tester) async {
      var copyCalled = false;
      await pumpIt(
        tester,
        selectedCount: 1,
        onBatchCopy: () => copyCalled = true,
        onConfirmDelete: () {},
      );
      await tester.tap(find.widgetWithIcon(IconButton, Icons.content_copy));
      expect(copyCalled, isTrue);
    });

    testWidgets('点删除按钮触发 onConfirmDelete', (tester) async {
      var delCalled = false;
      await pumpIt(
        tester,
        selectedCount: 1,
        onBatchCopy: () {},
        onConfirmDelete: () => delCalled = true,
      );
      await tester.tap(find.widgetWithIcon(IconButton, Icons.delete_outline));
      expect(delCalled, isTrue);
    });
  });
}
