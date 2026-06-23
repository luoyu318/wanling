import 'package:flutter/material.dart';
import 'package:flutter_highlight/themes/a11y-dark.dart';
import 'package:flutter_highlight/themes/a11y-light.dart';
import 'package:markdown_widget/markdown_widget.dart';

import 'markdown_code_wrapper.dart';
import 'select_all_container.dart';

/// 聊天气泡用的 markdown 渲染样式（极简墨白风格）。
///
/// 特征:
/// - 正文 15px、行高 1.6(受任务列表 checkbox WidgetSpan 约束下限,不能 < 1.6,
///   否则触发 padding.isNonNegative 断言)
/// - 标题墨黑/粗体,层级靠字号区分,**不带底部分割横线**
/// - 代码块:浅灰底圆角 6 + flutter_highlight 高亮 + 右上角复制按钮(无语言标签)
/// - 引用块灰条
/// - 表格:只保留行下方浅灰细线(无外框/竖线),表头灰字不加粗、表内容黑字不加粗,
///   宽表格横向滚动
///
/// [isDark] 控制明暗主题切换(代码块高亮主题 + 文字颜色)。
MarkdownConfig markdownStyle({required bool isDark}) {
  final ink = isDark ? const Color(0xFFE8E8E8) : const Color(0xFF222222);
  final sub = isDark ? const Color(0xFF999999) : const Color(0xFF666666);
  // 表格行下方分割线:浅灰细线
  final tableDividerColor =
      isDark ? const Color(0xFF444444) : const Color(0xFFDDDDDD);
  final preBase = isDark ? PreConfig.darkConfig : const PreConfig();
  final base = isDark ? MarkdownConfig.darkConfig : MarkdownConfig.defaultConfig;
  return base.copy(configs: [
    PConfig(textStyle: TextStyle(fontSize: 18, fontWeight: FontWeight.w300, height: 1.6, color: ink)),
    _NoDividerHeadingConfig(
      tag: MarkdownTag.h1,
      style: TextStyle(
          fontSize: 19, fontWeight: FontWeight.bold, color: ink, height: 1.5),
    ),
    _NoDividerHeadingConfig(
      tag: MarkdownTag.h2,
      style: TextStyle(
          fontSize: 17, fontWeight: FontWeight.bold, color: ink, height: 1.5),
    ),
    _NoDividerHeadingConfig(
      tag: MarkdownTag.h3,
      style: TextStyle(
          fontSize: 15, fontWeight: FontWeight.w600, color: ink, height: 1.5),
    ),
    preBase.copy(
      wrapper: markdownCodeWrapper,
      theme: isDark ? a11yDarkTheme : a11yLightTheme,
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF2F2F2),
        borderRadius: BorderRadius.circular(6),
      ),
    ),
    BlockquoteConfig(
      sideColor: isDark ? const Color(0xFF555555) : const Color(0xFFCCCCCC),
      textColor: sub,
      sideWith: 3,
      padding: const EdgeInsets.fromLTRB(10, 6, 0, 6),
      margin: const EdgeInsets.symmetric(vertical: 6),
    ),
    TableConfig(
      // 只保留每行下方浅灰细线,去掉外框和竖线
      border: TableBorder(
        bottom: BorderSide(width: 0.5, color: tableDividerColor),
        horizontalInside:
            BorderSide(width: 0.5, color: tableDividerColor),
      ),
      // 行高 +5:单元格上下内边距默认 4 → 9
      headPadding: const EdgeInsets.fromLTRB(8, 9, 8, 9),
      bodyPadding: const EdgeInsets.fromLTRB(8, 9, 8, 9),
      // 注意:markdown_widget 2.3.2+8 有 bug,TBodyNode(表内容)的 style 实际读
      // headerStyle 而非 bodyStyle,所以表头表内容共用 headerStyle。
      // 统一用 #000 黑字、w300 细体、字号 14。
      headerStyle: const TextStyle(
          color: Color(0xFF000000), fontSize: 14, fontWeight: FontWeight.w300),
      // bodyStyle 在当前版本不生效(被上述 bug 绕过),保留与 headerStyle 一致作记录
      bodyStyle: const TextStyle(
          color: Color(0xFF000000), fontSize: 14, fontWeight: FontWeight.w300),
      // 表格包横向滚动:宽表格可横向滑动,避免溢出气泡
      wrapper: _tableScrollWrapper,
    ),
  ]);
}

/// 无分割线标题配置:override divider 返回 null,去掉 H1/H2 默认的底部横线。
/// 通过 tag 区分 h1/h2/h3,共用一个类。
class _NoDividerHeadingConfig extends HeadingConfig {
  final MarkdownTag _tag;
  @override
  final TextStyle style;

  const _NoDividerHeadingConfig({
    required MarkdownTag tag,
    required this.style,
  }) : _tag = tag;

  @override
  String get tag => _tag.name;

  @override
  HeadingDivider? get divider => null;
}

/// 表格外层横向滚动包装:宽表格可横向滑动,避免溢出气泡。
/// 内层包 SelectAllOrNoneContainer:拉杆碰到表格整块选中(表格单元格是 TextSpan
/// 天然可选,复制得表格文本)。
Widget _tableScrollWrapper(Widget child) {
  return SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    child: SelectAllOrNoneContainer(child: child),
  );
}
