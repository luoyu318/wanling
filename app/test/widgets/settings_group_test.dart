import 'package:app/widgets/settings_group.dart';
import 'package:app/widgets/settings_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('渲染白底卡片含多个 SettingsTile', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsGroup(
          children: [
            SettingsTile(icon: Icons.add, label: 'A', onTap: () {}),
            SettingsTile(icon: Icons.remove, label: 'B', onTap: () {}),
          ],
        ),
      ),
    ));

    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.byType(SettingsTile), findsNWidgets(2));
  });

  testWidgets('默认 margin top=8', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsGroup(
          children: [SettingsTile(icon: Icons.add, label: 'A', onTap: () {})],
        ),
      ),
    ));

    final container = tester.widget<Container>(
      find.byKey(const ValueKey('settings-group')),
    );
    final margin = container.margin as EdgeInsets?;
    expect(margin?.top, 8);
  });

  testWidgets('背景色为 white', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsGroup(
          children: [SettingsTile(icon: Icons.add, label: 'A', onTap: () {})],
        ),
      ),
    ));

    final container = tester.widget<Container>(
      find.byKey(const ValueKey('settings-group')),
    );
    final decoration = container.decoration as BoxDecoration?;
    expect(decoration?.color, Colors.white);
  });

  testWidgets('空 children 不崩且渲染白底容器', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SettingsGroup(children: const [])),
    ));

    expect(find.byType(SettingsGroup), findsOneWidget);
    final container = tester.widget<Container>(
      find.byKey(const ValueKey('settings-group')),
    );
    expect((container.decoration as BoxDecoration?)?.color, Colors.white);
  });
}
