import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/account_mark.dart';

void main() {
  group('AccountMark', () {
    test('toJson 序列化包含 colorIndex 和 emoji', () {
      final m = AccountMark(colorIndex: 2, emoji: '🟢');
      expect(m.toJson(), {'colorIndex': 2, 'emoji': '🟢'});
    });

    test('toJson emoji 为 null 时不包含 emoji 键', () {
      final m = AccountMark(colorIndex: 0);
      expect(m.toJson(), {'colorIndex': 0});
    });

    test('fromJson 完整字段', () {
      final m = AccountMark.fromJson({'colorIndex': 3, 'emoji': '🐱'});
      expect(m.colorIndex, 3);
      expect(m.emoji, '🐱');
    });

    test('fromJson 缺 emoji 字段返回 null', () {
      final m = AccountMark.fromJson({'colorIndex': 1});
      expect(m.colorIndex, 1);
      expect(m.emoji, isNull);
    });

    test('相等性看 colorIndex + emoji', () {
      expect(
        AccountMark(colorIndex: 2, emoji: '🟢'),
        AccountMark(colorIndex: 2, emoji: '🟢'),
      );
      expect(
        AccountMark(colorIndex: 2, emoji: '🟢').hashCode,
        AccountMark(colorIndex: 2, emoji: '🟢').hashCode,
      );
    });

    test('不同 colorIndex 不相等', () {
      expect(
        AccountMark(colorIndex: 1) == AccountMark(colorIndex: 2),
        isFalse,
      );
    });
  });
}
