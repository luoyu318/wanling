import 'package:wanling_core/rendering/truncatable_text_block.dart';
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

    testWidgets('isDark:抽屉深色底 #1E1F24 + 把手 #3A3B42 + 正文 #C8C8C8(浅色回归白底 #555555)', (tester) async {
      final longText = List<String>.generate(50, (i) => '第 $i 行').join('\n');
      Widget host(bool isDark) => MaterialApp(
            home: Scaffold(
              body: TruncatableTextBlock(
                text: longText,
                sheetTitle: const Text('我的标题'),
                textStyle: const TextStyle(fontSize: 12),
                isDark: isDark,
              ),
            ),
          );

      // 深色:抽屉 Material 底 1E1F24,把手 3A3B42,分割线 2E2F36,正文 C8C8C8
      await tester.pumpWidget(host(true));
      await tester.tap(find.byType(GestureDetector));
      await tester.pumpAndSettle();
      final darkSheet = tester.widget<Material>(
        find.descendant(of: find.byType(BottomSheet), matching: find.byType(Material)).first,
      );
      expect(darkSheet.color, const Color(0xFF1E1F24));
      expect(_hasContainerColor(tester, const Color(0xFF3A3B42)), isTrue, reason: '深色把手');
      expect(tester.widget<Divider>(find.byType(Divider)).color, const Color(0xFF2E2F36), reason: '深色分割线');
      expect(tester.widget<SelectableText>(find.byType(SelectableText)).style?.color, const Color(0xFFC8C8C8));

      // 浅色回归:白底 + 正文 555555(先点 barrier 关深色抽屉再切浅色)
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      await tester.pumpWidget(host(false));
      await tester.tap(find.byType(GestureDetector));
      await tester.pumpAndSettle();
      final lightSheet = tester.widget<Material>(
        find.descendant(of: find.byType(BottomSheet), matching: find.byType(Material)).first,
      );
      expect(lightSheet.color, Colors.white);
      expect(tester.widget<SelectableText>(find.byType(SelectableText)).style?.color, const Color(0xFF555555));
    });
  });
}

/// 判断树中是否存在指定底色的 Container(抽屉把手断言用)。
/// 新版 Container(color:) 不再折叠进 decoration,需同时查 self color + decoration。
bool _hasContainerColor(WidgetTester tester, Color color) => tester
    .widgetList<Container>(find.byType(Container))
    .any((w) => w.color == color || (w.decoration as BoxDecoration?)?.color == color);
