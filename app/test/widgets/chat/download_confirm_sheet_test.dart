import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wanling_core/utils/file_format.dart';
import 'package:app/widgets/chat/download_confirm_sheet.dart';
import 'package:app/widgets/file_type_icon.dart';

void main() {
  const filename = 'report.pdf';
  const mimeType = 'application/pdf';
  const fileSize = 2048;

  Future<void> pumpSheet(
    WidgetTester tester, {
    VoidCallback? onConfirm,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => ElevatedButton(
              onPressed: () => showModalBottomSheet(
                context: ctx,
                backgroundColor: Colors.white,
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
                ),
                builder: (_) => DownloadConfirmSheet(
                  filename: filename,
                  mimeType: mimeType,
                  fileSize: fileSize,
                  onConfirm: onConfirm ?? () {},
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('DownloadConfirmSheet 渲染', () {
    testWidgets('渲染文件名', (tester) async {
      await pumpSheet(tester);
      expect(find.text(filename), findsOneWidget);
    });

    testWidgets('渲染文件大小', (tester) async {
      await pumpSheet(tester);
      expect(find.text(formatFileSize(fileSize)), findsOneWidget);
    });

    testWidgets('渲染 FileTypeIcon', (tester) async {
      await pumpSheet(tester);
      expect(find.byType(FileTypeIcon), findsOneWidget);
    });

    testWidgets('渲染「下载」按钮', (tester) async {
      await pumpSheet(tester);
      expect(find.text('下载'), findsOneWidget);
    });

    testWidgets('渲染「取消」按钮', (tester) async {
      await pumpSheet(tester);
      expect(find.text('取消'), findsOneWidget);
    });
  });

  testWidgets('点「下载」触发 onConfirm（不 pop）', (tester) async {
    var called = 0;
    await pumpSheet(tester, onConfirm: () => called++);
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
    expect(called, 1);
    // widget 不负责 pop，sheet 仍在
    expect(find.text('下载'), findsOneWidget);
  });

  testWidgets('点「取消」pop sheet', (tester) async {
    await pumpSheet(tester);
    expect(find.text('下载'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('下载'), findsNothing);
  });
}
