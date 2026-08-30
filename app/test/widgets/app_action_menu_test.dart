import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/widgets/app_action_menu.dart';

const _menuKey = ValueKey('app-action-menu');

Future<void> _pumpWithButton(WidgetTester tester,
    {required AppMenuAlign align}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      appBar: AppBar(actions: [
        Builder(
          builder: (btnCtx) => IconButton(
            icon: const Icon(Icons.add),
            onPressed: () async {
              final box = btnCtx.findRenderObject()! as RenderBox;
              final pos =
                  box.localToGlobal(Offset(box.size.width, box.size.height));
              await showAppActionMenu(
                btnCtx,
                pos,
                align: align,
                items: const [
                  ActionMenuItem(
                      value: 'scan',
                      label: '扫一扫',
                      icon: Icons.qr_code_scanner),
                ],
              );
            },
          ),
        ),
      ]),
      body: const SizedBox.expand(),
    ),
  ));
}

void main() {
  testWidgets('belowRight:菜单右上角贴按钮右缘,顶部在按钮下方 8px', (tester) async {
    await _pumpWithButton(tester, align: AppMenuAlign.belowRight);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    final btnRect = tester.getRect(find.byType(IconButton));
    final menuRect = tester.getRect(find.byKey(_menuKey));
    expect((menuRect.right - btnRect.right).abs(), lessThanOrEqualTo(1.0));
    expect(menuRect.top, closeTo(btnRect.bottom + 8, 1.0));
  });

  testWidgets('默认 topLeft:菜单左上角对齐传入点(长按语义不变)', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => showAppActionMenu(
                ctx,
                const Offset(100, 120),
                items: const [
                  ActionMenuItem(
                      value: 'scan',
                      label: '扫一扫',
                      icon: Icons.qr_code_scanner),
                ],
              ),
              child: const Text('OPEN'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('OPEN'));
    await tester.pumpAndSettle();
    final menuRect = tester.getRect(find.byKey(_menuKey));
    expect(menuRect.topLeft, const Offset(100, 120));
  });

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
                final box = ctx.findRenderObject()! as RenderBox;
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
              final box = ctx.findRenderObject()! as RenderBox;
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
              final box = ctx.findRenderObject()! as RenderBox;
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
