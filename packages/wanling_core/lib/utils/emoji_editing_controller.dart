/// 让 [TextField] 也能渲染彩色 emoji 的 [TextEditingController]。
///
/// ## 背景
/// [TextField] 不像 [Text],内容由用户实时输入,没法用 Text.rich 预先切 span。
/// 但 [TextEditingController] 有 [buildTextSpan] 回调,引擎每次渲染时调用——
/// 在这里返回切好 span 的 TextSpan,就能让输入框里的 emoji 也走彩色字体。
///
/// ## 用法
/// 把原来的 `TextEditingController()` 换成 `EmojiEditingController()`:
/// ```dart
/// final controller = EmojiEditingController();
/// TextField(controller: controller, style: ...);
/// ```
///
/// ## 性能
/// [buildTextSpan] 每次 build 调用,内部做 [containsForceEmoji] 快速短路:
/// 不含目标字符时直接返回默认 span(零额外开销)。
library;

import 'package:flutter/material.dart';

import 'emoji_span.dart';

/// 支持 emoji 彩色渲染的输入框 controller。
class EmojiEditingController extends TextEditingController {
  EmojiEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = this.text;
    // 不含目标字符:走父类默认实现(零开销)
    if (!containsForceEmoji(text)) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    // 含目标字符:切 span,emoji 段单独设彩色字体。
    // 注意:不在外层 TextSpan 设 style,只让 child span 各自带 style,
    // 避免 style 双重 merge 造成字号/字重渲染异常。
    final spans = splitEmojiSpans(text, style);
    return TextSpan(children: spans);
  }
}
