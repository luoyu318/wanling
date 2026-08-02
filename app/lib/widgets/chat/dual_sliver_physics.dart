import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';

/// 双 sliver center 几何专用的滚动物理。
///
/// 背景:CustomScrollView(center=live) 在 live 为空时 maxScrollExtent=0
/// (viewport.dart:1734:max(0, trailingExtent - vd))。但 leading(history)
/// 反向 sliver 在 px > -vd 时因 reversePaint=0 不绘制(viewport.dart:1782),
/// 放任 px 进入 (-vd, 0] 会露出空白屏。
///
/// 本物理把 live 空时的有效上界从 maxScrollExtent(=0) 收紧为
/// max(minScrollExtent, -viewportDimension),与 dualSliverBottomTarget 一致,
/// 让用户手动下滑/惯性滑动都无法越过最新消息进入空白区。
///
/// live 非空(会话中有活跃消息)时退化为普通 [ClampingScrollPhysics]。
class DualSliverClampingPhysics extends ClampingScrollPhysics {
  const DualSliverClampingPhysics({
    super.parent,
    required this.getLiveEmpty,
  });

  /// 活跃 sliver(liveMessages)是否为空。每次边界判定实时读取,
  /// 支持用户发消息后 live 从空→非空的动态切换。
  final bool Function() getLiveEmpty;

  @override
  DualSliverClampingPhysics applyTo(ScrollPhysics? ancestor) {
    return DualSliverClampingPhysics(
      parent: buildParent(ancestor),
      getLiveEmpty: getLiveEmpty,
    );
  }

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    final effectiveMax = getLiveEmpty()
        ? math.max(position.minScrollExtent, -position.viewportDimension)
        : position.maxScrollExtent;
    if (value < position.pixels && position.pixels <= position.minScrollExtent) {
      return value - position.pixels;
    }
    if (effectiveMax <= position.pixels && position.pixels < value) {
      return value - position.pixels;
    }
    if (value < position.minScrollExtent &&
        position.minScrollExtent < position.pixels) {
      return value - position.minScrollExtent;
    }
    if (position.pixels < effectiveMax && effectiveMax < value) {
      return value - effectiveMax;
    }
    return 0.0;
  }

  /// viewport dimension 变化(键盘弹起/收起、旋转屏)时,保持视口底部边缘在
  /// 内容坐标系中的位置恒定,模拟改造前 `ListView(reverse:true)`(axisDirection.up,
  /// 底部锚定)的自然行为。
  ///
  /// 默认实现(scroll_physics.dart:362)返回 `newPosition.pixels`——保持 pixels 不变。
  /// 在 axisDirection.down(center sliver)几何下,pixels 不变意味着 viewport 缩小时
  /// 内容不跟随上移,底部被键盘遮挡。
  ///
  /// 守恒公式:`newPixels = oldPixels + oldVd - newVd`(oldVd/newVd 为前后 viewport
  /// dimension),使 `newPixels + newVd == oldPixels + oldVd`(底部边缘坐标守恒)。
  /// 仅在 viewport dimension 真正变化时介入;content 变化(新消息/loadMore)走 super 默认。
  @override
  double adjustPositionForNewDimensions({
    required ScrollMetrics oldPosition,
    required ScrollMetrics newPosition,
    required bool isScrolling,
    required double velocity,
  }) {
    if (oldPosition.viewportDimension == newPosition.viewportDimension) {
      return super.adjustPositionForNewDimensions(
        oldPosition: oldPosition,
        newPosition: newPosition,
        isScrolling: isScrolling,
        velocity: velocity,
      );
    }
    final oldBottom = getLiveEmpty()
        ? math.max(oldPosition.minScrollExtent, -oldPosition.viewportDimension)
        : oldPosition.maxScrollExtent;
    final wasAtBottom = (oldPosition.pixels - oldBottom).abs() <= 50;
    if (wasAtBottom) {
      // 贴底场景(如键盘收起 vd 增大):应保持贴底(对齐新底部),而非底部边缘守恒把
      // px 往负方向拉。守恒公式 target=oldPx+oldVd-newVd 在 vd 增大时为负,若
      // 内容不足一屏(live 非空 maxScrollExtent=0)或历史存在,会把 live sliver
      // 推出视口下方露出空屏。键盘弹起(vd 缩小)同样走这里对齐新底部。
      return getLiveEmpty()
          ? math.max(newPosition.minScrollExtent, -newPosition.viewportDimension)
          : newPosition.maxScrollExtent;
    }
    // 看历史场景(不在底部):底部边缘守恒,保持相对位置。
    final delta = oldPosition.viewportDimension - newPosition.viewportDimension;
    final target = oldPosition.pixels + delta;
    final effectiveMax = getLiveEmpty()
        ? math.max(newPosition.minScrollExtent, -newPosition.viewportDimension)
        : newPosition.maxScrollExtent;
    if (target < newPosition.minScrollExtent) return newPosition.minScrollExtent;
    if (target > effectiveMax) return effectiveMax;
    return target;
  }
}
