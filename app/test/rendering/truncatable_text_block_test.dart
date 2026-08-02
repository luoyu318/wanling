import 'package:app/rendering/truncatable_text_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TruncatableTextBlock', () {
    testWidgets('空文本返 SizedBox.shrink', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TruncatableTextBlock(
            text: '',
            sheetTitle: const Text('标题'),
            textStyle: const TextStyle(fontSize: 12),
          ),
        ),
      ));
      expect(find.byType(SizedBox), findsOneWidget);
      expect(find.byType(Container), findsNothing);
    });

    testWidgets('长文本内联截断(maxHeight:56 + maxLines:3)', (tester) async {
      final longText = List<String>.generate(50, (i) => '第 $i 行').join('\n');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TruncatableTextBlock(
            text: longText,
            sheetTitle: const Text('标题'),
            textStyle: const TextStyle(fontSize: 12),
          ),
        ),
      ));
      // Container 存在且有 maxHeight:56 约束
      final container = tester.widget<Container>(find.byType(Container));
      final constraints = container.constraints;
      expect(constraints, isNotNull);
      expect(constraints!.maxHeight, 56);
      // Text 有 maxLines:3 + ellipsis
      final text = tester.widget<Text>(find.byType(Text).last);
      expect(text.maxLines, 3);
      expect(text.overflow, TextOverflow.ellipsis);
    });

    testWidgets('点击弹 showDetailSheet,SelectableText 含全文 + 标题渲染', (tester) async {
      final longText = List<String>.generate(50, (i) => '第 $i 行').join('\n');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TruncatableTextBlock(
            text: longText,
            sheetTitle: const Text('我的标题'),
            textStyle: const TextStyle(fontSize: 12),
          ),
        ),
      ));
      // 抽屉出现前无 SelectableText(内联是普通 Text)
      expect(find.byType(SelectableText), findsNothing);

      await tester.tap(find.byType(GestureDetector));
      await tester.pumpAndSettle();

      // 抽屉出现,内含 SelectableText 且文本是全文
      final selectable = find.byType(SelectableText);
      expect(selectable, findsOneWidget);
      expect((tester.widget<SelectableText>(selectable) as SelectableText).data, longText);
      // 标题渲染
      expect(find.text('我的标题'), findsOneWidget);
    });
  });
}
