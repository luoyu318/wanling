import 'package:flutter/material.dart';

/// 聊天首屏加载骨架屏。
///
/// 6 个 shimmer 灰块左右交替模拟气泡轮廓,用于 server 就绪前盖住双 sliver
/// center 的空白锚点。不内置 opacity——淡出由父级用 AnimatedOpacity 包裹控制。
/// 背景透明(不盖会话区背景),只画气泡轮廓灰块。
class ChatLoadingSkeleton extends StatefulWidget {
  const ChatLoadingSkeleton({super.key});

  @override
  State<ChatLoadingSkeleton> createState() => _ChatLoadingSkeletonState();
}

class _ChatLoadingSkeletonState extends State<ChatLoadingSkeleton>
    with SingleTickerProviderStateMixin {
  /// 6 块灰块规格:对齐 / 宽度占比 / 高度。左右交替模拟聊天气泡。
  static const _rowSpecs = <({Alignment align, double widthFactor, double height})>[
    (align: Alignment.centerLeft, widthFactor: 0.55, height: 28.0),
    (align: Alignment.centerRight, widthFactor: 0.65, height: 28.0),
    (align: Alignment.centerLeft, widthFactor: 0.45, height: 28.0),
    (align: Alignment.centerRight, widthFactor: 0.60, height: 56.0),
    (align: Alignment.centerLeft, widthFactor: 0.50, height: 28.0),
    (align: Alignment.centerRight, widthFactor: 0.55, height: 56.0),
  ];

  static const _baseColor = Color(0xFFE0E0E0);
  static const _highlightColor = Color(0xFFEAEAEA);

  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (context, _) {
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final spec in _rowSpecs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Align(
                    alignment: spec.align,
                    child: FractionallySizedBox(
                      widthFactor: spec.widthFactor,
                      child: _shimmerBox(spec.height),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  /// shimmer 灰块:ShaderMask 用横向滑动的渐变重绘,模拟高亮带左→右横扫。
  Widget _shimmerBox(double height) {
    final dx = _ctrl.value * 2 - 1;
    return ShaderMask(
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) {
        return LinearGradient(
          begin: Alignment(dx - 0.5, 0),
          end: Alignment(dx + 0.5, 0),
          colors: const [_baseColor, _highlightColor, _baseColor],
        ).createShader(bounds);
      },
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );
  }
}
