import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

import 'package:wanling_core/models/msg_type.dart';
import '../pages/text_preview_page.dart';
import 'package:wanling_core/utils/emoji_span.dart';
import 'package:wanling_core/utils/file_format.dart';
import 'package:wanling_core/utils/gallery_image.dart' show thumbUrl;
import '../widgets/file_card.dart';
import '../widgets/file_type_icon.dart';
import '../widgets/image_thumb.dart';
import '../widgets/markdown_block_spacing.dart';
import '../widgets/markdown_config.dart';
import '../widgets/markdown_latex.dart';
import '../widgets/markdown_strong.dart';
import '../widgets/markdown_view.dart';
import '../widgets/streaming_text.dart';
import 'aggregate_card_renderer.dart';
import 'card_renderer.dart';
import 'file_diff_renderer.dart';
import 'message_content_renderer.dart';
import 'permission_card_renderer.dart';
import 'question_card_renderer.dart';
import 'reasoning_renderer.dart';
import 'slash_echo_renderer.dart';
import 'step_finish_renderer.dart';
import 'tool_call_renderer.dart';
import 'tool_card_renderer.dart';
import 'tool_error_renderer.dart';
import 'tool_result_renderer.dart';
import 'tui_user_renderer.dart';

/// MarkdownView 共用的 generators 列表：
/// - latex/strong：自定义节点（数学公式、w500 粗体）
/// - hr/heading：自定义节点（提供上下间距，markdown_widget 默认无 margin 字段）
final List<SpanNodeGeneratorWithTag> _markdownGenerators = [
  latexGenerator,
  strongGenerator,
  hrSpacingGenerator,
  ...headingSpacingGenerators(),
];

/// 纯文本渲染器。
///
/// content.data.text 若含 markdown 语法，改用 [MarkdownView] 渲染（保留原
/// MessageBubble 的分流逻辑）。纯文本走 Text（intrinsic width，气泡自适应）。
class TextContentRenderer implements MessageContentRenderer {
  const TextContentRenderer();

  @override
  bool get selectable => true;

  @override
  bool get wrapInBubble => true;

  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> content,
    MessageRenderContext rc,
  ) {
    final data = content['data'];
    final text = (data?['text'] as String?) ?? '';
    if (rc.isStreaming && text.isNotEmpty) {
      return StreamingText(
        key: ValueKey(rc.messageId),
        text: text,
        streaming: true,
        mdBuilder: (t) => _renderFinal(context, rc, t),
      );
    }
    return _renderFinal(context, rc, text);
  }

  Widget _renderFinal(
    BuildContext context,
    MessageRenderContext rc,
    String text,
  ) {
    // 纯文本（无 markdown 语法）走 Text：Text 有 intrinsic width，气泡能自适应内容宽度。
    // 含 markdown 语法的（# 标题、* 强调、``` 代码块、- 列表等）走 MarkdownView。
    // 发送方紫底气泡不适合白底配色,直接走纯文本白字,不渲染 markdown。
    if (rc.isMe || !_hasMarkdownSyntax(text)) {
      // buildEmojiColoredText: 给 ♻️⚠️✂️ 等单色 emoji 字符单独设 Noto Color Emoji
      // 字体(精确 span 分割),不影响普通文本度量(见 emoji_span.dart 根因说明)。
      // 字色:发送方气泡紫色背景,强制白色;接收方按默认(null 走 Theme 默认)。
      final textColor = rc.isMe ? Colors.white : null;
      return buildEmojiColoredText(text,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w400, color: textColor));
    }
    return MarkdownView(
      data: text,
      config: markdownStyle(isDark: rc.isDark, isMe: rc.isMe, context: context, baseUrl: rc.baseUrl, token: rc.token, openGallery: rc.openGallery),
      inlineSyntaxes: [LatexSyntax()],
      generators: _markdownGenerators,
    );
  }

  /// 检测 text 是否含 markdown 语法（从 MessageBubble 原样搬迁）。
  static final _markdownRe = RegExp(
    r'(^|\n)\s{0,3}(#{1,6}\s|[*+-]\s|\d+\.\s|>)' // 行首：标题/无序/有序列表/引用
    r'|```' // 代码块
    r'|`[^`]+`' // 行内代码
    r'|\*\*[^*]+\*\*' // 粗体
    r'|\*[^*]+\*' // 斜体
    r'|_[^_]+_' // 下划线斜体
    r'|\[[^\]]+\]\([^)]+\)' // 链接
    r'|\|.*\|.*\|' // 表格（至少 3 个 |）
    r'|\$\$[\s\S]+?\$\$' // 块级 LaTeX
    r'|\$[^\$\n]+?\$', // 行内 LaTeX
  );

  static bool _hasMarkdownSyntax(String text) {
    if (text.isEmpty) return false;
    return _markdownRe.hasMatch(text);
  }
}

