import 'package:flutter/material.dart';

/// 卡片按钮状态
enum CardButtonState { active, selected, disabled }

/// 审批卡片按钮。强对比三色：绿 #07C160 / 蓝 #1989FA / 红 #FA5151。
/// 用 Material Icons 代替 SVG（避免引入 flutter_svg 依赖）。
class CardButton extends StatelessWidget {
  final String label;
  final String iconName; // check / shield / x
  final String style; // primary / info / danger
  final CardButtonState state;
  final VoidCallback? onTap;

  const CardButton({
    super.key,
    required this.label,
    required this.iconName,
    required this.style,
    this.state = CardButtonState.active,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDisabled = state == CardButtonState.disabled;
    final isSelected = state == CardButtonState.selected;

    Color bgColor;
    Color fgColor = Colors.white;

    if (isDisabled) {
      bgColor = const Color(0xFFE0E0E0);
      fgColor = const Color(0xFF9E9E9E);
    } else if (isSelected) {
      bgColor = _darkenedColor();
    } else {
      bgColor = _activeColor();
    }

    return GestureDetector(
      onTap: isDisabled ? null : onTap,
      child: Container(
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(6),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: bgColor.withValues(alpha: 0.2),
                    blurRadius: 0,
                    spreadRadius: 2,
                  )
                ]
              : null,
        ),
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(_mapIcon(iconName), color: fgColor, size: 14),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                color: fgColor,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _activeColor() {
    switch (style) {
      case 'info':
        return const Color(0xFF1989FA);
      case 'danger':
        return const Color(0xFFFA5151);
      default:
        return const Color(0xFF07C160);
    }
  }

  Color _darkenedColor() {
    return Color.alphaBlend(const Color(0x20000000), _activeColor());
  }

  IconData _mapIcon(String name) {
    switch (name) {
      case 'check':
        return Icons.check;
      case 'shield':
        return Icons.shield;
      case 'x':
        return Icons.close;
      default:
        return Icons.circle;
    }
  }
}
