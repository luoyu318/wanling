import 'package:app/widgets/panel_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('高度按内容收缩，不撑满父级 maxHeight', (tester) async {
    // 故意给一个远大于内容（~75）的父容器，
    // 验证 Column 的 mainAxisSize.min 让 PanelItem 收缩到内容真实高度，
    // 而不是被父级 loose 约束撑满（曾导致画廊 BottomSheet 显示成半屏）。
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 500,
            child: Row(
              children: const [
                PanelItem(
                  icon: Icons.download_for_offline_outlined,
                  label: '保存图片',
                  onTap: noop,
                ),
              ],
            ),
          ),
        ),
      ),
    );

    final rect = tester.getRect(find.byType(PanelItem));
    // 不撑满父级 500
    expect(rect.height, lessThan(200));
    // 内容正常渲染（图标块 52 + 间距 6 + 文字行高 ≈ 75）
    expect(rect.height, greaterThan(60));
  });
}

void noop() {}
