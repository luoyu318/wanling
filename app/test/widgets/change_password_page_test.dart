import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/pages/change_password_page.dart';

void main() {
  testWidgets('两个密码输入框 + 提交按钮存在', (tester) async {
    await tester.pumpWidget(MaterialApp(home: const ChangePasswordPage()));
    expect(find.text('新密码'), findsOneWidget);
    expect(find.text('确认密码'), findsOneWidget);
    expect(find.text('提交'), findsOneWidget);
  });

  testWidgets('两次密码不一致时不允许提交', (tester) async {
    await tester.pumpWidget(MaterialApp(home: const ChangePasswordPage()));
    await tester.enterText(find.byType(TextField).at(0), 'newpw123');
    await tester.enterText(find.byType(TextField).at(1), 'different');
    await tester.tap(find.text('提交'));
    await tester.pump();
    expect(find.textContaining('两次输入不一致'), findsOneWidget);
  });

  testWidgets('密码短于 6 位时不允许提交', (tester) async {
    await tester.pumpWidget(MaterialApp(home: const ChangePasswordPage()));
    await tester.enterText(find.byType(TextField).at(0), '123');
    await tester.enterText(find.byType(TextField).at(1), '123');
    await tester.tap(find.text('提交'));
    await tester.pump();
    expect(find.textContaining('至少 6 位'), findsOneWidget);
  });
}
