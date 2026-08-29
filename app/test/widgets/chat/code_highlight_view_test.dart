import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/widgets/chat/code_highlight_view.dart';

void main() {
  testWidgets('渲染代码 + 行号', (tester) async {
    const code = 'package main\n\nfunc main() {}';
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 300,
          child: CodeHighlightView(
            code: code, path: 'main.go',
            truncated: false, fileSizeBytes: 100),
        ),
      ),
    ));
    expect(
      find.byWidgetPredicate((w) =>
          w is RichText &&
          (w.text as TextSpan).toPlainText().contains('package main')),
      findsOneWidget,
    );
    expect(find.text('1'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });

  testWidgets('空代码 → 渲染空(不崩)', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 300,
          child: CodeHighlightView(
            code: '', path: 'empty.txt',
            truncated: false, fileSizeBytes: 0),
        ),
      ),
    ));
    expect(find.byType(RichText), findsWidgets);
  });

  testWidgets('truncated=true → 底部显示截断条', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 400,
          child: CodeHighlightView(
            code: 'hello', path: 'a.go',
            truncated: true, fileSizeBytes: 1024000),
        ),
      ),
    ));
    expect(find.textContaining('1000'), findsOneWidget);
    expect(find.textContaining('KB'), findsOneWidget);
  });

  testWidgets('truncated=false → 无截断条', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 400,
          child: CodeHighlightView(
            code: 'hello', path: 'a.go',
            truncated: false, fileSizeBytes: 100),
        ),
      ),
    ));
    expect(find.textContaining('超过'), findsNothing);
  });

  testWidgets('短代码 → 内容区背景撑满父级', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 300,
          child: CodeHighlightView(
            code: 'hi', path: 'a.go',
            truncated: false, fileSizeBytes: 10),
        ),
      ),
    ));
    final expandeds = tester.widgetList<Expanded>(find.byType(Expanded));
    var found = false;
    for (final exp in expandeds) {
      if (exp.child is ColoredBox) {
        found = true;
        final colored = exp.child as ColoredBox;
        expect(colored.child, isA<SingleChildScrollView>(),
            reason: 'ColoredBox 内应为横向 ScrollView');
        final scroll = colored.child as SingleChildScrollView;
        expect(scroll.scrollDirection, Axis.horizontal);
        expect(scroll.child, isA<Padding>(),
            reason: 'ScrollView 内应为 Padding（不再有 Container color）');
        final padding = scroll.child as Padding;
        expect(padding.child, isA<SelectableRegion>());
        final selRegion = padding.child as SelectableRegion;
        expect(selRegion.child, isA<Text>(),
            reason: 'SelectableRegion 直接子代为 Text.rich(内部展开为 RichText)');
        final text = selRegion.child as Text;
        expect(text.softWrap, isFalse,
            reason: '代码长行不换行(softWrap=false)');
      }
    }
    expect(found, isTrue,
        reason: 'Expanded 的直接子代必须是 ColoredBox（白底撑满）');
  });

  testWidgets('长行不换行 → RichText softWrap=false', (tester) async {
    const longLine = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          height: 200,
          child: CodeHighlightView(
            code: longLine, path: 'a.go',
            truncated: false, fileSizeBytes: 100),
        ),
      ),
    ));
    final richTexts = tester.widgetList<RichText>(find.byType(RichText));
    expect(richTexts.any((rt) => rt.softWrap == false), isTrue);
  });

  testWidgets('代码区被 SelectableRegion 包裹 + 行号在外', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 300,
          child: CodeHighlightView(
            code: 'line1\nline2\nline3', path: 'a.go',
            truncated: false, fileSizeBytes: 100),
        ),
      ),
    ));

    expect(find.byType(SelectableRegion), findsOneWidget);

    for (final n in ['1', '2', '3']) {
      final lineNoInRegion = find.descendant(
        of: find.byType(SelectableRegion),
        matching: find.byWidgetPredicate((w) => w is Text && w.data == n),
      );
      expect(lineNoInRegion, findsNothing,
          reason: '行号 $n 应在 SelectableRegion 外（复制不带行号）');
    }
  });

  testWidgets('长按代码区 → selection 建立(可复制)', (tester) async {
    const code = 'hello world foo bar\nsecond line';
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 300,
          child: CodeHighlightView(
            code: code, path: 'a.go',
            truncated: false, fileSizeBytes: 100),
        ),
      ),
    ));

    // 找到代码区 RenderParagraph（SelectableRegion 内的 RichText）
    final paragraphFinder = find.descendant(
      of: find.byType(SelectableRegion),
      matching: find.byType(RichText),
    );
    final RenderParagraph paragraph =
        tester.renderObject<RenderParagraph>(paragraphFinder);

    // RichText 必须注入 selectionRegistrar，否则长按选词静默失败
    // （Text.rich 内部会调 SelectionContainer.maybeOf 自动注入）
    final richText = tester.widget<RichText>(paragraphFinder);
    expect(richText.selectionRegistrar, isNotNull,
        reason: 'RichText 需 selectionRegistrar 才能参与选择');

    // 长按落在第一行文本 box 内
    final rect = tester.getRect(paragraphFinder);
    await tester.longPressAt(rect.topLeft + const Offset(30, 10));
    await tester.pumpAndSettle();

    expect(paragraph.selections, isNotEmpty,
        reason: '长按后应建立文本选区');
  });
}
