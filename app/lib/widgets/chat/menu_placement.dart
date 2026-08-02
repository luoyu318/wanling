import 'package:flutter/foundation.dart';

/// 菜单定位缓存（用于滚动时比较，变化才重建 OverlayEntry）。
/// 全部用屏幕绝对坐标（脱离 LayerLink follower，实现锚钉效果）。
@immutable
class MenuPlacement {
  /// 菜单左缘屏幕 x（clamp 不超屏）。
  final double left;

  /// 菜单顶缘屏幕 y（clamp 在可见区内，钉边缘）。
  final double top;

  /// 三角在菜单内的水平偏移（指向消息中心）。
  final double tailOffsetX;

  /// 三角朝向：true=朝下（菜单在消息上方），false=朝上。
  final bool pointDown;

  const MenuPlacement({
    required this.left,
    required this.top,
    required this.tailOffsetX,
    required this.pointDown,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MenuPlacement &&
          left == other.left &&
          top == other.top &&
          tailOffsetX == other.tailOffsetX &&
          pointDown == other.pointDown;

  @override
  int get hashCode => Object.hash(left, top, tailOffsetX, pointDown);
}
