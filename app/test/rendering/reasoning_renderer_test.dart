import 'package:app/rendering/builtin_renderers.dart';
import 'package:app/rendering/message_content_renderer.dart';
import 'package:app/models/msg_type.dart';
import 'package:app/widgets/markdown_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    ContentRendererRegistry.reset();
    registerBuiltinRenderers();
  });

  Widget host({required String text, required bool isStreaming}) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ContentRendererRegistry.render(
            MsgType.reasoning,
            {
              'msg_type': MsgType.reasoning.value,
              'data': {'text': text},
            },
            ctx,
            MessageRenderContext(
              isMe: false,
              baseUrl: 'http://localhost',
              token: 'test',
              isDark: false,
              isStreaming: isStreaming,
            ),
          ),
        ),
      ),
    );
  }

  group('ReasoningRenderer 终态 (isStreaming=false)', () {
    testWidgets('显示真实 text 预览', (tester) async {
      await tester.pumpWidget(host(text: '一段思考内容', isStreaming: false));
      expect(find.text('一段思考内容'), findsOneWidget);
    });

    testWidgets('✨ icon opacity 0.6 淡化', (tester) async {
      await tester.pumpWidget(host(text: 'x', isStreaming: false));
      final opacity = tester.widget<Opacity>(find.byType(Opacity));
      expect(opacity.opacity, 0.6);
    });

    testWidgets('白底 + #EEEEEE 边框', (tester) async {
      await tester.pumpWidget(host(text: 'x', isStreaming: false));
      final container = tester.widget<Container>(find.byType(Container));
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, Colors.white);
      final border = deco.border as BoxBorder;
      // Border.all 上下左右同色
      expect(border.top.color, const Color(0xFFEEEEEE));
    });
  });

  group('ReasoningRenderer 空文本守卫', () {
    testWidgets('空文本返 SizedBox.shrink', (tester) async {
      await tester.pumpWidget(host(text: '', isStreaming: false));
      expect(find.byType(SizedBox), findsOneWidget);
      expect(find.byType(Container), findsNothing);
    });
  });

  group('ReasoningRenderer 流式态 (isStreaming=true)', () {
    testWidgets('显示「正在思考...」固定文案', (tester) async {
      await tester.pumpWidget(host(text: '累积的流式文本', isStreaming: true));
      expect(find.text('正在思考...'), findsOneWidget);
      // 流式态不显示累积 text(避免半截文本抖动)
      expect(find.text('累积的流式文本'), findsNothing);
    });

    testWidgets('✨ icon 存在', (tester) async {
      await tester.pumpWidget(host(text: 'x', isStreaming: true));
      expect(find.text('✨ '), findsOneWidget);
    });

    testWidgets('白底 + #EEEEEE 边框', (tester) async {
      await tester.pumpWidget(host(text: 'x', isStreaming: true));
      // 流式卡外层白底 Container,取树序首个
      final container = tester.widgetList<Container>(find.byType(Container)).first;
      final deco = container.decoration as BoxDecoration;
      expect(deco.color, Colors.white);
      final border = deco.border as BoxBorder;
      expect(border.top.color, const Color(0xFFEEEEEE));
    });

    testWidgets('✨ 闪烁动画:opacity 随时间正弦变化', (tester) async {
      await tester.pumpWidget(host(text: 'x', isStreaming: true));
      // 周期 1800ms,opacity = 0.25 + 0.75*(sin(2πt)*0.5+0.5)
      //  pump 450ms (t=0.25): sin(π/2)=1   → opacity=1.0
      //  pump 1350ms(t=0.75): sin(3π/2)=-1 → opacity=0.25
      await tester.pump(const Duration(milliseconds: 450));
      expect(find.byType(Opacity), findsOneWidget);
      expect(
        tester.widget<Opacity>(find.byType(Opacity)).opacity,
        closeTo(1.0, 0.05),
      );
      await tester.pump(const Duration(milliseconds: 900));
      expect(
        tester.widget<Opacity>(find.byType(Opacity)).opacity,
        closeTo(0.25, 0.05),
      );
    });
  });

  group('ReasoningRenderer 抽屉(两态共用)', () {
    testWidgets('终态点击弹抽屉看全文', (tester) async {
      await tester.pumpWidget(host(text: '完整思考内容', isStreaming: false));
      await tester.tap(find.byType(GestureDetector));
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownView), findsOneWidget);
      expect(find.text('思考链'), findsOneWidget);
    });

    testWidgets('流式态点击弹抽屉看全文', (tester) async {
      await tester.pumpWidget(host(text: '流式累积文本', isStreaming: true));
      await tester.tap(find.byType(GestureDetector));
      // 用 pump(Duration) 而非 pumpAndSettle:流式卡的 AnimationController..repeat()
      // 永不停歇,pumpAndSettle 会超时。1s 足够让底部抽屉的进入动画(默认 ~300ms)播完。
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(find.byType(MarkdownView), findsOneWidget);
    });
  });
}
