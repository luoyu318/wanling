import 'package:flutter/material.dart';
import 'package:markdown_widget/markdown_widget.dart';

/// 自定义块级元素的上下间距（标题 / 分割线）。
///
/// 背景：markdown_widget 2.3.2+8 的默认行为无法直接配置这两类元素的 margin：
/// - [HeadingNode]（heading.dart）：`divider == null` 时直接返回 `childrenSpan`，
///   根本不读 `HeadingConfig.padding`（默认 top:8/bottom:4 在我们 `_NoDividerHeadingConfig`
///   下是死代码），所以无法靠 override padding 调间距。
/// - [HrNode]（horizontal_rules.dart）：只渲染 `Container(height, color)`，
///   [HrConfig] 没暴露 margin 字段。
///
/// 解决思路：用 [SpanNodeGeneratorWithTag] 拦截 `h1~h6` / `hr` tag，
/// 替换成会自己包 [Padding] 的自定义节点。通过 MarkdownView 的 `generators`
/// 参数注入（见 builtin_renderers.dart）。

/// 标题节点：在原 `HeadingConfig` 基础上包一层 [Padding]，统一控制上下间距。
///
/// 与 heading.dart 默认 `Padding(top: 8, bottom: 4)` 不同，本节点无论 divider 是否
/// 为 null 都会包 Padding，确保间距生效。不渲染底部分割线（继承项目的无分割线风格）。
class _PaddedHeadingNode extends ElementNode {
  final HeadingConfig headingConfig;

  _PaddedHeadingNode(this.headingConfig);

  @override
  TextStyle get style => headingConfig.style.merge(parentStyle);

  @override
  InlineSpan build() {
    return WidgetSpan(
      child: Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 6),
        child: Text.rich(
          childrenSpan,
          textAlign: TextAlign.left,
        ),
      ),
    );
  }
}

/// 分割线节点：在原 `HrConfig` 渲染外加一层 [Padding]，提供上下间距。
class _PaddedHrNode extends SpanNode {
  final HrConfig hrConfig;

  _PaddedHrNode(this.hrConfig);

  @override
  InlineSpan build() {
    return WidgetSpan(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Container(
          height: hrConfig.height,
          color: hrConfig.color,
        ),
      ),
    );
  }
}

/// 拦截 h1~h6 tag 的 generator 列表：返回自定义 [_PaddedHeadingNode]。
///
/// 注入到 MarkdownView.generators 时会覆盖 markdown_widget 默认的 HeadingNode。
/// 从传入的 [MarkdownConfig] 读取对应 tag 的 HeadingConfig（保留项目自定义样式：
/// 字号/字重/颜色），只替换「外壳 + 间距」。
List<SpanNodeGeneratorWithTag> headingSpacingGenerators() {
  return [
    for (final tag in const [
      MarkdownTag.h1,
      MarkdownTag.h2,
      MarkdownTag.h3,
      MarkdownTag.h4,
      MarkdownTag.h5,
      MarkdownTag.h6,
    ])
      SpanNodeGeneratorWithTag(
        tag: tag.name,
        generator: (element, config, visitor) {
          final headingConfig = _headingConfigFor(config, tag);
          return _PaddedHeadingNode(headingConfig);
        },
      ),
  ];
}

/// 从 [MarkdownConfig] 取出对应 tag 的 [HeadingConfig]（h1~h6）。
HeadingConfig _headingConfigFor(MarkdownConfig config, MarkdownTag tag) {
  switch (tag) {
    case MarkdownTag.h1:
      return config.h1;
    case MarkdownTag.h2:
      return config.h2;
    case MarkdownTag.h3:
      return config.h3;
    case MarkdownTag.h4:
      return config.h4;
    case MarkdownTag.h5:
      return config.h5;
    case MarkdownTag.h6:
      return config.h6;
    default:
      return config.h1;
  }
}

/// 拦截 hr tag 的 generator：返回自定义 [_PaddedHrNode]。
///
/// 注入到 MarkdownView.generators 时会覆盖 markdown_widget 默认的 HrNode，
/// 保留原 [HrConfig] 的 height/color（在 markdown_config.dart 里设的 0.5/灰）。
final SpanNodeGeneratorWithTag hrSpacingGenerator = SpanNodeGeneratorWithTag(
  tag: MarkdownTag.hr.name,
  generator: (element, config, visitor) => _PaddedHrNode(config.hr),
);
