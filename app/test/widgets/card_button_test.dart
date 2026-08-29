import 'package:wanling_core/widgets/card_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('disabled 状态 onTap 为 null', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: CardButton(
            label: '允许',
            iconName: 'check',
            style: 'primary',
            state: CardButtonState.disabled,
          ),
        ),
      ),
    );
    final gesture = find.byType(GestureDetector);
    expect((tester.widget(gesture) as GestureDetector).onTap, isNull);
  });

  testWidgets('active 状态可点击触发回调', (tester) async {
    var tapped = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CardButton(
            label: '允许',
            iconName: 'check',
            style: 'primary',
            onTap: () => tapped = true,
          ),
        ),
      ),
    );
    await tester.tap(find.byType(CardButton));
    expect(tapped, isTrue);
  });

  testWidgets('primary/info/danger 三色都对', (tester) async {
    for (final s in ['primary', 'info', 'danger']) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CardButton(label: 'x', iconName: 'check', style: s),
          ),
        ),
      );
      final container = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(CardButton),
              matching: find.byType(Container),
            )
            .first,
      );
      final deco = container.decoration as BoxDecoration;
      final expected = s == 'primary'
          ? const Color(0xFF07C160)
          : s == 'info'
              ? const Color(0xFF1989FA)
              : const Color(0xFFFA5151);
      expect(deco.color, expected);
    }
  });

  testWidgets('disabled 深浅成对:浅色 E0E0E0/9E9E9E,深色 3A3B42/777777', (tester) async {
    Widget host({required bool isDark}) => MaterialApp(
          home: Scaffold(
            body: CardButton(
              label: '允许',
              iconName: 'check',
              style: 'primary',
              state: CardButtonState.disabled,
              isDark: isDark,
            ),
          ),
        );

    // 浅色臂
    await tester.pumpWidget(host(isDark: false));
    var container = tester.widget<Container>(
      find.descendant(of: find.byType(CardButton), matching: find.byType(Container)).first,
    );
    expect((container.decoration as BoxDecoration).color, const Color(0xFFE0E0E0));
    expect(
      (tester.widget<Text>(find.text('允许')).style!).color,
      const Color(0xFF9E9E9E),
    );

    // 深色臂
    await tester.pumpWidget(host(isDark: true));
    container = tester.widget<Container>(
      find.descendant(of: find.byType(CardButton), matching: find.byType(Container)).first,
    );
    expect((container.decoration as BoxDecoration).color, const Color(0xFF3A3B42));
    expect(
      (tester.widget<Text>(find.text('允许')).style!).color,
      const Color(0xFF777777),
    );
  });
}
