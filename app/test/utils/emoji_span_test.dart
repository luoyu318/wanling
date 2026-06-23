import 'package:app/utils/emoji_span.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('containsForceEmoji', () {
    test('含默认 text 形态字符返回 true', () {
      expect(containsForceEmoji('♻️'), isTrue);
      expect(containsForceEmoji('⚠️注意'), isTrue);
      expect(containsForceEmoji('✂️'), isTrue);
      // ☀️✈️ 也是默认 text 形态,纳入强制彩色集合
      expect(containsForceEmoji('☀️✈️'), isTrue);
    });

    test('不含目标字符返回 false(纯文本/高码位彩色 emoji 不算)', () {
      expect(containsForceEmoji('普通文本'), isFalse);
      // 😀🔥 是高码位 emoji(默认 emoji 形态),本身彩色,不在集合
      expect(containsForceEmoji('😀🔥'), isFalse);
      expect(containsForceEmoji(''), isFalse);
    });
  });

  group('buildEmojiColoredText', () {
    test('不含目标字符返回普通 Text(无 span 拆分)', () {
      final w = buildEmojiColoredText('Hello 世界 123');
      expect(w, isA<Text>());
      expect((w as Text).data, 'Hello 世界 123');
      // 普通 Text 的 textSpan 为 null(data 模式),不是 TextSpan 列表
      expect(w.textSpan, isNull);
    });

    test('含 ♻️ 时拆分为普通段 + emoji段,emoji段设 Noto Color Emoji 字体', () {
      final w = buildEmojiColoredText('♻️ online') as Text;
      final span = w.textSpan! as TextSpan;
      expect(span.children, isNotNull);
      // 应有 emoji 段 + 普通段(开头的 emoji 段 + 「 online」普通段)
      final spans = span.children!.cast<TextSpan>();
      // 找到 emoji 段(含 ♻)
      final emojiSpan = spans.firstWhere((s) => s.text!.contains('♻'));
      expect(emojiSpan.style!.fontFamily, 'Noto Color Emoji');
      // 普通段不应设 emoji 字体
      final normalSpan = spans.firstWhere((s) => s.text!.contains('online'));
      expect(normalSpan.style?.fontFamily == 'Noto Color Emoji', isFalse);
    });

    test('数字字符不会被分到 emoji 段(防数字变宽)', () {
      final w = buildEmojiColoredText('♻️ 123 ⚠️') as Text;
      final span = w.textSpan! as TextSpan;
      final spans = span.children!.cast<TextSpan>();
      // 找含「123」的 span,它应是普通段(非 emoji 字体)
      final numSpan = spans.firstWhere((s) => s.text!.contains('123'));
      expect(numSpan.style?.fontFamily == 'Noto Color Emoji', isFalse);
    });

    test('FE0F 变体符跟随 emoji 归入 emoji 段', () {
      final w = buildEmojiColoredText('♻️') as Text;
      final span = w.textSpan! as TextSpan;
      final spans = span.children!.cast<TextSpan>();
      final emojiSpan = spans.first;
      // ♻ + FE0F 都在 emoji 段
      expect(emojiSpan.text, '♻️');
      expect(emojiSpan.style!.fontFamily, 'Noto Color Emoji');
    });

    test('透传 style 给普通段和 emoji 段(emoji 段在 style 基础上覆盖 fontFamily)', () {
      const base = TextStyle(fontSize: 16, fontWeight: FontWeight.w300);
      final w = buildEmojiColoredText('x♻️y', style: base) as Text;
      final span = w.textSpan! as TextSpan;
      final spans = span.children!.cast<TextSpan>();
      final emojiSpan = spans.firstWhere((s) => s.text!.contains('♻'));
      // emoji 段保留 fontSize/fontWeight,并叠加 fontFamily
      expect(emojiSpan.style!.fontSize, 16);
      expect(emojiSpan.style!.fontWeight, FontWeight.w300);
      expect(emojiSpan.style!.fontFamily, 'Noto Color Emoji');
    });

    test('多个 emoji 交替出现,各自独立成段', () {
      final w = buildEmojiColoredText('a♻️b⚠️c') as Text;
      final span = w.textSpan! as TextSpan;
      final spans = span.children!.cast<TextSpan>();
      // 应交替:a | ♻️ | b | ⚠️ | c
      expect(spans.length, 5);
      expect(spans[0].text, 'a');
      expect(spans[1].text, '♻️');
      expect(spans[1].style!.fontFamily, 'Noto Color Emoji');
      expect(spans[2].text, 'b');
      expect(spans[3].text, '⚠️');
      expect(spans[3].style!.fontFamily, 'Noto Color Emoji');
      expect(spans[4].text, 'c');
    });
  });
}
