import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show BoxDecoration;
import 'package:flutter_test/flutter_test.dart';
import 'package:app/theme/app_menu_style.dart';
import 'package:app/widgets/message_context_menu.dart';

void main() {
  // 共享构造:统一传 onRecall(已 required),按需覆盖 canRecall。
  MessageContextMenu buildMenu({
    double left = 0,
    double top = 0,
    double tailOffsetX = 75,
    bool pointDown = true,
    bool canRecall = false,
    required VoidCallback onCopy,
    required VoidCallback onDelete,
    required VoidCallback onRecall,
    required VoidCallback onSelect,
    required VoidCallback onDismiss,
  }) {
    return MessageContextMenu(
      left: left,
      top: top,
      tailOffsetX: tailOffsetX,
      pointDown: pointDown,
      canRecall: canRecall,
      onCopy: onCopy,
      onDelete: onDelete,
      onRecall: onRecall,
      onSelect: onSelect,
      onDismiss: onDismiss,
    );
  }

  testWidgets('canRecall=false 默认三项:复制/删除/多选', (tester) async {
    bool? copyCalled, deleteCalled, selectCalled;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            buildMenu(
              canRecall: false,
              onCopy: () => copyCalled = true,
              onDelete: () => deleteCalled = true,
              onRecall: () => fail('撤回按钮 canRecall=false 时不该触发'),
              onSelect: () => selectCalled = true,
              onDismiss: () {},
            ),
          ],
        ),
      ),
    ));
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('多选'), findsOneWidget);
    expect(find.text('撤回'), findsNothing);

    await tester.tap(find.text('复制'));
    expect(copyCalled, isTrue);

    await tester.tap(find.text('删除'));
    expect(deleteCalled, isTrue);

    await tester.tap(find.text('多选'));
    expect(selectCalled, isTrue);
  });

  testWidgets('canRecall=true 显示四项:复制/删除/撤回/多选', (tester) async {
    bool? recallCalled;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            buildMenu(
              canRecall: true,
              onCopy: () {},
              onDelete: () {},
              onRecall: () => recallCalled = true,
              onSelect: () {},
              onDismiss: () {},
            ),
          ],
        ),
      ),
    ));
    expect(find.text('复制'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('撤回'), findsOneWidget);
    expect(find.text('多选'), findsOneWidget);

    await tester.tap(find.text('撤回'));
    expect(recallCalled, isTrue);
  });

  testWidgets('点外部遮罩触发 onDismiss', (tester) async {
    bool dismissed = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 300,
          height: 400,
          child: Stack(
            children: [
              buildMenu(
                onCopy: () {},
                onDelete: () {},
                onRecall: () {},
                onSelect: () {},
                onDismiss: () => dismissed = true,
              ),
            ],
          ),
        ),
      ),
    ));
    // 点菜单外的区域(右下角)
    await tester.tapAt(const Offset(290, 390));
    expect(dismissed, isTrue);
  });

  testWidgets('删除项用红色 icon', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            buildMenu(
              onCopy: () {},
              onDelete: () {},
              onRecall: () {},
              onSelect: () {},
              onDismiss: () {},
            ),
          ],
        ),
      ),
    ));
    final deleteIcon = tester.widget<Icon>(find.byIcon(Icons.delete_outline));
    expect(deleteIcon.color, AppMenuStyle.darkDanger);
    final copyIcon = tester.widget<Icon>(find.byIcon(Icons.content_copy));
    expect(copyIcon.color, AppMenuStyle.darkFg);
  });

  testWidgets('canRecall=true 时撤回按钮用红色 icon', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            buildMenu(
              canRecall: true,
              onCopy: () {},
              onDelete: () {},
              onRecall: () {},
              onSelect: () {},
              onDismiss: () {},
            ),
          ],
        ),
      ),
    ));
    final recallIcon = tester.widget<Icon>(find.byIcon(Icons.undo));
    expect(recallIcon.color, AppMenuStyle.darkDanger);
  });

  testWidgets('菜单背景色 = AppMenuStyle.darkBg', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            buildMenu(
              left: 50,
              top: 100,
              onCopy: () {},
              onDelete: () {},
              onRecall: () {},
              onSelect: () {},
              onDismiss: () {},
            ),
          ],
        ),
      ),
    ));
    await tester.pump();

    // 找到 _MenuBody 内的 Container，断言背景色等于 AppMenuStyle.darkBg
    final container = tester.widget<Container>(
      find.byWidgetPredicate((w) =>
          w is Container &&
          (w.decoration is BoxDecoration) &&
          ((w.decoration as BoxDecoration).color == AppMenuStyle.darkBg)).first,
    );
    expect(container, isNotNull);
  });

  group('定位参数与圆角', () {
    Future<void> pumpMenu(
      WidgetTester tester, {
      required bool pointDown,
      bool canRecall = false,
    }) {
      return tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              buildMenu(
                left: 10,
                top: 20,
                tailOffsetX: 75,
                pointDown: pointDown,
                canRecall: canRecall,
                onCopy: () {},
                onDelete: () {},
                onRecall: () {},
                onSelect: () {},
                onDismiss: () {},
              ),
            ],
          ),
        ),
      ));
    }

    testWidgets('菜单容器圆角 = AppMenuStyle.radiusAnchor', (tester) async {
      await pumpMenu(tester, pointDown: true);
      final container = tester.widget<Container>(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).color == AppMenuStyle.darkBg,
        ),
      );
      final deco = container.decoration as BoxDecoration;
      expect(deco.borderRadius,
          BorderRadius.circular(AppMenuStyle.radiusAnchor));
    });

    testWidgets('pointDown=true 正常渲染三项（不抛异常）', (tester) async {
      await pumpMenu(tester, pointDown: true);
      expect(find.byIcon(Icons.content_copy), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    });

    testWidgets('pointDown=false 正常渲染三项（不抛异常）', (tester) async {
      await pumpMenu(tester, pointDown: false);
      expect(find.byIcon(Icons.content_copy), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    });

    testWidgets('canRecall=true 渲染 4 项', (tester) async {
      await pumpMenu(tester, pointDown: true, canRecall: true);
      expect(find.byIcon(Icons.content_copy), findsOneWidget);
      expect(find.byIcon(Icons.delete_outline), findsOneWidget);
      expect(find.byIcon(Icons.undo), findsOneWidget); // 撤回
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    });
  });
}
