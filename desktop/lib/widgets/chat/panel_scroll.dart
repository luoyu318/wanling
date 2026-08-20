import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;

/// 面板列表项最小滚动:目标项可见则不动,越出视口才滚到刚好可见。
///
/// 不用 Scrollable.ensureVisible:其默认 alignment 0.0 会把目标强行对齐
/// 视口边缘,hover 触发的高亮变化经它滚动后,鼠标下的 item 随列表移动
/// 变号再次触发 hover → 连环滚动。本函数目标可见即返回,根治该问题。
void revealItemMinimal(BuildContext itemCtx, {bool animate = true}) {
  final ro = itemCtx.findRenderObject();
  if (ro == null) return;

  final viewport = RenderAbstractViewport.of(ro);
  final lead = viewport.getOffsetToReveal(ro, 0.0).offset;
  final trail = viewport.getOffsetToReveal(ro, 1.0).offset;
  final pos = Scrollable.of(itemCtx).position;
  final target = pos.pixels < lead
      ? lead
      : pos.pixels > trail
      ? trail
      : pos.pixels;
  if (target == pos.pixels) return;
  final clamped = target.clamp(pos.minScrollExtent, pos.maxScrollExtent);
  if (animate) {
    pos.animateTo(
      clamped,
      duration: const Duration(milliseconds: 80),
      curve: Curves.easeOut,
    );
  } else {
    pos.jumpTo(clamped);
  }
}
