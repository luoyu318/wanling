import 'package:wanling_core/models/msg_type.dart';
import 'package:wanling_core/rendering/builtin_renderers.dart';
import 'package:wanling_core/rendering/message_content_renderer.dart';
import 'package:wanling_core/widgets/file_card.dart';
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

  group('FileContentRenderer 文本预览卡深色适配', () {
    // 卡底 Container 可能走 color 也可能走 decoration.color,两者都查
    bool hasCardBg(WidgetTester tester, Color color) => tester
        .widgetList<Container>(find.byType(Container))
        .any((w) => w.color == color || (w.decoration as BoxDecoration?)?.color == color);

    testWidgets('text/plain 卡:深色底 26272D + 边框 2E2F36 + 文件名 EEEEEE(浅色回归 白底/E8E8E8/333333)', (tester) async {
      final data = {
        'file_id': 'abc',
        'filename': 'readme.txt',
        'mime_type': 'text/plain',
        'file_size': 256,
      };
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: _RendererHost(msgType: MsgType.file, data: data, isDark: true)),
      ));
      expect(hasCardBg(tester, const Color(0xFF26272D)), isTrue);
      expect(
        tester.widget<Text>(find.text('readme.txt')).style?.color,
        const Color(0xFFEEEEEE),
      );
      expect(
        tester.widget<Text>(find.text('256 B')).style?.color,
        const Color(0xFF777777),
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: _RendererHost(msgType: MsgType.file, data: data)),
      ));
      expect(hasCardBg(tester, Colors.white), isTrue);
      expect(
        tester.widget<Text>(find.text('readme.txt')).style?.color,
        const Color(0xFF333333),
      );
      expect(
        tester.widget<Text>(find.text('256 B')).style?.color,
        const Color(0xFF999999),
      );
    });

    testWidgets('圆形 icon 底:深色 26272D + 图标 AAAAAA(浅色回归 F2F2F2/666666)', (tester) async {
      final data = {
        'file_id': 'abc',
        'filename': 'notes.md',
        'mime_type': 'text/markdown',
        'file_size': 4096,
      };
      bool hasCircleBg(WidgetTester tester, Color color) => tester
          .widgetList<Container>(find.byType(Container))
          .any((w) => (w.decoration as BoxDecoration?)?.borderRadius == BorderRadius.circular(17) && (w.decoration as BoxDecoration).color == color);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: _RendererHost(msgType: MsgType.file, data: data, isDark: true)),
      ));
      expect(hasCircleBg(tester, const Color(0xFF26272D)), isTrue);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.description)).color,
        const Color(0xFFAAAAAA),
      );

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: _RendererHost(msgType: MsgType.file, data: data)),
      ));
      expect(hasCircleBg(tester, const Color(0xFFF2F2F2)), isTrue);
      expect(
        tester.widget<Icon>(find.byIcon(Icons.description)).color,
        const Color(0xFF666666),
      );
    });
  });
}

/// 渲染 host widget，复用 ContentRendererRegistry.render 路径
class _RendererHost extends StatelessWidget {
  final MsgType msgType;
  final Map<String, dynamic> data;
  final Map<String, FileDownloadSnapshot>? snapshots;
  final bool isDark;

  const _RendererHost({
    required this.msgType,
    required this.data,
    this.snapshots,
    this.isDark = false,
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
        isDark: isDark,
        fileDownloadSnapshots: snapshots,
      ),
    );
  }
}
