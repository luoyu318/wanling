import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/widgets/typing_bubble.dart';
import 'package:app/widgets/message_bubble.dart' show BubbleWithTail;

void main() {
  testWidgets('TypingBubble 渲染 BubbleWithTail 内含 "." 字符', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: TypingBubble()),
    ));
    await tester.pump(); // 触发首帧
    expect(find.byType(TypingBubble), findsOneWidget);
    expect(find.byType(BubbleWithTail), findsOneWidget);
    expect(find.textContaining('.'), findsWidgets);
  });

  testWidgets('左对齐（agent 一侧）', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: TypingBubble()),
    ));
    await tester.pump();
    // Align 应该 centerLeft
    final align = tester.widget<Align>(find.byType(Align));
    expect(align.alignment, Alignment.centerLeft);
  });
}
