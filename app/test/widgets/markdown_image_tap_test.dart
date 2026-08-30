import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/widgets/markdown_config.dart';
import 'package:wanling_core/widgets/markdown_view.dart';
import 'package:wanling_core/widgets/image_thumb.dart';

/// 复现聚合卡内 markdown 图片点击无反应问题:
/// MarkdownView + markdownStyle(openGallery) 渲染 `![alt](/api/files/xxx)`,
/// tap 图片 widget,断言 openGallery 回调收到正确 fileId。
void main() {
  testWidgets('点击 markdown 内嵌图片触发 openGallery 回调', (tester) async {
    String? tappedFileId;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: SingleChildScrollView(
              child: MarkdownView(
                data: '![截图](/api/files/abc123)',
                config: markdownStyle(
                  isDark: false,
                  isMe: false,
                  context: context,
                  baseUrl: 'https://h',
                  token: 'tok',
                  openGallery: (id) => tappedFileId = id,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 图片确实渲染成 ImageThumb(内部 URL 放行,非文字占位)
    expect(find.byType(ImageThumb), findsOneWidget);

    await tester.tap(find.byType(ImageThumb));
    await tester.pump();

    expect(tappedFileId, 'abc123');
  });
}
