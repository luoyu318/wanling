import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as m;
import 'package:markdown_widget/markdown_widget.dart';

/// 自控的 markdown 渲染组件。
///
/// **不用 `MarkdownWidget`**：它会内部固定包 `SelectionArea` + `ListView` +
/// `VisibilityDetector` + `AutoScrollController`，导致：
/// 1. 选择控制权不在我们手里（SelectionArea 吞掉长按手势，菜单弹不出）
/// 2. 气泡内本不该有滚动容器（ListView）和可见性检测（VisibilityDetector）
///
/// 本组件用 markdown_widget 的**底层 API** 自己组装渲染链：
///   `m.Document.parseLines`（解析 AST）
///   → `WidgetVisitor.visit`（AST → SpanNode，config/generator 钩子照常生效）
///   → `SpanNode.build()`（→ InlineSpan）
///   → `Column[Text.rich(...)]`
///
/// **不包 SelectionArea**：选择由 MessageBubble 外层 SelectableRegion 统一管，
/// 避免嵌套冲突。所有现有样式（markdown_config.dart）、LaTeX（markdown_latex.dart）、
/// 代码高亮（markdown_code_wrapper.dart）100% 保留 —— 它们在 SpanNode build 层生效，
/// 与本组件的容器无关。
class MarkdownView extends StatelessWidget {
  final String data;
  final MarkdownConfig config;
  final List<m.InlineSyntax>? inlineSyntaxes;
  final List<SpanNodeGeneratorWithTag>? generators;

  const MarkdownView({
    super.key,
    required this.data,
    required this.config,
    this.inlineSyntaxes,
    this.generators,
  });

  @override
  Widget build(BuildContext context) {
    final spans = _buildSpans();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final span in spans) Text.rich(span),
      ],
    );
  }

  /// 解析 markdown → SpanNode 列表 → 每个 build 成 InlineSpan。
  ///
  /// 块级元素（代码块/表格/LaTeX/列表）的 build() 返回 WidgetSpan，内嵌对应
  /// widget；普通段落返回 TextSpan。一个顶层 SpanNode 对应一个 Text.rich。
  List<InlineSpan> _buildSpans() {
    // 1. markdown 字符串 → 行 → AST 节点（用 package:markdown 的 Document）
    final document = m.Document(
      extensionSet: m.ExtensionSet.gitHubFlavored,
      encodeHtml: false,
      inlineSyntaxes: inlineSyntaxes,
    );
    final nodes = document.parseLines(data.split(WidgetVisitor.defaultSplitRegExp));

    // 2. AST → SpanNode（用 markdown_widget 的 WidgetVisitor，
    //    config/generators 钩子在此层生效，样式/LaTeX/代码高亮全保留）
    final visitor = WidgetVisitor(
      config: config,
      generators: generators ?? const [],
    );
    final spanNodes = visitor.visit(nodes);

    // 3. SpanNode.build() → InlineSpan
    return [for (final node in spanNodes) node.build()];
  }
}
