import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 无边框窗口的边缘拖拽缩放热区。
///
/// 背景:setAsFrameless() 去掉系统装饰后,Windows 不再预留系统缩放边
/// (原 TitleBarStyle.hidden 会在 WM_NCCALCSIZE 预留 8px 非客户区,而
/// 窗口类无背景刷 → 涂黑成黑边,已弃用)。改为 Flutter 自绘 6px 边角
/// 热区,按下调用 window_manager startResizing 交给系统拖拽
/// (GTK begin_resize_drag / Win32 SC_SIZE),四角后放覆盖四边。
class WindowResizeEdges extends StatelessWidget {
  final Widget child;

  /// 热区厚度(px)。
  static const double _w = 6;

  const WindowResizeEdges({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        // 四边(先放,被四角覆盖交叉区)。
        _zone(ResizeEdge.top,
            cursor: SystemMouseCursors.resizeUp,
            left: _w, right: _w, top: 0, height: _w),
        _zone(ResizeEdge.bottom,
            cursor: SystemMouseCursors.resizeDown,
            left: _w, right: _w, bottom: 0, height: _w),
        _zone(ResizeEdge.left,
            cursor: SystemMouseCursors.resizeLeft,
            top: _w, bottom: _w, left: 0, width: _w),
        _zone(ResizeEdge.right,
            cursor: SystemMouseCursors.resizeRight,
            top: _w, bottom: _w, right: 0, width: _w),
        // 四角。
        _zone(ResizeEdge.topLeft,
            cursor: SystemMouseCursors.resizeUpLeft,
            left: 0, top: 0, width: _w, height: _w),
        _zone(ResizeEdge.topRight,
            cursor: SystemMouseCursors.resizeUpRight,
            right: 0, top: 0, width: _w, height: _w),
        _zone(ResizeEdge.bottomLeft,
            cursor: SystemMouseCursors.resizeDownLeft,
            left: 0, bottom: 0, width: _w, height: _w),
        _zone(ResizeEdge.bottomRight,
            cursor: SystemMouseCursors.resizeDownRight,
            right: 0, bottom: 0, width: _w, height: _w),
      ],
    );
  }

  Widget _zone(
    ResizeEdge edge, {
    MouseCursor cursor = MouseCursor.defer,
    double? left,
    double? top,
    double? right,
    double? bottom,
    double? width,
    double? height,
  }) {
    return Positioned(
      left: left,
      top: top,
      right: right,
      bottom: bottom,
      width: width,
      height: height,
      child: MouseRegion(
        cursor: cursor,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) => windowManager.startResizing(edge),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}
