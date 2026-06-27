import 'package:app/widgets/markdown_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown_widget/markdown_widget.dart';

void main() {
  // markdownStyle 需要必填 context（图片点击导航用），用 Builder 在 widget
  // 树里拿到 context 构造 config 再断言。不需要 pump 渲染 MarkdownView，
  // 只验证返回的 MarkdownConfig 里 H1/H2/H3 配置规格。
  MarkdownConfig buildStyle(BuildContext context, {required bool isDark}) =>
      markdownStyle(
        isDark: isDark,
        context: context,
        baseUrl: '',
        token: '',
      );

  group('markdownStyle 标题规格（亮色）', () {
    testWidgets('H1 = 21/w600/#222', (tester) async {
      late final MarkdownConfig style;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              style = buildStyle(context, isDark: false);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final h1 = style.h1;
      expect(h1.style.fontSize, 21);
      expect(h1.style.fontWeight, FontWeight.w600);
      expect(h1.style.color, const Color(0xFF222222));
    });

    testWidgets('H2 = 19/w500/#222', (tester) async {
      late final MarkdownConfig style;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              style = buildStyle(context, isDark: false);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final h2 = style.h2;
      expect(h2.style.fontSize, 19);
      expect(h2.style.fontWeight, FontWeight.w500);
      expect(h2.style.color, const Color(0xFF222222));
    });

    testWidgets('H3 = 17/w500/#222', (tester) async {
      late final MarkdownConfig style;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              style = buildStyle(context, isDark: false);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final h3 = style.h3;
      expect(h3.style.fontSize, 17);
      expect(h3.style.fontWeight, FontWeight.w500);
      expect(h3.style.color, const Color(0xFF222222));
    });
  });

  group('markdownStyle 标题规格（暗色）', () {
    testWidgets('H1/H2/H3 暗色 = #E8E8E8', (tester) async {
      late final MarkdownConfig style;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              style = buildStyle(context, isDark: true);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(style.h1.style.color, const Color(0xFFE8E8E8));
      expect(style.h2.style.color, const Color(0xFFE8E8E8));
      expect(style.h3.style.color, const Color(0xFFE8E8E8));
    });
  });
}