/// Markdown 渲染器。
///
/// content.data.text 走 [MarkdownView]（自控选择链，无内置 SelectionArea）。
/// 纯文本（无语法）降级为 Text。
class MarkdownContentRenderer implements MessageContentRenderer {
  const MarkdownContentRenderer();

  @override
  bool get selectable => true;

  @override
  bool get wrapInBubble => true;

  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> content,
    MessageRenderContext rc,
  ) {
    final data = content['data'];
    final text = (data?['text'] as String?) ?? '';
    if (text.isEmpty) return const SizedBox.shrink();
    if (rc.isStreaming) {
      return StreamingText(
        key: ValueKey(rc.messageId),
        text: text,
        streaming: true,
        mdBuilder: (t) => _renderFinal(context, rc, t),
      );
    }
    return _renderFinal(context, rc, text);
  }

  Widget _renderFinal(
    BuildContext context,
    MessageRenderContext rc,
    String text,
  ) {
    // 无 markdown 语法的 markdown 消息降级为带 emoji span 分割的 Text:
    // 保留 ♻️⚠️✂️ 彩色渲染,且避免 MarkdownView 对纯文本的额外开销。
    // 发送方紫底气泡同 P0 策略,直接走纯文本白字,不渲染 markdown。
    if (rc.isMe || !TextContentRenderer._hasMarkdownSyntax(text)) {
      final textColor = rc.isMe ? Colors.white : null;
      return buildEmojiColoredText(text,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w400, color: textColor));
    }
    return MarkdownView(
      data: text,
      config: markdownStyle(isDark: rc.isDark, isMe: rc.isMe, context: context, baseUrl: rc.baseUrl, token: rc.token, openGallery: rc.openGallery),
      inlineSyntaxes: [LatexSyntax()],
      generators: _markdownGenerators,
    );
  }
}

/// 图片渲染器：6px 圆角无三角，点击进会话级画廊（Hero 共享元素过渡）。
///
/// 不参与选择（图片不可选），不包气泡三角（自带圆角样式）。
/// 缩略图包 Hero(tag='gallery_$fileId')，与画廊初始页的 PhotoView 配对，
/// 完成从点击位置缩放放大的过渡动画。
class ImageContentRenderer implements MessageContentRenderer {
  const ImageContentRenderer();

  @override
  bool get selectable => false;

  @override
  bool get wrapInBubble => false;

  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> content,
    MessageRenderContext rc,
  ) {
    final data = content['data'];
    final fileId = (data?['file_id'] ?? '') as String;
    if (fileId.isEmpty) return const Text('[图片]');

    // 缩略图 URL（?thumb=1）：服务端返回 600px 长边小图，无缩略图时降级原图。
    // 消息列表 / 气泡场景显示宽 200，600px 已覆盖 3×DPR，清晰度足够。
    final url = thumbUrl(rc.baseUrl, fileId);
    final headers = {'Authorization': 'Bearer ${rc.token}'};

    // 宽高比：server message processor 已对 image 消息自动补 width/height
    // （从 files 表查原图尺寸）。有则主路径零跳动；存量消息无此字段为 null，
    // 走 ImageThumb 内的 resolve 探测兜底。
    final w = data?['width'];
    final h = data?['height'];
    final aspect = (w is int && h is int && w > 0 && h > 0) ? (w / h) : null;

    return Hero(
      tag: 'gallery_$fileId',
      child: GestureDetector(
        // 点击收集会话图片并打开画廊（由 ChatPage 注入 rc.openGallery）。
        // openGallery 为 null（如测试）时降级为无操作，避免崩溃。
        onTap: () => rc.openGallery?.call(fileId),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: ImageThumb(
            fileId: fileId,
            url: url,
            headers: headers,
            aspect: aspect,
            // image 消息用 cover 裁切成紧凑方块（照片风，主流 IM 风格）。
            fit: BoxFit.cover,
            isDark: rc.isDark,
          ),
        ),
      ),
    );
  }
}

/// 文件渲染器：独立卡片气泡（无三角），按 mime_type 分流:
/// - text/plain/markdown/csv → 全屏 TextPreviewPage 预览
/// - 其他 → FileCard 走下载流程，点击触发 rc.onFileTap
class FileContentRenderer implements MessageContentRenderer {
  const FileContentRenderer();

  @override
  bool get selectable => false;

  @override
  bool get wrapInBubble => false;

