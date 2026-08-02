import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/slash_command.dart';
import 'package:app/widgets/chat/message_input_bar.dart';
import 'package:app/widgets/feedback/app_text_selection_toolbar.dart';

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
    expect(find.byIcon(Icons.send), findsOneWidget);
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

  testWidgets('长按 TextField 弹 AppTextSelectionToolbar', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MessageInputBar(
          onSend: (_) {},
          onPickFile: () {},
          onTakePhoto: () {},
          onPickAlbum: () {},
        ),
      ),
    ));

    // 输入文字然后长按选区
    await tester.enterText(find.byType(TextField), 'hello world');
    await tester.pump();

    // 长按触发 contextMenuBuilder
    await tester.longPress(find.byType(TextField));
    await tester.pumpAndSettle(const Duration(milliseconds: 500));

    // 验证是我们的 AppTextSelectionToolbar 而非 Flutter 默认菜单
    // （Flutter 默认 AdaptiveTextSelectionToolbar 也会有「复制」「粘贴」文字,
    //   故用 byType 精确断言我们的组件类型）
    expect(find.byType(AppTextSelectionToolbar), findsOneWidget);
  });

  group('MessageInputBar slash 标签', () {
    testWidgets('setSlash 后显示标签胶囊,输入框聚焦', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageInputBar(
            key: key,
            onSend: (_) {},
            onPickFile: () {},
            onTakePhoto: () {},
            onPickAlbum: () {},
            onSendSlash: (_, __) {},
          ),
        ),
      ));

      const cmd = SlashCommand(
        name: 'review',
        template: '/review',
        description: 'code review',
        source: 'command',
      );
      (key.currentState as dynamic).setSlash(cmd);
      await tester.pump();

      // 标签胶囊显示命令名
      expect(find.textContaining('review'), findsWidgets);
    });

    testWidgets('有 _pendingSlash + 无 args,按发送键触发 onSendSlash(name, "")',
        (tester) async {
      String? sentName;
      String? sentArgs;
      final key = GlobalKey();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageInputBar(
            key: key,
            onSend: (_) {},
            onPickFile: () {},
            onTakePhoto: () {},
            onPickAlbum: () {},
            onSendSlash: (name, args) {
              sentName = name;
              sentArgs = args;
            },
          ),
        ),
      ));

      const cmd = SlashCommand(
          name: 'compact', template: '/compact', description: '', source: 'command');
      (key.currentState as dynamic).setSlash(cmd);
      await tester.pump();

      // 无文本时,有 _pendingSlash 也应显示发送键
      final sendButton = find.byKey(const ValueKey('send'));
      expect(sendButton, findsOneWidget);

      await tester.tap(sendButton);
      await tester.pump();

      expect(sentName, 'compact');
      expect(sentArgs, '');
    });

    testWidgets('有 _pendingSlash + args,按发送键触发 onSendSlash(name, args)',
        (tester) async {
      String? sentName;
      String? sentArgs;
      final key = GlobalKey();

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageInputBar(
            key: key,
            onSend: (_) {},
            onPickFile: () {},
            onTakePhoto: () {},
            onPickAlbum: () {},
            onSendSlash: (name, args) {
              sentName = name;
              sentArgs = args;
            },
          ),
        ),
      ));

      const cmd = SlashCommand(
          name: 'review', template: '/review', description: '', source: 'command');
      (key.currentState as dynamic).setSlash(cmd);
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'commit abc..def');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();

      expect(sentName, 'review');
      expect(sentArgs, 'commit abc..def');
    });

    testWidgets('点 ╳ 取消 _pendingSlash + 清空文本', (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MessageInputBar(
            key: key,
            onSend: (_) {},
            onPickFile: () {},
            onTakePhoto: () {},
            onPickAlbum: () {},
            onSendSlash: (_, __) {},
          ),
        ),
      ));

      const cmd = SlashCommand(
          name: 'review', template: '/review', description: '', source: 'command');
      (key.currentState as dynamic).setSlash(cmd);
      await tester.enterText(find.byType(TextField), 'some args');
      await tester.pump();

      // 找 ╳ 图标按钮(用 Icons.close)
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      // _pendingSlash 清空 → 不再显示标签
      expect(find.textContaining('review'), findsNothing);
      // _inputCtrl 清空
      final textField = tester.widget<TextField>(find.byType(TextField));
      expect(textField.controller!.text, '');
    });
  });
}
