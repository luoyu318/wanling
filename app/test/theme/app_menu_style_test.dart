import 'package:app/theme/app_menu_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppMenuStyle 色板锁定', () {
    test('深色菜单色值正确', () {
      expect(AppMenuStyle.darkBg, const Color(0xE6262626));
      expect(AppMenuStyle.darkFg, Colors.white);
      expect(AppMenuStyle.darkDanger, const Color(0xFFFF5B5B));
      expect(AppMenuStyle.darkDivider, const Color(0x1FFFFFFF));
    });

    test('阴影规格正确', () {
      expect(AppMenuStyle.shadow.color, const Color(0x66000000));
      expect(AppMenuStyle.shadow.blurRadius, 20);
      expect(AppMenuStyle.shadow.offset, const Offset(0, 6));
    });

    test('圆角规格正确', () {
      expect(AppMenuStyle.radiusAnchor, 4);
      expect(AppMenuStyle.radiusFloating, 8);
    });
  });
}
