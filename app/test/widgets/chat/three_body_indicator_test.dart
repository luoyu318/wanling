import 'package:app/widgets/chat/three_body_indicator.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> cleanup(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  testWidgets('indicator 挂载和卸载正常', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 32,
            height: 16,
            child: ThreeBodyIndicator(),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(ThreeBodyIndicator), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
    await cleanup(tester);
  });

  testWidgets('动画推进后 CustomPaint 仍在', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 100,
            height: 50,
            child: ThreeBodyIndicator(),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(CustomPaint), findsWidgets);
    await cleanup(tester);
  });
}
