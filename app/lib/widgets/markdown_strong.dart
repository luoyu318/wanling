import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

/// 自定义 Bold (strong) 节点:覆盖 markdown_widget 默认的 FontWeight.bold (w700),
/// 改用 w500(medium),对齐 IM 简洁风格、与 H1 标题字重一致。
///
/// markdown_widget 2.3.2+8 的 [StrongNode] 是 hardcoded
/// `parentStyle?.merge(_defaultStrongStyle)`,没有 PConfig.strongStyle 字段,
/// 无法通过 MarkdownConfig 配置。这里通过 [SpanNodeGeneratorWithTag]
/// 拦截 `strong` tag,替换成自定义节点。
///
/// 通过 MarkdownGenerator.generators 注入(见 builtin_renderers.dart)。
final SpanNodeGeneratorWithTag strongGenerator = SpanNodeGeneratorWithTag(
  tag: MarkdownTag.strong.name,
  generator: (element, config, visitor) => _SemiboldStrongNode(),
);

class _SemiboldStrongNode extends ElementNode {
  @override
  TextStyle get style =>
      parentStyle?.merge(const TextStyle(fontWeight: FontWeight.w500)) ??
      const TextStyle(fontWeight: FontWeight.w500);
}
