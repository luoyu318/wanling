import 'package:flutter_test/flutter_test.dart';

import 'package:app/widgets/chat/menu_placement.dart';

void main() {
  group('MenuPlacement', () {
    test('== 字段全等判 true', () {
      const a = MenuPlacement(
        left: 10,
        top: 20,
        tailOffsetX: 5,
        pointDown: true,
      );
      const b = MenuPlacement(
        left: 10,
        top: 20,
        tailOffsetX: 5,
        pointDown: true,
      );
      expect(a == b, isTrue);
    });

    test('任一字段不等判 false', () {
      const base = MenuPlacement(
        left: 10,
        top: 20,
        tailOffsetX: 5,
        pointDown: true,
      );
      // 逐字段变化,验证每个字段都参与判等
      expect(base == const MenuPlacement(left: 99, top: 20, tailOffsetX: 5, pointDown: true), isFalse, reason: 'left 不等应判 false');
      expect(base == const MenuPlacement(left: 10, top: 99, tailOffsetX: 5, pointDown: true), isFalse, reason: 'top 不等应判 false');
      expect(base == const MenuPlacement(left: 10, top: 20, tailOffsetX: 99, pointDown: true), isFalse, reason: 'tailOffsetX 不等应判 false');
      expect(base == const MenuPlacement(left: 10, top: 20, tailOffsetX: 5, pointDown: false), isFalse, reason: 'pointDown 不等应判 false');
    });

    test('hashCode 一致性:等价对象 hashCode 相同', () {
      const a = MenuPlacement(
        left: 10.5,
        top: 20.5,
        tailOffsetX: 5.5,
        pointDown: false,
      );
      const b = MenuPlacement(
        left: 10.5,
        top: 20.5,
        tailOffsetX: 5.5,
        pointDown: false,
      );
      expect(a.hashCode, b.hashCode);
    });

    test('const 构造 + identical', () {
      const a = MenuPlacement(
        left: 0,
        top: 0,
        tailOffsetX: 0,
        pointDown: true,
      );
      const b = MenuPlacement(
        left: 0,
        top: 0,
        tailOffsetX: 0,
        pointDown: true,
      );
      // const 构造的等价字面量在 Dart 中应 identical(const canonicalization)
      expect(identical(a, b), isTrue);
    });

    test('与其它类型比较判 false(不是 MenuPlacement)', () {
      const a = MenuPlacement(
        left: 10,
        top: 20,
        tailOffsetX: 5,
        pointDown: true,
      );
      expect(a == 'not a MenuPlacement', isFalse);
      expect(a == 42, isFalse);
    });
  });
}
