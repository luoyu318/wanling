import 'package:app/rendering/footer_info_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Map<String, dynamic> data) {
  return MaterialApp(
    home: Scaffold(body: FooterInfoBar(data: data)),
  );
}

void main() {
  group('FooterInfoBar 四要素', () {
    testWidgets('完整四要素渲染:模式+时长 | 模型+tokens', (tester) async {
      await tester.pumpWidget(host({
        'mode': 'build',
        'duration': 12300,
        'model': 'DeepSeek-V3',
        'tokens': {'total': 2100},
      }));
      expect(find.text('build'), findsOneWidget);
      expect(find.text('12.3s'), findsOneWidget);
      expect(find.text('DeepSeek-V3'), findsOneWidget);
      expect(find.text('tokens 2.1k'), findsOneWidget);
    });

    testWidgets('四要素语义色区分:mode深灰/duration绿/model蓝/tokens橙', (tester) async {
      await tester.pumpWidget(host({
        'mode': 'build',
        'duration': 12300,
        'model': 'DeepSeek-V3',
        'tokens': {'total': 2100},
      }));
      Color? textColor(String text) {
        final t = tester.widget<Text>(find.text(text));
        return t.style?.color;
      }

      expect(textColor('build'), const Color(0xFF666666)); // 模式:深灰
      expect(textColor('12.3s'), const Color(0xFF07C160)); // 耗时:绿
      expect(textColor('DeepSeek-V3'), const Color(0xFF5B8BF7)); // 模型:蓝
      expect(textColor('tokens 2.1k'), const Color(0xFFFA8C16)); // 用量:橙
    });

    testWidgets('缺 mode/model 时只显示时长/tokens 段', (tester) async {
      await tester.pumpWidget(host({
        'duration': 5000,
        'tokens': {'total': 800},
      }));
      expect(find.text('5.0s'), findsOneWidget);
      expect(find.text('tokens 0.8k'), findsOneWidget);
      expect(find.text('build'), findsNothing);
    });

    testWidgets('时长/tokens 缺省时隐藏相应段', (tester) async {
      await tester.pumpWidget(host({'mode': 'plan', 'model': 'M1'}));
      expect(find.text('plan'), findsOneWidget);
      expect(find.text('M1'), findsOneWidget);
      expect(find.textContaining('s'), findsNothing);
      expect(find.textContaining('tokens'), findsNothing);
    });

    testWidgets('静态信息条顶部有分隔线', (tester) async {
      await tester.pumpWidget(host({
        'mode': 'build', 'duration': 12300, 'model': 'DeepSeek-V3', 'tokens': {'total': 2100},
      }));
      final container = tester.widget<Container>(
        find.byWidgetPredicate((w) =>
            w is Container &&
            (w.decoration as BoxDecoration?)?.color == const Color(0xFFF7F7F7)),
      );
      final deco = container.decoration! as BoxDecoration;
      expect(deco.border, isNotNull);
      expect(deco.border!.top, const BorderSide(color: Color(0xFFF0F0F0)));
    });

    testWidgets('四要素全空时渲染空(不显示空通栏)', (tester) async {
      await tester.pumpWidget(host(const {}));
      // 无 mode/duration/model/tokens → SizedBox.shrink,不渲染 Container 通栏
      expect(find.byType(Container), findsNothing);
    });
  });

  group('FooterInfoBar 停止态', () {
    testWidgets('stopped=true 显示已停止,不显示 tokens', (tester) async {
      await tester.pumpWidget(host({
        'stopped': true,
        'reason': 'stop',
        'tokens': {'total': 2100},
      }));
      expect(find.text('已停止'), findsOneWidget);
      expect(find.textContaining('tokens'), findsNothing);
    });

    testWidgets('非 stopped 正常显示 tokens 汇总', (tester) async {
      await tester.pumpWidget(host({
        'stopped': false,
        'tokens': {'total': 1500},
      }));
      expect(find.text('已停止'), findsNothing);
      expect(find.text('tokens 1.5k'), findsOneWidget);
    });
  });
}
