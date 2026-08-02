import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/widgets/chat/recalled_bubble.dart';

void main() {
  Future<void> pumpIt(
    WidgetTester tester,
    RecalledBubble widget,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: widget)),
    );
  }

  group('RecalledBubble', () {
    testWidgets('isMe=true 显示「你撤回了一条消息」', (tester) async {
      await pumpIt(tester, const RecalledBubble(isMe: true));
      expect(find.text('你撤回了一条消息'), findsOneWidget);
    });

    testWidgets('isMe=false 单聊场景 显示「对方撤回了一条消息」', (tester) async {
      await pumpIt(
        tester,
        const RecalledBubble(isMe: false, isGroup: false),
      );
      expect(find.text('对方撤回了一条消息'), findsOneWidget);
    });

    testWidgets('isMe=false 群聊 + 有 senderName 显示带名撤回', (tester) async {
      await pumpIt(
        tester,
        const RecalledBubble(
          isMe: false,
          isGroup: true,
          senderName: 'Alice',
        ),
      );
      expect(find.text('Alice 撤回了一条消息'), findsOneWidget);
    });

    testWidgets('isMe=false 群聊 + senderName=null fallback 到「对方撤回了一条消息」',
        (tester) async {
      await pumpIt(
        tester,
        const RecalledBubble(isMe: false, isGroup: true, senderName: null),
      );
      expect(find.text('对方撤回了一条消息'), findsOneWidget);
    });
  });
}
