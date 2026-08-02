import 'package:flutter/material.dart';

/// 拿 GlobalKey 对应 RenderBox 的屏幕矩形。
/// key 未挂载 / 不是 RenderBox / 无 size → 返回 null。
Rect? globalRectOf(GlobalKey? key) {
  final ctx = key?.currentContext;
  if (ctx == null) return null;
  final box = ctx.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return null;
  return Rect.fromPoints(
    box.localToGlobal(Offset.zero),
    box.localToGlobal(Offset(box.size.width, box.size.height)),
  );
}

/// 拿 ListView 的屏幕矩形(可见区)。
/// 拿不到 RenderBox 时用 MediaQuery 全屏兜底。
Rect listViewRect(GlobalKey listViewKey, BuildContext context) {
  final box = listViewKey.currentContext?.findRenderObject();
  if (box is RenderBox && box.hasSize) {
    return Rect.fromPoints(
      box.localToGlobal(Offset.zero),
      box.localToGlobal(Offset(box.size.width, box.size.height)),
    );
  }
  return Offset.zero & MediaQuery.of(context).size;
}
