import 'package:flutter/material.dart';
import '../utils/mono_font.dart';

import 'tool_card_body_widgets.dart' show showDetailSheet;

/// 可截断文本块:内联 maxHeight:56 + maxLines:3 + 点击弹 showDetailSheet 看全文。
///
/// 内联样式由调用方传入(textStyle / backgroundColor / padding),
/// 抽屉内容统一 SelectableText + monospace 12 + 屏高 70%(showDetailSheet 约定)。
/// 始终挂 GestureDetector(对齐 BashBody);调用方若需短文本直出不进抽屉,
/// 在调用点用条件判断根本不渲染本组件(见 tool_result_renderer.dart 用法)。
class TruncatableTextBlock extends StatelessWidget {
  final String text;
  final Widget sheetTitle;
  final TextStyle textStyle;
  final Color backgroundColor;
  final EdgeInsets padding;
  final int maxLines;

  /// 深色模式(桌面端):透传 showDetailSheet(抽屉底 1E1F24 + 正文 C8C8C8);
  /// 浅色(app 壳)白底 + 555555 不变。内联样式由调用方传(textStyle/backgroundColor)。
  final bool isDark;

  const TruncatableTextBlock({
    super.key,
    required this.text,
    required this.sheetTitle,
    required this.textStyle,
    this.backgroundColor = const Color(0xFFF2F2F2),
    this.padding = const EdgeInsets.all(6),
    this.maxLines = 3,
    this.isDark = false,
  });

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () => showDetailSheet(
        context,
        isDark: isDark,
        title: sheetTitle,
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(
            text,
            style: TextStyle(
              fontFamily: 'monospace', fontFamilyFallback: kMonoFontFallback,
              fontSize: 12,
              height: 1.5,
              // 深色灰阶反转:#555 → #C8C8C8
              color: isDark ? const Color(0xFFC8C8C8) : const Color(0xFF555555),
            ),
          ),
        ),
      ),
      child: Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(4),
        ),
        constraints: const BoxConstraints(maxHeight: 56),
        child: Text(
          text,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: textStyle,
        ),
      ),
    );
  }
}
