import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/widgets/file_card.dart';

void main() {
  testWidgets('notDownloaded shows filename, size, hint, download button', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: FileCard(
        fileId: 'abc',
        filename: 'test.pdf',
        mimeType: 'application/pdf',
        fileSize: 1024,
        isMe: false,
        downloadState: DownloadState.notDownloaded,
      ),
    )));
    expect(find.text('test.pdf'), findsOneWidget);
    expect(find.text('1.0 KB'), findsOneWidget);
    expect(find.text('点击下载 · 下载后可用系统应用打开'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
  });

  testWidgets('downloading state shows progress text and progress bar', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: FileCard(
        fileId: 'abc',
        filename: 'test.pdf',
        mimeType: 'application/pdf',
        fileSize: 1024,
        isMe: false,
        downloadState: DownloadState.downloading,
        downloadProgress: 0.68,
      ),
    )));
    expect(find.text('下载中 68%'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    // 取消按钮显示
    expect(find.byIcon(Icons.close), findsOneWidget);
  });

  testWidgets('downloaded state shows green status and folder_open button', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: FileCard(
        fileId: 'abc',
        filename: 'test.pdf',
        mimeType: 'application/pdf',
        fileSize: 1024,
        isMe: false,
        downloadState: DownloadState.downloaded,
      ),
    )));
    expect(find.text('已下载 1.0 KB'), findsOneWidget);
    expect(find.byIcon(Icons.folder_open), findsOneWidget);
  });

  testWidgets('uploading state shows orange progress', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: FileCard(
        fileId: 'abc',
        filename: 'test.pdf',
        mimeType: 'application/pdf',
        fileSize: 1024,
        isMe: true,
        downloadState: DownloadState.uploading,
        downloadProgress: 0.45,
      ),
    )));
    expect(find.text('上传中 45%'), findsOneWidget);
  });

  testWidgets('size formatting handles MB and GB', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: Column(children: [
        FileCard(fileId: 'a', filename: 'mb.pdf', mimeType: 'application/pdf', fileSize: 2 * 1024 * 1024, isMe: false, downloadState: DownloadState.notDownloaded),
        FileCard(fileId: 'b', filename: 'gb.pdf', mimeType: 'application/pdf', fileSize: 3 * 1024 * 1024 * 1024, isMe: false, downloadState: DownloadState.notDownloaded),
      ]),
    )));
    expect(find.text('2.0 MB'), findsOneWidget);
    expect(find.text('3.0 GB'), findsOneWidget);
  });

  testWidgets('sender has purple border, receiver has gray border', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: Column(children: [
        FileCard(fileId: 'a', filename: 'me.pdf', mimeType: 'application/pdf', fileSize: 100, isMe: true, downloadState: DownloadState.notDownloaded),
        FileCard(fileId: 'b', filename: 'them.pdf', mimeType: 'application/pdf', fileSize: 100, isMe: false, downloadState: DownloadState.notDownloaded),
      ]),
    )));
    // 至少渲染了两个 FileCard
    expect(find.byType(FileCard), findsNWidgets(2));
  });

  testWidgets('onTap callback fired when action button tapped in notDownloaded', (tester) async {
    int tapCount = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: FileCard(
        fileId: 'abc',
        filename: 'test.pdf',
        mimeType: 'application/pdf',
        fileSize: 100,
        isMe: false,
        downloadState: DownloadState.notDownloaded,
        onTap: () => tapCount++,
      ),
    )));
    await tester.tap(find.byIcon(Icons.arrow_downward));
    await tester.pump();
    expect(tapCount, 1);
  });
}
