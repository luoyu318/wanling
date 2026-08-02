import 'dart:math';
import 'package:flutter/material.dart';
import 'three_body_physics.dart';

class ThreeBodyIndicator extends StatefulWidget {
  const ThreeBodyIndicator({super.key});

  @override
  State<ThreeBodyIndicator> createState() => _ThreeBodyIndicatorState();
}

class _ThreeBodyIndicatorState extends State<ThreeBodyIndicator>
    with SingleTickerProviderStateMixin {
  static const _colors = [
    Color(0xFF26C6DA),
    Color(0xFF5C9CE6),
    Color(0xFFA5D6A7),
  ];

  late final AnimationController _ctrl;
  late final ThreeBodyPhysics _physics;

  @override
  void initState() {
    super.initState();
    _physics = ThreeBodyPhysics();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(_onTick)..repeat();
  }

  void _onTick() {
    for (int i = 0; i < 3; i++) {
      _physics.step();
    }
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
      builder: (_, _) => CustomPaint(
        size: Size.infinite,
        painter: _ThreeBodyPainter(
          physics: _physics,
          colors: _colors,
          breathePhase: _ctrl.value,
        ),
      ),
    );
  }
}

class _ThreeBodyPainter extends CustomPainter {
  final ThreeBodyPhysics physics;
  final List<Color> colors;
  final double breathePhase;

  const _ThreeBodyPainter({
    required this.physics,
    required this.colors,
    required this.breathePhase,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final physScale = size.shortestSide * 0.42;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final bodies = physics.bodies;

    double cmx = 0, cmy = 0;
    for (final b in bodies) {
      cmx += b.x;
      cmy += b.y;
    }
    cmx /= 3;
    cmy /= 3;

    final trail = physics.trail;
    for (int t = 0; t < trail.length; t++) {
      final frame = trail[t];
      final age = (trail.length - t) / trail.length;
      final trailAlpha = (1 - age) * 0.15;
      final trailR = size.shortestSide * 0.02;
      final tp = Paint()
        ..color = colors[0].withValues(alpha: trailAlpha);
      canvas.drawCircle(
          Offset(cx + frame.x0 * physScale, cy + frame.y0 * physScale),
          trailR, tp);
      canvas.drawCircle(
          Offset(cx + frame.x1 * physScale, cy + frame.y1 * physScale),
          trailR, tp);
      canvas.drawCircle(
          Offset(cx + frame.x2 * physScale, cy + frame.y2 * physScale),
          trailR, tp);
    }

    final baseR = size.shortestSide * 0.05;
    final zR = size.shortestSide * 0.14;
    final glowSigma = size.shortestSide * 0.06;

    for (int i = 0; i < bodies.length; i++) {
      final b = bodies[i];
      final color = colors[i];
      final dist = sqrt((b.x - cmx) * (b.x - cmx) + (b.y - cmy) * (b.y - cmy));
      final z = 1 / (1 + dist * 0.7);
      final px = cx + b.x * physScale;
      final py = cy + b.y * physScale;

      final breathe =
          0.5 + 0.5 * sin((breathePhase * 2 * pi) - i * 1.2);
      final radius = baseR + z * zR + breathe * size.shortestSide * 0.015;
      final alpha = (0.35 + z * 0.65 + breathe * 0.15).clamp(0.0, 1.0);

      final glow = Paint()
        ..color = color.withValues(alpha: alpha * 0.3)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, glowSigma);
      canvas.drawCircle(Offset(px, py), radius * 1.6, glow);

      final core = Paint()..color = color.withValues(alpha: alpha);
      canvas.drawCircle(Offset(px, py), radius, core);
    }
  }

  @override
  bool shouldRepaint(_) => true;
}
