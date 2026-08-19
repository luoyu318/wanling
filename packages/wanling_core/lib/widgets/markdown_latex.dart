import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as m;
import 'package:markdown_widget/markdown_widget.dart';

import 'select_all_container.dart';

/// 行内/块级 LaTeX 的 markdown 语法匹配:匹配 $...$ 和 $...$。
/// 通过 MarkdownGenerator.inlineSyntaxList 注入 MarkdownWidget,
/// 让 $E=mc^2$ / $$\int...$$ 被识别为 latex 节点,交给 [latexGenerator] 渲染。
///
/// 移植自 markdown_widget 官方 example 的 LatexSyntax。
class LatexSyntax extends m.InlineSyntax {
  LatexSyntax() : super(r'(\$\$[\s\S]+?\$\$)|(\$[^\$\n]+?\$)');

  @override
  bool onMatch(m.InlineParser parser, Match match) {
    final matchValue = match.input.substring(match.start, match.end);
    const blockSyntax = '\$\$';
    const inlineSyntax = '\$';

    String content = '';
    if (matchValue.startsWith(blockSyntax) &&
        matchValue.endsWith(blockSyntax) &&
        matchValue.length > blockSyntax.length) {
      content = matchValue.substring(2, matchValue.length - 2);
    } else if (matchValue.startsWith(inlineSyntax) &&
        matchValue.endsWith(inlineSyntax) &&
        matchValue.length > inlineSyntax.length) {
      content = matchValue.substring(1, matchValue.length - 1);
    }

    final el = m.Element.text(_latexTag, matchValue);
    el.attributes['content'] = content;
    parser.addNode(el);
    return true;
  }
}

const _latexTag = 'latex';

/// LaTeX 节点生成器:把 latex 元素渲染成 flutter_math_fork 的 Math.tex。
/// 通过 MarkdownGenerator.generators 注入。
final SpanNodeGeneratorWithTag latexGenerator = SpanNodeGeneratorWithTag(
  tag: _latexTag,
  generator: (element, config, visitor) =>
      LatexNode(element.attributes, element.textContent, config),
);

class LatexNode extends SpanNode {
  final Map<String, String> attributes;
  final String textContent;
  final MarkdownConfig config;

  LatexNode(this.attributes, this.textContent, this.config);

  @override
  InlineSpan build() {
    final content = attributes['content'] ?? '';
    final style = parentStyle ?? config.p.textStyle;
    if (content.isEmpty) {
      return TextSpan(text: textContent, style: style);
    }
    final isBlock = textContent.startsWith(r'$');
    final mathWidget = Math.tex(
      content,
      mathStyle: MathStyle.text,
      textStyle: style,
      textScaleFactor: 1.1,
    );
    // 块级 $...$: 包 SelectAllOrNoneContainer，拉杆碰到整块选中。
    // Math.tex 是图形(非文本)，原生选不中，用 content(latex 源码)作 fallbackText
    // 让复制时拿到可读的 latex 源码。
    // 行内 $...$: 不包，参与普通文字流选择(随周围文字一起被选中/复制)。
    final child = isBlock
        ? SelectAllOrNoneContainer(fallbackText: content, child: mathWidget)
        : mathWidget;
    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: child,
    );
  }
}
