import 'package:app/rendering/footer_status_bar.dart';
import 'package:app/widgets/chat/shimmer_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> el(String type, String id) {
  return {'type': type, 'element_id': id, 'data': const {}};
}

void main() {
  group('aggregatePhaseText 阶段词推导', () {
    test('最后一个非 footer 元素是 reasoning → 思考中', () {
      expect(aggregatePhaseText([el('reasoning', 'r1')]), '思考中...');
    });
    test('最后元素是 tool_card → 执行中', () {
      expect(
        aggregatePhaseText([el('markdown', 'm1'), el('tool_card', 't1')]),
        '执行中...',
      );
    });
    test('最后元素是 markdown → 汇总中', () {
      expect(
        aggregatePhaseText([el('tool_card', 't1'), el('markdown', 'm1')]),
        '汇总中...',
      );
    });
    test('最后元素是 footer → 看前一个非 footer 元素', () {
      expect(
        aggregatePhaseText([el('reasoning', 'r1'), el('footer', 'f1')]),
        '思考中...',
      );
    });
    test('空 elements → 思考中(默认)', () {
      expect(aggregatePhaseText([]), '思考中...');
    });
  });

  group('FooterStatusBar 动态/静态切换', () {
    testWidgets('generating=true → 渲染 ShimmerText(阶段词逐字符闪烁)', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FooterStatusBar(
            generating: true,
            elements: [el('tool_card', 't1')],
            footerData: const {},
          ),
        ),
      ));
      // ShimmerText 逐字符渲染,断言组件存在 + 首字符可见(阶段词推导由纯函数测试覆盖)
      expect(find.byType(ShimmerText), findsOneWidget);
      expect(find.text('执'), findsOneWidget);
    });

    testWidgets('generating=false → 显示静态 FooterInfoBar(模式/时长)', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: FooterStatusBar(
            generating: false,
            elements: [el('tool_card', 't1')],
            footerData: const {'mode': 'build', 'duration': 12300},
          ),
        ),
      ));
      expect(find.text('build'), findsOneWidget);
      expect(find.text('12.3s'), findsOneWidget);
    });
  });
}
