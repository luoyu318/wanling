import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/widgets/unread_badge.dart';

void main() {
  testWidgets('count=0 渲染 SizedBox.shrink', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: UnreadBadge(count: 0)),
    ));
    expect(find.byType(UnreadBadge), findsOneWidget);
    // 内部应渲染 SizedBox.shrink（无数字文本）
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('count=5 显示 "5"', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: UnreadBadge(count: 5)),
    ));
    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('count=100 显示 "99+"', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: UnreadBadge(count: 100)),
    ));
    expect(find.text('99+'), findsOneWidget);
  });

  testWidgets('count=99 显示 "99"（边界）', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: UnreadBadge(count: 99)),
    ));
    expect(find.text('99'), findsOneWidget);
  });
}
