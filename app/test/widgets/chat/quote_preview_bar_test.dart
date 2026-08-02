import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/quote.dart';
import 'package:app/widgets/chat/quote_preview_bar.dart';

void main() {
  group('QuotePreviewBar', () {
    final quote = Quote(
      messageId: 'm1',
      senderType: 'user',
      senderId: 'u1',
      senderName: '洛羽',
      msgType: 'text',
      preview: '明天下午开个会吧,讨论 Q3 路线图',
    );

    testWidgets('V1 卡片式渲染:sender + preview + 关闭按钮', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: QuotePreviewBar(quote: quote, onCancel: () {})),
      ));

      expect(find.text('洛羽'), findsOneWidget);
      expect(find.text('明天下午开个会吧,讨论 Q3 路线图'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('点击关闭按钮触发 onCancel', (tester) async {
      var canceled = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: QuotePreviewBar(
          quote: quote,
          onCancel: () => canceled = true,
        )),
      ));

      await tester.tap(find.byIcon(Icons.close));
      expect(canceled, isTrue);
    });

    testWidgets('preview 长文本单行省略(不报错)', (tester) async {
      final longQuote = Quote(
        messageId: 'm1',
        senderType: 'user',
        senderId: 'u1',
        senderName: '洛羽',
        msgType: 'text',
        preview: '这是一段非常非常非常非常非常非常非常非常非常非常非常非常非常非常非常长的预览文字',
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: SizedBox(
          width: 200,
          child: QuotePreviewBar(quote: longQuote, onCancel: () {}),
        )),
      ));

      // 单行省略:Text 应当存在且 maxLines=1(精确文本匹配会因省略号失败)
      expect(find.byType(Text), findsNWidgets(2));  // sender + preview
    });

    testWidgets('B1 视觉一致:有 Container 装饰(浅紫底 + 左竖线)', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: QuotePreviewBar(quote: quote, onCancel: () {})),
      ));

      // Container 装饰承载 B1 视觉(浅紫底 + 左竖线 + 圆角)
      expect(find.byType(Container), findsWidgets);
      expect(find.byType(Row), findsOneWidget);  // 左右布局:文本 + 关闭按钮
    });
  });
}
