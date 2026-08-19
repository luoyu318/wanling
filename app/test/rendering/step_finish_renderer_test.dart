import 'package:wanling_core/models/msg_type.dart';
import 'package:app/rendering/builtin_renderers.dart';
import 'package:app/rendering/message_content_renderer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    ContentRendererRegistry.reset();
    registerBuiltinRenderers();
  });

  Widget host(Map<String, dynamic> data) => MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ContentRendererRegistry.render(
              MsgType.stepFinish,
              {'msg_type': MsgType.stepFinish.value, 'data': data},
              ctx,
              MessageRenderContext(
                isMe: false,
                baseUrl: 'http://localhost',
                token: 'test',
                isDark: false,
              ),
            ),
          ),
        ),
      );

  group('StepFinishRenderer finished=true(主 session 循环结束)', () {
    testWidgets('只显示 tokens 一行,无对号无已完成', (tester) async {
      await tester.pumpWidget(host({
        'finished': true,
        'reason': 'stop',
        'cost': 0.012,
        'tokens': {
          'input': 100,
          'output': 50,
          'reasoning': 10,
          'cache': {'read': 200, 'write': 0},
          'total': 360,
        },
        'duration': 0,
      }));

      expect(find.text('tokens 0.4k'), findsOneWidget);
      // 不显示对号 / 已完成 / cost / 耗时
      expect(find.byIcon(Icons.check_circle), findsNothing);
      expect(find.text('已完成'), findsNothing);
      expect(find.text('\$0.012'), findsNothing);
    });

    testWidgets('tokens.total=0 时返回 SizedBox.shrink', (tester) async {
      await tester.pumpWidget(host({
        'finished': true,
        'reason': 'stop',
        'cost': 0,
        'tokens': {},
        'duration': 0,
      }));

      expect(find.byType(SizedBox), findsOneWidget);
      expect(find.textContaining('tokens'), findsNothing);
    });

    testWidgets('tokens 字段缺失时返回 SizedBox.shrink', (tester) async {
      await tester.pumpWidget(host({
        'finished': true,
        'reason': 'stop',
        'cost': 0.5,
        'duration': 3.2,
      }));

      expect(find.byType(SizedBox), findsOneWidget);
      expect(find.textContaining('tokens'), findsNothing);
    });
  });

  group('StepFinishRenderer finished!=true(子 session / 历史元信息)', () {
    testWidgets('显示 ⏱/tokens/cost 元信息行(无已完成标识)', (tester) async {
      await tester.pumpWidget(host({
        'reason': 'stop',
        'cost': 0.012,
        'tokens': {'total': 360},
        'duration': 0,
      }));

      expect(find.text('已完成'), findsNothing);
      expect(find.byIcon(Icons.check_circle), findsNothing);
      expect(find.text('tokens 0.4k'), findsOneWidget);
      expect(find.text('\$0.012'), findsOneWidget);
    });

    testWidgets('全空数据返回 SizedBox.shrink', (tester) async {
      await tester.pumpWidget(host({
        'reason': '',
        'cost': 0,
        'tokens': {},
        'duration': 0,
      }));

      expect(find.byType(SizedBox), findsOneWidget);
      expect(find.textContaining('tokens'), findsNothing);
      expect(find.textContaining('已完成'), findsNothing);
    });
  });
}
