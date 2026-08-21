import 'package:flutter/material.dart';

import '../theme/desktop_theme.dart';

/// 浮动卡片容器:12px 圆角 + 卡片底色,内容裁进圆角。
/// color 缺省取当前主题卡片色(聊天区传 chatCardColor 区分)。
class CardContainer extends StatelessWidget {
  final Widget child;
  final Color? color;
  final EdgeInsetsGeometry padding;

  const CardContainer({
    super.key,
    required this.child,
    this.color,
    this.padding = EdgeInsets.zero,
  });

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return Container(
      decoration: BoxDecoration(
        color: color ?? DesktopTheme.cardColor(brightness),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      padding: padding,
      child: child,
    );
  }
}
