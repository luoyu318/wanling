// ConvSlidable 组件测试:纯色按钮渲染、extentRatio 档位、左滑点击触发回调。
// 注:flutter_slidable 3.1.2 的 action pane 懒构建,断言前须先左滑展开。
import 'package:app/widgets/conv_slidable.dart';
import 'package:flutter/material.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pump(
    WidgetTester tester, {
    required List<SlideActionSpec> actions,
    required Widget child,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SlidableAutoCloseBehavior(
          child: ListView(
            children: [
              ConvSlidable(
                slideKey: const ValueKey('slide_test'),
                actions: actions,
                child: child,
              ),
            ],
          ),
        ),
      ),
    ));
  }

  Future<void> openLeft(WidgetTester tester) async {
    // 拖距须超过 pane 宽度一半才会展开(3 按钮 0.6*800/2=240,取 -300)。
    await tester.drag(find.byKey(const ValueKey('slide_test')),
        const Offset(-300, 0));
    await tester.pumpAndSettle();
  }

  SlideActionSpec navAction() => SlideActionSpec(
        icon: Icons.dock,
        label: '固定到底栏',
        color: const Color(0xFF3C7CF7),
        onTap: () async {},
      );
  SlideActionSpec pinAction({void Function()? onFire}) => SlideActionSpec(
        icon: Icons.vertical_align_top,
        label: '置顶',
        color: const Color(0xFFFFA426),
        onTap: () async => onFire?.call(),
      );
  SlideActionSpec hideAction() => SlideActionSpec(
        icon: Icons.delete_outline,
        label: '删除会话',
        color: const Color(0xFFFA5151),
        onTap: () async {},
      );

  testWidgets('渲染 3 个纯色按钮:icon/label/颜色/档位正确', (tester) async {
    await pump(tester,
        actions: [navAction(), pinAction(), hideAction()],
        child: const SizedBox(height: 72));
    await openLeft(tester);

    // 3.1.2 无 SlidableAction(labelStyle:),用 CustomSlidableAction 自绘按钮。
    final acts = tester
        .widgetList<CustomSlidableAction>(find.byType(CustomSlidableAction))
        .toList();
    expect(acts, hasLength(3));
    expect(acts[0].backgroundColor, const Color(0xFF3C7CF7));
    expect(acts[0].foregroundColor, Colors.white);
    expect(acts[2].backgroundColor, const Color(0xFFFA5151));
    // 按钮布局:icon 上、文字下,白字 11sp(间距自绘 SizedBox 4.0)。
    expect(find.byIcon(Icons.dock), findsOneWidget);
    expect(find.byIcon(Icons.vertical_align_top), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
    expect(find.text('固定到底栏'), findsOneWidget);
    expect(find.text('删除会话'), findsOneWidget);
    final labelText = tester.widget<Text>(find.text('置顶'));
    expect(labelText.style?.fontSize, 11);
    expect(labelText.style?.color, Colors.white);
    // 3 按钮 extentRatio 0.6。
    expect(
        tester.widget<ActionPane>(find.byType(ActionPane)).extentRatio, 0.6);
  });

  testWidgets('2 按钮档位 0.4;左滑展开后点击触发回调并自动收起', (tester) async {
    var fired = false;
    await pump(
      tester,
      actions: [
        pinAction(onFire: () => fired = true),
        hideAction(),
      ],
      child: const SizedBox(height: 72, child: Center(child: Text('tile'))),
    );

    // 左滑展开,点击「置顶」:autoClose 先收起再回调。
    await openLeft(tester);
    expect(
        tester.widget<ActionPane>(find.byType(ActionPane)).extentRatio, 0.4);
    await tester.tap(find.text('置顶'));
    await tester.pumpAndSettle();
    expect(fired, isTrue);
  });
}
