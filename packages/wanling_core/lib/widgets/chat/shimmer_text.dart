import 'dart:math' as math;

import 'package:flutter/material.dart';

class ShimmerText extends StatefulWidget {
  final String text;
  final Color baseColor;
  final TextStyle style;

  const ShimmerText({
    super.key,
    required this.text,
    required this.baseColor,
    required this.style,
  });

  @override
  State<ShimmerText> createState() => _ShimmerTextState();
}

class _ShimmerTextState extends State<ShimmerText>
    with SingleTickerProviderStateMixin {
  static const _highlight = Color(0xFFFF6B35);

  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chars = widget.text.characters.toList();
    final dark = HSLColor.fromColor(widget.baseColor)
        .withLightness(
            (HSLColor.fromColor(widget.baseColor).lightness - 0.15)
                .clamp(0.0, 1.0))
        .toColor();
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < chars.length; i++)
              Text(
                chars[i],
                style: widget.style.copyWith(
                  color: Color.lerp(
                    dark,
                    _highlight,
                    0.5 +
                        0.5 *
                            math.sin(
                                (_ctrl.value * 2 * math.pi) - i * 0.4),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
