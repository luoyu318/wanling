import 'dart:async';

import 'package:flutter/material.dart';

/// 用 [Listener]（pointer 层）实现的轻量长按检测器。
///
/// 不进 gesture arena → 不会与内部手势识别器（如 SelectableRegion 的长按选词、
/// PhotoViewGallery 的 ScaleGestureRecognizer）抢手势。自己用 Timer 计时：
/// down 启动，移动超阈值或 up/cancel 取消，到点（500ms）触发回调。
class LongPressDetector extends StatefulWidget {
  final Widget child;
  final void Function(LongPressStartDetails)? onLongPressStart;

  const LongPressDetector({
    super.key,
    required this.child,
    this.onLongPressStart,
  });

  @override
  State<LongPressDetector> createState() => _LongPressDetectorState();
}

class _LongPressDetectorState extends State<LongPressDetector> {
  Offset? _downPos;
  Timer? _timer;
  static const Duration _longPressDelay = Duration(milliseconds: 500);
  static const double _moveSlop = 18;

  void _startTimer(Offset pos) {
    _downPos = pos;
    _timer?.cancel();
    _timer = Timer(_longPressDelay, () {
      if (_downPos != null && mounted) {
        widget.onLongPressStart?.call(
          LongPressStartDetails(
            globalPosition: _downPos!,
            localPosition: _downPos!,
          ),
        );
      }
    });
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
    _downPos = null;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (e) => _startTimer(e.position),
      onPointerMove: (e) {
        if (_downPos != null && (e.position - _downPos!).distance > _moveSlop) {
          _cancelTimer();
        }
      },
      onPointerUp: (_) => _cancelTimer(),
      onPointerCancel: (_) => _cancelTimer(),
      child: widget.child,
    );
  }
}
