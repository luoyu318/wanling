import 'package:wanling_core/models/msg_type.dart';
import 'package:app/rendering/builtin_renderers.dart';
import 'package:app/rendering/message_content_renderer.dart';
import 'package:app/widgets/file_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    ContentRendererRegistry.reset();
    registerBuiltinRenderers();
  });

  testWidgets('FileContentRenderer: PDF 渲染 FileCard', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: _RendererHost(
          msgType: MsgType.file,
          data: {
            'file_id': 'abc',
            'filename': 'doc.pdf',
            'mime_type': 'application/pdf',
            'file_size': 1024,
          },
        ),
      ),
    ));
    expect(find.byType(FileCard), findsOneWidget);
    expect(find.text('doc.pdf'), findsOneWidget);
    // notDownloaded 状态文本为文件大小（顶部副标题位）
    expect(find.text('1.0 KB'), findsOneWidget);
    expect(find.text('点击下载 · 下载后可用系统应用打开'), findsOneWidget);
  });

  testWidgets('FileContentRenderer: text/plain 渲染 _TextPreviewCard',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: _RendererHost(
          msgType: MsgType.file,
          data: {
            'file_id': 'abc',
            'filename': 'readme.txt',
            'mime_type': 'text/plain',
            'file_size': 256,
          },
        ),
      ),
    ));
    // _TextPreviewCard 不渲染 FileCard，渲染独立卡片样式
    expect(find.byType(FileCard), findsNothing);
    expect(find.text('readme.txt'), findsOneWidget);
    expect(find.text('256 B'), findsOneWidget);
    expect(find.text('点击预览文本内容'), findsOneWidget);
  });

  testWidgets('FileContentRenderer: text/markdown 走预览卡片', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: _RendererHost(
          msgType: MsgType.file,
          data: {
            'file_id': 'abc',
            'filename': 'notes.md',
            'mime_type': 'text/markdown',
            'file_size': 4096,
          },
        ),
      ),
    ));
    expect(find.byType(FileCard), findsNothing);
    expect(find.text('点击预览文本内容'), findsOneWidget);
  });

  testWidgets('FileContentRenderer: text/csv 走预览卡片', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: _RendererHost(
          msgType: MsgType.file,
          data: {
            'file_id': 'abc',
            'filename': 'data.csv',
            'mime_type': 'text/csv',
            'file_size': 8192,
          },
        ),
      ),
    ));
    expect(find.byType(FileCard), findsNothing);
    expect(find.text('点击预览文本内容'), findsOneWidget);
  });

  testWidgets('FileContentRenderer: Word docx 走 FileCard', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: _RendererHost(
          msgType: MsgType.file,
          data: {
            'file_id': 'abc',
            'filename': 'report.docx',
            'mime_type':
                'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
            'file_size': 32768,
          },
        ),
      ),
    ));
    expect(find.byType(FileCard), findsOneWidget);
  });

  testWidgets('FileContentRenderer: fileDownloadSnapshots 注入下载中状态',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: _RendererHost(
          msgType: MsgType.file,
          data: {
            'file_id': 'downloading123',
            'filename': 'big.pdf',
            'mime_type': 'application/pdf',
            'file_size': 1048576,
          },
          snapshots: {
            'downloading123': FileDownloadSnapshot(state: 1, progress: 0.42),
          },
        ),
      ),
    ));
    expect(find.text('下载中 42%'), findsOneWidget);
  });

  testWidgets('FileContentRenderer: fileDownloadSnapshots 注入已下载状态',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: _RendererHost(
          msgType: MsgType.file,
          data: {
            'file_id': 'done456',
            'filename': 'done.pdf',
            'mime_type': 'application/pdf',
            'file_size': 2048,
          },
          snapshots: {
            'done456': FileDownloadSnapshot(state: 2),
          },
        ),
      ),
    ));
    expect(find.text('已下载 2.0 KB'), findsOneWidget);
  });

  test('FileContentRenderer 接口契约', () {
    final r = ContentRendererRegistry.get(MsgType.file);
    expect(r, isNotNull);
    expect(r!.selectable, isFalse);
    expect(r.wrapInBubble, isFalse);
  });
}

/// 渲染 host widget，复用 ContentRendererRegistry.render 路径
class _RendererHost extends StatelessWidget {
  final MsgType msgType;
  final Map<String, dynamic> data;
  final Map<String, FileDownloadSnapshot>? snapshots;

  const _RendererHost({
    required this.msgType,
    required this.data,
    this.snapshots,
  });

  @override
  Widget build(BuildContext context) {
    return ContentRendererRegistry.render(
      msgType,
      {'msg_type': msgType.value, 'data': data},
      context,
      MessageRenderContext(
        isMe: false,
        baseUrl: 'http://localhost',
        token: 'test',
        isDark: false,
        fileDownloadSnapshots: snapshots,
      ),
    );
  }
}
