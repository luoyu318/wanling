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
        'duration': 12.3,
        'model': 'DeepSeek-V3',
        'tokens': {'total': 2100},
      }));
      expect(find.text('build'), findsOneWidget);
      expect(find.text('12.3s'), findsOneWidget);
      expect(find.text('DeepSeek-V3'), findsOneWidget);
      expect(find.text('tokens 2.1k'), findsOneWidget);
    });

    testWidgets('缺 mode/model 时只显示时长/tokens 段', (tester) async {
      await tester.pumpWidget(host({
        'duration': 5.0,
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
