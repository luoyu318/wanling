import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/widgets/message_input_bar.dart';

void main() {
  // 构造一个最小可用的 MessageInputBar,所有回调空实现。
  Widget buildBar() => MaterialApp(
        home: Scaffold(
          body: MessageInputBar(
            onSend: (_) {},
            onPickFile: () {},
            onTakePhoto: () {},
            onPickAlbum: () {},
          ),
        ),
      );

  testWidgets('空内容显示加号,不显示发送', (tester) async {
    await tester.pumpWidget(buildBar());
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.text('发送'), findsNothing);
  });

  testWidgets('输入文字后显示发送按钮,加号消失', (tester) async {
    await tester.pumpWidget(buildBar());
    await tester.enterText(find.byType(TextField), '你好');
    // AnimatedSwitcher 切换有 150ms 过渡,pumpAndSettle 等动画结束。
    await tester.pumpAndSettle();
    expect(find.text('发送'), findsOneWidget);
    expect(find.byIcon(Icons.add), findsNothing);
  });

  testWidgets('点加号展开面板,显示拍照/相册/文件(无图片)', (tester) async {
    await tester.pumpWidget(buildBar());
    expect(find.text('拍照'), findsNothing);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('拍照'), findsOneWidget);
    expect(find.text('相册'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);
    expect(find.text('图片'), findsNothing); // 图片已移除
  });

  testWidgets('点面板某格触发回调并收起面板', (tester) async {
    bool photoCalled = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageInputBar(
          onSend: (_) {},
          onPickFile: () {},
          onTakePhoto: () => photoCalled = true,
          onPickAlbum: () {},
        ),
      ),
    ));
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    await tester.tap(find.text('拍照'));
    await tester.pumpAndSettle();
    expect(photoCalled, isTrue);
    expect(find.text('拍照'), findsNothing); // 面板已收起
  });

  testWidgets('输入框获焦时面板自动收起(键盘↔面板互斥)', (tester) async {
    await tester.pumpWidget(buildBar());
    // 先展开面板
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.text('拍照'), findsOneWidget);
    // 点击输入框获焦 → 面板应收起
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(find.text('拍照'), findsNothing);
  });
}
