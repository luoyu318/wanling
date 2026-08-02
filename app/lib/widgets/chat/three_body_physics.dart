import 'dart:math';

class Body {
  double x, y, vx, vy;
  double ax = 0, ay = 0;

  Body(this.x, this.y, this.vx, this.vy);
}

class TrailFrame {
  final double x0, y0, x1, y1, x2, y2;
  const TrailFrame(this.x0, this.y0, this.x1, this.y1, this.x2, this.y2);
}

class ThreeBodyPhysics {
  final List<Body> bodies;
  final List<TrailFrame> _trail = [];

  static const double G = 0.5;
  static const double rep = 0.08;
  static const double eps2 = 0.01;
  static const double dt = 0.018;
  static const double bound = 1.2;
  static const double bounce = 0.9;
  static const int maxTrail = 12;

  ThreeBodyPhysics() : bodies = _initBodies();

  static List<Body> _initBodies() {
    final a = Random().nextDouble() * 2 * pi;
    const r = 0.55;
    return [
      Body(cos(a) * r, sin(a) * r, -sin(a) * 0.72, cos(a) * 0.72),
      Body(cos(a + 2.0944) * r, sin(a + 2.0944) * r,
          -sin(a + 2.0944) * 0.72 - 0.04, cos(a + 2.0944) * 0.72),
      Body(cos(a + 4.1888) * r, sin(a + 4.1888) * r,
          -sin(a + 4.1888) * 0.72 + 0.04, cos(a + 4.1888) * 0.72),
    ];
  }

  List<TrailFrame> get trail => _trail;

  void step() {
    for (final b in bodies) {
      b.ax = 0;
      b.ay = 0;
    }
    for (int i = 0; i < 3; i++) {
      for (int j = i + 1; j < 3; j++) {
        final dx = bodies[j].x - bodies[i].x;
        final dy = bodies[j].y - bodies[i].y;
        final r2 = dx * dx + dy * dy + eps2;
        final r = sqrt(r2);
        final r3 = r2 * r;
        final r5 = r3 * r2;
        final aNet = G / r3 - rep / r5;
        bodies[i].ax += aNet * dx;
        bodies[i].ay += aNet * dy;
        bodies[j].ax -= aNet * dx;
        bodies[j].ay -= aNet * dy;
      }
    }
    double cmx = 0, cmy = 0;
    for (final b in bodies) {
      b.vx += b.ax * dt;
      b.vy += b.ay * dt;
      b.x += b.vx * dt;
      b.y += b.vy * dt;
      cmx += b.x;
      cmy += b.y;
    }
    cmx /= 3;
    cmy /= 3;
    for (final b in bodies) {
      b.x -= cmx;
      b.y -= cmy;
      if (b.x > bound) {
        b.x = bound;
        b.vx = -b.vx.abs() * bounce;
      } else if (b.x < -bound) {
        b.x = -bound;
        b.vx = b.vx.abs() * bounce;
      }
      if (b.y > bound) {
        b.y = bound;
        b.vy = -b.vy.abs() * bounce;
      } else if (b.y < -bound) {
        b.y = -bound;
        b.vy = b.vy.abs() * bounce;
      }
    }
    _trail.add(TrailFrame(
      bodies[0].x, bodies[0].y,
      bodies[1].x, bodies[1].y,
      bodies[2].x, bodies[2].y,
    ));
    if (_trail.length > maxTrail) {
      _trail.removeAt(0);
    }
  }
}
