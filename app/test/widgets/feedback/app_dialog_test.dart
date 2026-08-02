import 'package:app/widgets/feedback/app_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('点击主按钮触发 onConfirm 并关闭', (tester) async {
    var confirmed = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              await showAppDialog(
                context: ctx,
                title: '确认',
                content: const Text('确认执行？'),
                onConfirm: () => confirmed = true,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('确认'), findsOneWidget);
    expect(find.text('确认执行？'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(confirmed, isTrue);
    expect(find.text('确认'), findsNothing);
  });

  testWidgets('点击取消关闭但不触发 onConfirm', (tester) async {
    var confirmed = false;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              await showAppDialog(
                context: ctx,
                title: '确认',
                content: const Text('确认？'),
                onConfirm: () => confirmed = true,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(confirmed, isFalse);
    expect(find.text('确认'), findsNothing);
  });

  testWidgets('自定义 confirmText', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: ElevatedButton(
            onPressed: () async {
              await showAppDialog(
                context: ctx,
                title: '删除',
                content: const Text('确认删除？'),
                confirmText: '删除',
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('删除'), findsNWidgets(2)); // title + button
  });

  testWidgets('dismissOnConfirm=false 时点主按钮不关闭 dialog', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: ElevatedButton(
            onPressed: () => showAppDialog(
              context: ctx,
              title: '测试',
              content: const Text('content'),
              dismissOnConfirm: false,
              onConfirm: () {},
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('测试'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // dismissOnConfirm=false → dialog 仍存在
    expect(find.text('测试'), findsOneWidget);
  });

  testWidgets('dismissOnConfirm=true(默认)时点主按钮关闭 dialog', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: ElevatedButton(
            onPressed: () => showAppDialog(
              context: ctx,
              title: '测试',
              content: const Text('content'),
              onConfirm: () {},
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('测试'), findsOneWidget);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // 默认 → dialog 关闭
    expect(find.text('测试'), findsNothing);
  });
}
