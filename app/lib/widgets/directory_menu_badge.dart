import 'package:flutter/material.dart';

/// 目录切换按钮上的双色角标(方案 C 定稿)。
///
/// - 红色未读数:右上,贴 Icon 角(半压边)
/// - 橙色待处理数:左下,镜像对称
/// - 两者独立计数,避免未读/待处理重叠导致数字虚高
///
/// 用法:Stack 包 IconButton,把本 widget 的 children 展开进去。
/// 定位基于 48×48 的 IconButton 尺寸(Icon 24×24 居中,角在 12px 处)。
class DirectoryMenuBadge {
  /// 返回 Positioned 列表,空列表表示无角标。
  ///
  /// 每个 badge 包裹 [IgnorePointer],不拦截下层 IconButton 的点击事件。
  static List<Widget> build({required int unread, required int pending}) {
    return [
      if (unread > 0)
        Positioned(
          top: 10,
          right: 10,
          child: IgnorePointer(
            child: _BadgePill(count: unread, color: const Color(0xFFFA5151)),
          ),
        ),
      if (pending > 0)
        Positioned(
          bottom: 10,
          left: 10,
          child: IgnorePointer(
            child: _BadgePill(count: pending, color: const Color(0xFFFF9500)),
          ),
        ),
    ];
  }
}

/// 胶囊 badge(复用 UnreadBadge 风格)。
class _BadgePill extends StatelessWidget {
  final int count;
  final Color color;

  const _BadgePill({required this.count, required this.color});

  @override
  Widget build(BuildContext context) {
    final text = count > 99 ? '99+' : count.toString();
    final isLong = text.length > 1;
    return Container(
      constraints: BoxConstraints(
        minWidth: isLong ? 22 : 16,
        minHeight: 16,
      ),
      padding: EdgeInsets.symmetric(horizontal: isLong ? 4 : 0),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white, width: 1.5),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 10,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
