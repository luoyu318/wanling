import 'package:wanling_core/widgets/countdown_timer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // CountdownTimer 内部 Timer.periodic 永不停歇,禁用 pumpAndSettle,
  // 用 pump(Duration) 推进(参考 reasoning_renderer_test 流式用例)。
  Widget host({required bool isDark}) {
    final expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 5));
    return MaterialApp(
      home: Scaffold(
        body: CountdownTimer(expiresAt: expiresAt, isDark: isDark),
      ),
    );
  }

  testWidgets('剩余时间>0 显示倒计时文本', (tester) async {
    await tester.pumpWidget(host(isDark: false));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('⏱'), findsOneWidget);
  });

  testWidgets('文字灰深浅成对:浅色 999999,深色 777777', (tester) async {
    // 浅色臂
    await tester.pumpWidget(host(isDark: false));
    await tester.pump(const Duration(seconds: 1));
    var text = tester.widget<Text>(find.textContaining('⏱'));
    expect(text.style!.color, const Color(0xFF999999));

    // 深色臂
    await tester.pumpWidget(host(isDark: true));
    await tester.pump(const Duration(seconds: 1));
    text = tester.widget<Text>(find.textContaining('⏱'));
    expect(text.style!.color, const Color(0xFF777777));
  });
}
