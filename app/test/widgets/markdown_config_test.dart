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
        isMe: false,
        context: context,
        baseUrl: '',
        token: '',
      );

  group('markdownStyle 标题规格（亮色）', () {
    testWidgets('H1 = 16/w500/#1A365D', (tester) async {
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
      expect(h1.style.fontSize, 16);
      expect(h1.style.fontWeight, FontWeight.w500);
      expect(h1.style.color, const Color(0xFF1A365D));
    });

    testWidgets('H2 = 16/w500/#2C5282', (tester) async {
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
      expect(h2.style.fontSize, 16);
      expect(h2.style.fontWeight, FontWeight.w500);
      expect(h2.style.color, const Color(0xFF2C5282));
    });

    testWidgets('H3 = 16/w500/#2B6CB0', (tester) async {
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
      expect(h3.style.fontSize, 16);
      expect(h3.style.fontWeight, FontWeight.w500);
      expect(h3.style.color, const Color(0xFF2B6CB0));
    });
  });

  // 标题色硬编码(不跟 isDark),暗色与亮色一致
  group('markdownStyle 标题规格（暗色）', () {
    testWidgets('H1/H2/H3 暗色与亮色一致(硬编码色)', (tester) async {
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
      expect(style.h1.style.color, const Color(0xFF1A365D));
      expect(style.h2.style.color, const Color(0xFF2C5282));
      expect(style.h3.style.color, const Color(0xFF2B6CB0));
    });
  });
}
