import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/widgets/app_action_menu.dart';

void main() {
  Future<String?> Function(WidgetTester tester) pumpMenu({
    required List<ActionMenuItem> items,
  }) {
    return (tester) async {
      String? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () async {
                // 按钮中心触发，验证定位
                final box = ctx.findRenderObject() as RenderBox;
                final pos = box.localToGlobal(Offset.zero);
                result = await showAppActionMenu(ctx, pos, items: items);
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return result;
    };
  }

  testWidgets('渲染菜单项 icon 左 + 文字右', (tester) async {
    await pumpMenu(items: const [
      ActionMenuItem(
        value: 'edit',
        label: '编辑',
        icon: Icons.edit_outlined,
      ),
      ActionMenuItem(
        value: 'delete',
        label: '删除',
        icon: Icons.delete_outline,
        color: Color(0xFFFA5151),
      ),
    ])(tester);

    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
  });

  testWidgets('点击菜单项返回对应 value', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              final box = ctx.findRenderObject() as RenderBox;
              final pos = box.localToGlobal(Offset.zero);
              result = await showAppActionMenu(ctx, pos, items: const [
                ActionMenuItem(
                    value: 'edit', label: '编辑', icon: Icons.edit_outlined),
              ]);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(result, 'edit');
  });

  testWidgets('点击空白处关闭返回 null', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              final box = ctx.findRenderObject() as RenderBox;
              final pos = box.localToGlobal(Offset.zero);
              result = await showAppActionMenu(ctx, pos, items: const [
                ActionMenuItem(
                    value: 'edit', label: '编辑', icon: Icons.edit_outlined),
              ]);
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    // 点屏幕右下角空白区(远离菜单)
    await tester.tapAt(const Offset(700, 500));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  testWidgets('危险项 icon 与文字标红', (tester) async {
    await pumpMenu(items: const [
      ActionMenuItem(
        value: 'delete',
        label: '删除',
        icon: Icons.delete_outline,
        color: Color(0xFFFA5151),
      ),
    ])(tester);

    final deleteText = tester.widget<Text>(find.text('删除'));
    expect(deleteText.style?.color, const Color(0xFFFA5151));
    final deleteIcon = tester.widget<Icon>(find.byIcon(Icons.delete_outline));
    expect(deleteIcon.color, const Color(0xFFFA5151));
  });
}
