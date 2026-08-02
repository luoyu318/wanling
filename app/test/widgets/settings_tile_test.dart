import 'package:app/widgets/settings_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('渲染 icon + label + 默认 chevron', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsTile(
          icon: Icons.settings_outlined,
          label: '设置',
          onTap: () {},
        ),
      ),
    ));

    expect(find.byIcon(Icons.settings_outlined), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets('onTap 回调被触发', (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsTile(
          icon: Icons.settings_outlined,
          label: '设置',
          onTap: () => tapped = true,
        ),
      ),
    ));

    await tester.tap(find.text('设置'));
    await tester.pump();
    expect(tapped, isTrue);
  });

  testWidgets('labelColor / iconColor 自定义（删除红）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsTile(
          icon: Icons.delete_outline,
          label: '删除',
          labelColor: const Color(0xFFFA5151),
          iconColor: const Color(0xFFFA5151),
          showDivider: false,
          onTap: () {},
        ),
      ),
    ));

    final icon = tester.widget<Icon>(find.byIcon(Icons.delete_outline));
    expect(icon.color, const Color(0xFFFA5151));

    final label = tester.widget<Text>(find.text('删除'));
    expect(label.style?.color, const Color(0xFFFA5151));
  });

  testWidgets('showDivider=false 时不渲染底部分割线', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsTile(
          icon: Icons.delete_outline,
          label: '删除',
          showDivider: false,
          onTap: () {},
        ),
      ),
    ));

    expect(find.text('删除'), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-tile-divider')), findsNothing);
  });

  testWidgets('showDivider=true（默认）时渲染底部分割线', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsTile(
          icon: Icons.settings_outlined,
          label: '设置',
          onTap: () {},
        ),
      ),
    ));

    expect(find.byKey(const ValueKey('settings-tile-divider')), findsOneWidget);
  });

  testWidgets('trailing 自定义时不渲染默认 chevron', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettingsTile(
          icon: Icons.info_outline,
          label: '关于',
          trailing: const Text('v1.0.0'),
          onTap: () {},
        ),
      ),
    ));

    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.text('v1.0.0'), findsOneWidget);
  });
}
