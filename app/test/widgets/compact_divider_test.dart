import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/widgets/chat/compact_divider.dart';

void main() {
  group('CompactDivider', () {
    testWidgets('phase=done 显示"上下文压缩完成"', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CompactDivider(phase: 'done'))),
      );
      expect(find.text('上下文压缩完成'), findsOneWidget);
    });

    testWidgets('phase=failed 显示"压缩失败"', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CompactDivider(phase: 'failed'))),
      );
      expect(find.text('压缩失败'), findsOneWidget);
    });

    testWidgets('phase=running 显示"正在压缩对话历史" + 文本前后各一组呼吸动画', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CompactDivider(phase: 'running'))),
      );
      await tester.pump(); // 启动动画
      expect(find.textContaining('正在压缩对话历史'), findsOneWidget);
      // running 态文本前后各一组 _BreathingDots(每组 3 个圆点 Container,共 6 个)
      final dots = find.byWidgetPredicate(
        (w) => w is Container && (w.decoration is BoxDecoration),
      ).evaluate();
      // 过滤出圆形 4x4 的呼吸点
      final breathingDots = dots.where((element) {
        final w = element.widget as Container;
        final d = w.decoration as BoxDecoration;
        return d.shape == BoxShape.circle && (w.constraints?.maxWidth == 4);
      }).toList();
      expect(breathingDots.length, 6);
    });

    testWidgets('两侧有 Divider 横线', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: CompactDivider(phase: 'done'))),
      );
      expect(find.byType(Divider), findsNWidgets(2));
    });
  });
}
