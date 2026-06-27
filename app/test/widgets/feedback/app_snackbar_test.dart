import 'package:app/widgets/feedback/app_snackbar.dart';
import 'package:app/widgets/message_input_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('渲染 message 文字 + logo icon', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Column(
          children: [
            const Expanded(child: SizedBox()),
            MessageInputBar(
              onSend: (_) {},
              onPickFile: () {},
              onTakePhoto: () {},
              onPickAlbum: () {},
            ),
          ],
        ),
      ),
    ));

    showAppSnackBar(tester.element(find.byType(Scaffold)), '已保存到相册');
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('已保存到相册'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('无 MessageInputBar 时也能渲染（降级贴底）', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: const SizedBox()),
    ));

    showAppSnackBar(tester.element(find.byType(Scaffold)), '提示');
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('提示'), findsOneWidget);
  });

  testWidgets('2 秒后自动消失', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: const SizedBox()),
    ));

    showAppSnackBar(tester.element(find.byType(Scaffold)), '消失测试');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('消失测试'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2, milliseconds: 100));
    await tester.pumpAndSettle();

    expect(find.text('消失测试'), findsNothing);
  });
}
