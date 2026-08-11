import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/quote.dart';
import 'package:app/widgets/chat/message_quote_block.dart';

void main() {
  group('MessageQuoteBlock', () {
    testWidgets('单行格式:@昵称 + preview 同行(冒号分隔)', (tester) async {
      final quote = Quote(
        messageId: 'm1', senderType: 'user', senderId: 'u1',
        senderName: '洛羽', msgType: 'text', preview: '原文预览',
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MessageQuoteBlock(quote: quote)),
      ));

      expect(find.text('@洛羽'), findsOneWidget);
      expect(find.text('原文预览'), findsOneWidget);
      // 昵称带 @ 前缀(不再是裸昵称)
      expect(find.text('洛羽'), findsNothing);
    });

    testWidgets('Agent 名旁显示「智能体」小标', (tester) async {
      final quote = Quote(
        messageId: 'm1', senderType: 'agent', senderId: 'a1',
        senderName: '小灵', msgType: 'text', preview: '原文',
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MessageQuoteBlock(quote: quote)),
      ));

      expect(find.text('@小灵'), findsOneWidget);
      expect(find.text('智能体'), findsOneWidget);
    });

    testWidgets('user sender 不显示「智能体」标', (tester) async {
      final quote = Quote(
        messageId: 'm1', senderType: 'user', senderId: 'u1',
        senderName: '洛羽', msgType: 'text', preview: '原文',
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MessageQuoteBlock(quote: quote)),
      ));

      expect(find.text('智能体'), findsNothing);
    });

    testWidgets('点击引用块触发 onTap 回调', (tester) async {
      var tapped = false;
      final quote = Quote(
        messageId: 'm1', senderType: 'user', senderId: 'u1',
        senderName: '洛羽', msgType: 'text', preview: '原文',
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MessageQuoteBlock(
          quote: quote,
          onTap: () => tapped = true,
        )),
      ));

      await tester.tap(find.byType(MessageQuoteBlock));
      expect(tapped, isTrue);
    });

    testWidgets('isRevoked=true 时显示「原消息已撤回」', (tester) async {
      final quote = Quote(
        messageId: 'm1', senderType: 'user', senderId: 'u1',
        senderName: '洛羽', msgType: 'text', preview: '原文',
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MessageQuoteBlock(quote: quote, isRevoked: true)),
      ));

      expect(find.text('原消息已撤回'), findsOneWidget);
      expect(find.text('原文'), findsNothing);
    });

    testWidgets('isRevoked=false 时显示 preview', (tester) async {
      final quote = Quote(
        messageId: 'm1', senderType: 'user', senderId: 'u1',
        senderName: '洛羽', msgType: 'text', preview: '原文',
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: MessageQuoteBlock(quote: quote)),
      ));

      expect(find.text('原文'), findsOneWidget);
      expect(find.text('原消息已撤回'), findsNothing);
    });
  });
}
