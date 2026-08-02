import 'package:app/widgets/chat/chat_loading_skeleton.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('渲染 6 个 shimmer 灰块(左右交替)', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: ChatLoadingSkeleton()),
    ));
    await tester.pump();
    expect(find.byType(ChatLoadingSkeleton), findsOneWidget);
    expect(find.byType(ShaderMask), findsNWidgets(6));
  });

  testWidgets('动画推进后 6 块灰块仍在', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: ChatLoadingSkeleton()),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(ShaderMask), findsNWidgets(6));
  });

  testWidgets('卸载正常(无 setState-after-dispose)', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: ChatLoadingSkeleton()),
    ));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ChatLoadingSkeleton), findsNothing);
  });
}
