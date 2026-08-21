import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_desktop/shell/card_container.dart';
import 'package:wanling_desktop/theme/desktop_theme.dart';

void main() {
  test('主题 token:深浅模式画布/卡片/边框色', () {
    expect(DesktopTheme.canvasColor(Brightness.dark), const Color(0xFF101014));
    expect(DesktopTheme.cardColor(Brightness.dark), const Color(0xFF1A1A20));
    expect(DesktopTheme.cardBorderColor(Brightness.dark), const Color(0xFF2E2E38));
    expect(DesktopTheme.canvasColor(Brightness.light), const Color(0xFFE9EAEC));
    expect(DesktopTheme.cardColor(Brightness.light), const Color(0xFFFFFFFF));
    expect(DesktopTheme.cardBorderColor(Brightness.light), const Color(0xFFDCDCDC));
  });

  testWidgets('CardContainer 渲染 12px 圆角且无外边框', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CardContainer(
            color: DesktopTheme.cardColor(Brightness.dark),
            child: const Text('card'),
          ),
        ),
      ),
    );
    final decor = tester.widget<Container>(
      find.descendant(of: find.byType(CardContainer), matching: find.byType(Container)),
    );
    final box = decor.decoration! as BoxDecoration;
    expect(box.borderRadius, BorderRadius.circular(12));
    // 验收反馈:去掉卡片外部边框线(内部 divider 分割线不受影响)
    expect(box.border, isNull);
  });
}
