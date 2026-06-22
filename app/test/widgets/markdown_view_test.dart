import 'package:app/widgets/markdown_config.dart';
import 'package:app/widgets/markdown_latex.dart';
import 'package:app/widgets/markdown_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 通用渲染辅助：包 MaterialApp + 限定宽度（防 MarkdownView 无约束报错）。
  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 300, child: child),
        ),
      );

  group('MarkdownView 基础渲染', () {
    testWidgets('渲染标题文本', (tester) async {
      await tester.pumpWidget(wrap(MarkdownView(
        data: '# 标题',
        config: markdownStyle(isDark: false),
      )));
      expect(find.text('标题'), findsOneWidget);
    });

    testWidgets('渲染段落文本', (tester) async {
      await tester.pumpWidget(wrap(MarkdownView(
        data: '正文段落',
        config: markdownStyle(isDark: false),
      )));
      expect(find.text('正文段落'), findsOneWidget);
    });

    testWidgets('渲染有序列表项', (tester) async {
      await tester.pumpWidget(wrap(MarkdownView(
        data: '1. 第一项\n2. 第二项',
        config: markdownStyle(isDark: false),
      )));
      expect(find.text('第一项'), findsOneWidget);
      expect(find.text('第二项'), findsOneWidget);
    });

    testWidgets('渲染多块：标题 + 段落各自独立', (tester) async {
      await tester.pumpWidget(wrap(MarkdownView(
        data: '# 标题\n\n段落内容',
        config: markdownStyle(isDark: false),
      )));
      expect(find.text('标题'), findsOneWidget);
      expect(find.text('段落内容'), findsOneWidget);
    });

    testWidgets('渲染代码块（含复制按钮图标）', (tester) async {
      await tester.pumpWidget(wrap(MarkdownView(
        data: '```dart\nvoid main() {}\n```',
        config: markdownStyle(isDark: false),
      )));
      // markdown_code_wrapper 注入的复制按钮图标
      expect(find.byIcon(Icons.copy_rounded), findsOneWidget);
    });

    testWidgets('渲染表格', (tester) async {
      await tester.pumpWidget(wrap(MarkdownView(
        data: '| A | B |\n|---|---|\n| 1 | 2 |',
        config: markdownStyle(isDark: false),
      )));
      expect(find.text('A'), findsOneWidget);
      expect(find.text('B'), findsOneWidget);
      expect(find.text('1'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });
  });

  group('MarkdownView LaTeX 集成', () {
    testWidgets('行内 LaTeX 渲染不报错', (tester) async {
      // $E=mc^2$ → 通过 latexGenerator 注入 LatexNode
      final needle = String.fromCharCodes([36, 69, 61, 109, 99, 94, 50, 36]);
      await tester.pumpWidget(wrap(MarkdownView(
        data: needle,
        config: markdownStyle(isDark: false),
        inlineSyntaxes: [LatexSyntax()],
        generators: [latexGenerator],
      )));
      // flutter_math_fork 渲染成 widget，断言不抛异常即可
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('块级 LaTeX 渲染不报错', (tester) async {
      await tester.pumpWidget(wrap(MarkdownView(
        data: r'$$\int_0^1 x\,dx$$',
        config: markdownStyle(isDark: false),
        inlineSyntaxes: [LatexSyntax()],
        generators: [latexGenerator],
      )));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('MarkdownView 不依赖 MarkdownWidget', () {
    testWidgets('不使用 ListView（无滚动容器副作用）', (tester) async {
      await tester.pumpWidget(wrap(MarkdownView(
        data: '正文',
        config: markdownStyle(isDark: false),
      )));
      // Column 而非 ListView
      expect(find.byType(Column), findsOneWidget);
    });
  });
}
