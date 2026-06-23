/// 修复「♻️⚠️✂️ 等 emoji 在 Android 被渲染成单色」的精确 span 分割。
///
/// ## 根因
/// Android Roboto 字体 cmap 含 ♻(U+267B)⚠(U+26A0)✂(U+2702) 等的单色字形,
/// 主字体先抢到就用单色渲染。而 ☀️✈️ 等因 Roboto cmap 无字形才让给系统彩色字体。
///
/// ## 方案选型
/// - 全局 `fontFamilyFallback: ['Noto Color Emoji']`:能让 emoji 变彩色,但
///   Noto Color Emoji 的 cmap 含宽空格/宽数字(notofonts#753),会污染普通文本
///   导致数字、空格变宽。**已弃用**。
/// - 精确 span 分割(本文件):把文本切成 [普通段, emoji段, 普通段, ...],只给
///   emoji 段单独设 `fontFamily: 'Noto Color Emoji'`。普通文本仍走 Roboto,
///   度量不受污染;emoji 字符走打包的彩色字体,变彩色。**正解**。
///
/// ## 前提
/// 需在 pubspec 打包 'Noto Color Emoji' 字体(CBDT 格式),否则 fontFamily 引用无效。
///
/// ## 维护
/// 「需要强制彩色」的字符集 [_forceEmojiChars] 来自 Unicode UTS #51 的
/// 「默认 text 形态」emoji 字符(已排除键帽基础 # * 0-9,避免数字被污染)。
/// 字体子集用 scripts/subset-emoji.sh 重新生成。
library;

import 'package:flutter/material.dart';

/// 「Roboto cmap 抢占单色」的字符集(裸字符,不含 FE0F)。
///
/// 来自 Unicode 16.0 emoji-data.txt 的「有 Emoji 属性、无 Emoji_Presentation 属性」
/// 字符(默认 text 形态),排除键帽基础 # * 0-9(其 emoji 字形是键帽底框,会污染数字)。
/// 高码位 emoji(😀🔥 等)默认 emoji 形态本身彩色,不在此列。
const Set<int> _forceEmojiChars = {
    0x00A9, 0x00AE, 0x203C, 0x2049, 0x2122, 0x2139, 0x2194, 0x2195,
    0x2196, 0x2197, 0x2198, 0x2199, 0x21A9, 0x21AA, 0x2328, 0x23CF,
    0x23ED, 0x23EE, 0x23EF, 0x23F1, 0x23F2, 0x23F8, 0x23F9, 0x23FA,
    0x24C2, 0x25AA, 0x25AB, 0x25B6, 0x25C0, 0x25FB, 0x25FC, 0x2600,
    0x2601, 0x2602, 0x2603, 0x2604, 0x260E, 0x2611, 0x2618, 0x261D,
    0x2620, 0x2622, 0x2623, 0x2626, 0x262A, 0x262E, 0x262F, 0x2638,
    0x2639, 0x263A, 0x2640, 0x2642, 0x265F, 0x2660, 0x2663, 0x2665,
    0x2666, 0x2668, 0x267B, 0x267E, 0x2692, 0x2694, 0x2695, 0x2696,
    0x2697, 0x2699, 0x269B, 0x269C, 0x26A0, 0x26A7, 0x26B0, 0x26B1,
    0x26C8, 0x26CF, 0x26D1, 0x26D3, 0x26E9, 0x26F0, 0x26F1, 0x26F4,
    0x26F7, 0x26F8, 0x26F9, 0x2702, 0x2708, 0x2709, 0x270C, 0x270D,
    0x270F, 0x2712, 0x2714, 0x2716, 0x271D, 0x2721, 0x2733, 0x2734,
    0x2744, 0x2747, 0x2763, 0x2764, 0x27A1, 0x2934, 0x2935, 0x2B05,
    0x2B06, 0x2B07, 0x3030, 0x303D, 0x3297, 0x3299,
  };

/// 彩色 emoji 字体 family 名(与 pubspec 声明一致)。
const String _emojiFont = 'Noto Color Emoji';

/// 检测 [text] 是否含需要强制彩色的字符。
bool containsForceEmoji(String text) {
  for (final c in text.runes) {
    if (_forceEmojiChars.contains(c)) return true;
  }
  return false;
}

/// 把文本切成 [普通段, emoji段, ...] 的 TextSpan 列表,只给 emoji 段设彩色字体。
///
/// 底层切片逻辑,[buildEmojiColoredText](给 Text) 和
/// [EmojiEditingController.buildTextSpan](给 TextField) 都基于它。
/// 不含目标字符时返回空列表(调用方自行处理原样返回)。
List<TextSpan> splitEmojiSpans(String text, TextStyle? style) {
  if (!containsForceEmoji(text)) return [];

  final spans = <TextSpan>[];
  final normalBuf = StringBuffer();
  final emojiBuf = StringBuffer();
  var inEmoji = false;

  void flushNormal() {
    if (normalBuf.isNotEmpty) {
      spans.add(TextSpan(text: normalBuf.toString(), style: style));
      normalBuf.clear();
    }
  }

  void flushEmoji() {
    if (emojiBuf.isNotEmpty) {
      spans.add(TextSpan(
        text: emojiBuf.toString(),
        style: (style ?? const TextStyle()).copyWith(fontFamily: _emojiFont),
      ));
      emojiBuf.clear();
    }
  }

  for (final c in text.runes) {
    final isForce = _forceEmojiChars.contains(c);
    final isVs16 = c == 0xFE0F; // 变体选择符,跟在 emoji 后
    if (isForce) {
      if (!inEmoji) {
        flushNormal();
        inEmoji = true;
      }
      emojiBuf.writeCharCode(c);
    } else if (isVs16 && inEmoji) {
      // FE0F 紧跟 emoji,归入 emoji 段
      emojiBuf.writeCharCode(c);
    } else {
      if (inEmoji) {
        flushEmoji();
        inEmoji = false;
      }
      normalBuf.writeCharCode(c);
    }
  }
  flushNormal();
  flushEmoji();
  return spans;
}

/// 构建精确分 span 的 [Text]:emoji 字符走 Noto Color Emoji,普通文本走默认字体。
///
/// 不含目标字符时返回普通 [Text](零开销)。含则用 [Text.rich] 把文本切成
/// 普通段 + emoji 段交替,只给 emoji 段设 [fontFamily]。
///
/// [maxLines]/[overflow] 等透传给 [Text],支持会话列表摘要单行省略。
Text buildEmojiColoredText(
  String text, {
  TextStyle? style,
  int? maxLines,
  TextOverflow? overflow,
  bool? softWrap,
}) {
  if (!containsForceEmoji(text)) {
    return Text(text,
        style: style, maxLines: maxLines, overflow: overflow, softWrap: softWrap);
  }

  final spans = splitEmojiSpans(text, style);
  return Text.rich(
    TextSpan(children: spans),
    maxLines: maxLines,
    overflow: overflow,
    softWrap: softWrap,
  );
}
