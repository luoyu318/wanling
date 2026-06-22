import 'package:flutter/material.dart';

/// 未读消息红圆 badge。
///
/// count == 0 渲染 SizedBox.shrink（不占视觉空间）。
/// count > 99 显示 "99+"（参考主流 IM）。
///
/// 用法：Stack 包头像/图标，positioned 放右上角。
class UnreadBadge extends StatelessWidget {
  final int count;
  final double radius;

  const UnreadBadge({super.key, required this.count, this.radius = 9});

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final text = count > 99 ? '99+' : count.toString();
    // 数字 1 位数用小圆，2 位数椭圆。
    final isLong = text.length > 1;
    return Container(
      constraints: BoxConstraints(
        minWidth: isLong ? radius * 2.4 : radius * 2,
        minHeight: radius * 2,
      ),
      padding: EdgeInsets.symmetric(
        horizontal: isLong ? 4 : 0,
        vertical: 0,
      ),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: const Color(0xFFFA5151),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
