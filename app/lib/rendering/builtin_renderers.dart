import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../models/msg_type.dart';
import '../utils/emoji_span.dart';
import '../utils/gallery_image.dart' show thumbUrl;
import '../widgets/image_thumb.dart';
import '../widgets/markdown_block_spacing.dart';
import '../widgets/markdown_config.dart';
import '../widgets/markdown_latex.dart';
import '../widgets/markdown_strong.dart';
import '../widgets/markdown_view.dart';
import 'card_renderer.dart';
import 'message_content_renderer.dart';

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
    // 纯文本（无 markdown 语法）走 Text：Text 有 intrinsic width，气泡能自适应内容宽度。
    // 含 markdown 语法的（# 标题、* 强调、``` 代码块、- 列表等）走 MarkdownView。
    if (!_hasMarkdownSyntax(text)) {
      // buildEmojiColoredText: 给 ♻️⚠️✂️ 等单色 emoji 字符单独设 Noto Color Emoji
      // 字体(精确 span 分割),不影响普通文本度量(见 emoji_span.dart 根因说明)。
      return buildEmojiColoredText(text,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w300));
    }
    return MarkdownView(
      data: text,
      config: markdownStyle(isDark: rc.isDark, context: context, baseUrl: rc.baseUrl, token: rc.token, openGallery: rc.openGallery),
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
    // 无 markdown 语法的 markdown 消息降级为带 emoji span 分割的 Text:
    // 保留 ♻️⚠️✂️ 彩色渲染,且避免 MarkdownView 对纯文本的额外开销。
    if (!TextContentRenderer._hasMarkdownSyntax(text)) {
      return buildEmojiColoredText(text,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w300));
    }
    return MarkdownView(
      data: text,
      config: markdownStyle(isDark: rc.isDark, context: context, baseUrl: rc.baseUrl, token: rc.token, openGallery: rc.openGallery),
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

/// 文件渲染器：Row(图标 + 文件名)。
///
/// 返回纯内容（不含气泡三角），由 MessageBubble 包 BubbleWithTail。
class FileContentRenderer implements MessageContentRenderer {
  const FileContentRenderer();

  @override
  bool get selectable => false;

  @override
  bool get wrapInBubble => true;

  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> content,
    MessageRenderContext rc,
  ) {
    final data = content['data'];
    final filename = (data?['filename'] ?? '') as String;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.insert_drive_file, size: 20),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            filename.isEmpty ? '文件' : filename,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
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
}
