import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

import '../models/msg_type.dart';
import '../utils/emoji_span.dart';
import '../widgets/markdown_config.dart';
import '../widgets/markdown_latex.dart';
import '../widgets/markdown_view.dart';
import 'card_renderer.dart';
import 'message_content_renderer.dart';

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
      generators: [latexGenerator],
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
      generators: [latexGenerator],
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

    final url = '${rc.baseUrl}/api/files/$fileId';
    final headers = {'Authorization': 'Bearer ${rc.token}'};

    return Hero(
      tag: 'gallery_$fileId',
      child: GestureDetector(
        // 点击收集会话图片并打开画廊（由 ChatPage 注入 rc.openGallery）。
        // openGallery 为 null（如测试）时降级为无操作，避免崩溃。
        onTap: () => rc.openGallery?.call(fileId),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: CachedNetworkImage(
            imageUrl: url,
            httpHeaders: headers,
            cacheKey: 'file_$fileId',
            width: 200,
            fit: BoxFit.cover,
            placeholder: (_, __) => const SizedBox(
              width: 200,
              height: 150,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
            ),
            errorWidget: (_, __, ___) => const SizedBox(
              width: 200,
              height: 150,
              child: Center(child: Icon(Icons.broken_image, size: 60)),
            ),
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