  static const _textMimeTypes = {
    'text/plain',
    'text/markdown',
    'text/csv',
  };

  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> content,
    MessageRenderContext rc,
  ) {
    final data = content['data'];
    final fileId = (data?['file_id'] ?? '') as String;
    final filename = (data?['filename'] ?? '') as String;
    final mimeType = (data?['mime_type'] ?? '') as String;
    final fileSize = (data?['file_size'] as int?) ?? 0;

    if (_textMimeTypes.contains(mimeType)) {
      return _TextPreviewCard(
        filename: filename,
        fileSize: fileSize,
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => TextPreviewPage(
                fileId: fileId,
                filename: filename,
                baseUrl: rc.baseUrl,
                token: rc.token,
              ),
            ),
          );
        },
      );
    }

    // ChatPage 注入的下载状态决定 FileCard 渲染态：null/无条目 → notDownloaded。
    final snapshot = rc.fileDownloadSnapshots?[fileId];
    DownloadState state = DownloadState.notDownloaded;
    double? progress;
    if (snapshot != null) {
      switch (snapshot.state) {
        case 1:
          state = DownloadState.downloading;
          progress = snapshot.progress;
          break;
        case 2:
          state = DownloadState.downloaded;
          break;
        case 3:
          state = DownloadState.uploading;
          progress = snapshot.progress;
          break;
      }
    }

    return FileCard(
      fileId: fileId,
      filename: filename.isNotEmpty ? filename : '文件',
      mimeType: mimeType,
      fileSize: fileSize,
      isMe: rc.isMe,
      downloadState: state,
      downloadProgress: progress,
      // ChatPage 在 onFileTap 内据 _downloadProgress / _downloaded 状态分支决定:
      // notDownloaded → showSheet / downloading → cancel / downloaded → openFile
      onTap: rc.onFileTap != null
          ? () => rc.onFileTap!(fileId, filename, mimeType, fileSize)
          : null,
    );
  }
}

/// 文本文件预览卡片。复用 FileTypeIcon 样式但底部提示为"点击预览"。
class _TextPreviewCard extends StatelessWidget {
  final String filename;
  final int fileSize;
  final VoidCallback? onTap;

  const _TextPreviewCard({
    required this.filename,
    required this.fileSize,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: screenWidth * 0.75,
          minWidth: 220,
        ),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: const Color(0xFFE8E8E8)),
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: Color(0x0A000000),
              blurRadius: 3,
              offset: Offset(0, 1),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const FileTypeIcon(mimeType: 'text/plain'),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          filename.isNotEmpty ? filename : '文本文件',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF333333),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          formatFileSize(fileSize),
                          style: const TextStyle(
                            fontSize: 11,
                            color: Color(0xFF999999),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF2F2F2),
                      borderRadius: BorderRadius.circular(17),
                    ),
                    child: const Icon(
                      Icons.description,
                      size: 16,
                      color: Color(0xFF666666),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.only(bottom: 10, top: 2),
              alignment: Alignment.center,
              child: const Text(
                '点击预览文本内容',
                style: TextStyle(fontSize: 10, color: Color(0xFFAAAAAA)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 注册所有内置 renderer。应用启动时调用一次。
///
/// 后续扩展 HTML/卡片时，在此追加 `register(MsgType.html, HtmlRenderer())`。
void registerBuiltinRenderers() {
  ContentRendererRegistry.register(MsgType.text, const TextContentRenderer());
  ContentRendererRegistry.register(
      MsgType.markdown, const MarkdownContentRenderer());
  ContentRendererRegistry.register(MsgType.image, const ImageContentRenderer());
  ContentRendererRegistry.register(MsgType.file, const FileContentRenderer());
  ContentRendererRegistry.register(MsgType.card, const CardContentRenderer());
  ContentRendererRegistry.register(MsgType.tuiUser, const TuiUserRenderer());
  ContentRendererRegistry.register(MsgType.reasoning, const ReasoningRenderer());
  ContentRendererRegistry.register(MsgType.stepFinish, const StepFinishRenderer());
  ContentRendererRegistry.register(MsgType.toolResult, const ToolResultRenderer());
  ContentRendererRegistry.register(MsgType.toolError, const ToolErrorRenderer());
  ContentRendererRegistry.register(MsgType.toolCall, const ToolCallRenderer());
  ContentRendererRegistry.register(MsgType.toolCard, const ToolCardRenderer());
  ContentRendererRegistry.register(MsgType.fileDiff, const FileDiffRenderer());
  ContentRendererRegistry.register(
      MsgType.permissionCard, const PermissionCardRenderer());
  ContentRendererRegistry.register(
      MsgType.questionCard, const QuestionCardRenderer());
  ContentRendererRegistry.register(MsgType.slashEcho, const SlashEchoRenderer());
  ContentRendererRegistry.register(
      MsgType.aggregateCard, const AggregateCardRenderer());
}
