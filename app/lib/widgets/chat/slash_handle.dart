import 'package:flutter/material.dart';

/// 感应线吸附侧。
enum AttachSide { left, right }

/// 中点判定:相对 X < 0.5 贴左,≥ 0.5 贴右(纯函数,可单测)。
AttachSide attachSideForX(double relativeX) {
  return relativeX < 0.5 ? AttachSide.left : AttachSide.right;
}

/// 屏边感应线 — 触发斜杠命令面板(SlashCommandSheet)。
///
/// 3×66px 半透明灰,距屏边 6px(贴边,不遮挡内容)。
/// 点按 / 向内滑动 → 触发 onTrigger 打开命令面板。
/// 长按拖动 → 跟手,松手吸附到最近边。
///
/// 拖动范围限制在父容器(消息列表区域)内,不会进入底部输入框。
/// 拖动时触摸区放大为绿色高亮块提示用户。
class SlashHandle extends StatefulWidget {
  final bool visible;
  final VoidCallback onTrigger;

  /// 吸附侧变更回调(父级据此定位 SlashCommandSheet)。
  final ValueChanged<AttachSide>? onSideChanged;

  const SlashHandle({
    super.key,
    required this.visible,
    required this.onTrigger,
    this.onSideChanged,
  });

  @override
  State<SlashHandle> createState() => _SlashHandleState();
}

class _SlashHandleState extends State<SlashHandle> {
  AttachSide _side = AttachSide.right;
  double _relativeY = 0.35;
  bool _isDragging = false;

  /// 拖动时手指在父容器中的本地坐标(已减去父容器 origin)。
  Offset? _dragLocalPos;

  static const double _touchWidth = 44;
  static const double _defaultHeight = 66;
  static const double _dragHeight = 80;
  static const double _visibleLineWidth = 3;
  // 贴边距屏边 6px,不遮挡内容(系统返回手势区由点按为主触发规避)。
  static const double _edgePadding = 6;
  // 上下边距,避免感应线贴到容器顶/底。
  static const double _yMargin = 8;

  @override
  Widget build(BuildContext context) {
    if (!widget.visible) return const SizedBox.shrink();

    // SizedBox.expand 占满父容器(消息列表区域),LayoutBuilder 拿到的就是
    // 消息列表区域尺寸 — 拖动天然不会进入底部输入框。
    return SizedBox.expand(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final areaWidth = constraints.maxWidth;
          final areaHeight = constraints.maxHeight;

          const minTop = _yMargin;
          final maxDefaultTop =
              (areaHeight - _defaultHeight - _yMargin).clamp(minTop, areaHeight);
          final maxDragTop =
              (areaHeight - _dragHeight - _yMargin).clamp(minTop, areaHeight);

          final double left;
          final double top;
          final double touchH;
          if (_isDragging && _dragLocalPos != null) {
            touchH = _dragHeight;
            // 拖动跟手:x 不限制(松手才吸附),y 限制在可见范围避免拖出容器。
            left = _dragLocalPos!.dx - _touchWidth / 2;
            top = (_dragLocalPos!.dy - touchH / 2).clamp(minTop, maxDragTop);
          } else {
            touchH = _defaultHeight;
            left = _side == AttachSide.left
                ? _edgePadding
                : areaWidth - _edgePadding - _touchWidth;
            top = (areaHeight * _relativeY).clamp(minTop, maxDefaultTop);
          }

          final lineColor = _isDragging
              ? const Color(0xFF07C160)
              : const Color(0xFF888888).withValues(alpha: 0.35);
          final lineW = _isDragging ? _touchWidth : _visibleLineWidth;

          return Stack(
            children: [
              Positioned(
                left: left,
                top: top,
                child: GestureDetector(
                  key: const Key('slash-handle'),
                  behavior: HitTestBehavior.opaque,
                  onTap: _isDragging ? null : widget.onTrigger,
                  onHorizontalDragEnd: _isDragging
                      ? null
                      : (_) => widget.onTrigger(),
                  onLongPressStart: (details) => _onLongPressStart(details),
                  onLongPressMoveUpdate: (details) =>
                      _onLongPressMove(details),
                  onLongPressEnd: (details) =>
                      _onLongPressEnd(details, areaWidth, areaHeight),
                  child: SizedBox(
                    width: _touchWidth,
                    height: touchH,
                    child: Stack(
                      children: [
                        Positioned(
                          left: _side == AttachSide.left ? 0 : null,
                          right: _side == AttachSide.right ? 0 : null,
                          top: 0,
                          width: lineW,
                          height: touchH,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            decoration: BoxDecoration(
                              color: lineColor,
                              borderRadius: BorderRadius.all(
                                Radius.circular(_isDragging ? 6 : 2),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// 在手势回调里(layout 已完成)读取 SlashHandle 根 RenderObject 的
  /// 屏幕坐标 origin,把 globalPosition 换算成父容器本地坐标。
  Offset _toLocal(Offset globalPosition) {
    final renderBox = context.findRenderObject() as RenderBox?;
    final origin = renderBox?.localToGlobal(Offset.zero) ?? Offset.zero;
    return globalPosition - origin;
  }

  void _onLongPressStart(LongPressStartDetails details) {
    setState(() {
      _isDragging = true;
      _dragLocalPos = _toLocal(details.globalPosition);
    });
  }

  void _onLongPressMove(LongPressMoveUpdateDetails details) {
    setState(() {
      _dragLocalPos = _toLocal(details.globalPosition);
    });
  }

  void _onLongPressEnd(
      LongPressEndDetails details, double areaWidth, double areaHeight) {
    _handleDragEnd(
      _toLocal(details.globalPosition),
      areaWidth,
      areaHeight,
    );
  }

  void _handleDragEnd(
    Offset localPos,
    double areaWidth,
    double areaHeight,
  ) {
    // 中点判定吸附侧。
    final relativeX = localPos.dx / areaWidth;
    final newSide = attachSideForX(relativeX);
    // relativeY 限制在可见范围,避免吸附后贴到容器顶/底。
    final minRelativeY = _yMargin / areaHeight;
    final maxRelativeY =
        (areaHeight - _defaultHeight - _yMargin) / areaHeight;
    final newRelativeY =
        (localPos.dy / areaHeight).clamp(minRelativeY, maxRelativeY);

    setState(() {
      _side = newSide;
      _relativeY = newRelativeY;
      _isDragging = false;
      _dragLocalPos = null;
    });
    widget.onSideChanged?.call(newSide);
  }
}
