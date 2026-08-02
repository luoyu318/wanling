import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/widgets/chat/three_body_physics.dart';

void main() {
  group('ThreeBodyPhysics 初始化', () {
    test('构造后 bodies 长度为 3', () {
      final p = ThreeBodyPhysics();
      expect(p.bodies.length, 3);
    });

    test('三体初始 120° 等角分布', () {
      final p = ThreeBodyPhysics();
      final b = p.bodies;
      final a1 = atan2(b[0].y, b[0].x);
      final a2 = atan2(b[1].y, b[1].x);
      final a3 = atan2(b[2].y, b[2].x);
      double circDiff(double x, double y) {
        var d = ((x - y) * 180 / pi) % 360;
        if (d < 0) d += 360;
        if (d > 180) d = 360 - d;
        return d;
      }
      expect(circDiff(a2, a1), closeTo(120, 5));
      expect(circDiff(a3, a1), closeTo(120, 5));
      expect(circDiff(a3, a2), closeTo(120, 5));
    });
  });

  group('ThreeBodyPhysics step', () {
    test('step 后质心归零', () {
      final p = ThreeBodyPhysics();
      p.step();
      double cmx = 0, cmy = 0;
      for (final b in p.bodies) {
        cmx += b.x;
        cmy += b.y;
      }
      cmx /= 3;
      cmy /= 3;
      expect(cmx, closeTo(0, 0.001));
      expect(cmy, closeTo(0, 0.001));
    });

    test('1000 步后无 NaN', () {
      final p = ThreeBodyPhysics();
      for (int i = 0; i < 1000; i++) {
        p.step();
      }
      for (final b in p.bodies) {
        expect(b.x.isNaN, isFalse);
        expect(b.y.isNaN, isFalse);
        expect(b.vx.isNaN, isFalse);
        expect(b.vy.isNaN, isFalse);
      }
    });

    test('1000 步后未坍缩(最小间距 > 0.05)', () {
      final p = ThreeBodyPhysics();
      for (int i = 0; i < 1000; i++) {
        p.step();
      }
      final b = p.bodies;
      double minDist = double.maxFinite;
      for (int i = 0; i < 3; i++) {
        for (int j = i + 1; j < 3; j++) {
          final d = sqrt((b[i].x - b[j].x) * (b[i].x - b[j].x) +
              (b[i].y - b[j].y) * (b[i].y - b[j].y));
          if (d < minDist) minDist = d;
        }
      }
      expect(minDist, greaterThan(0.05));
    });

    test('1000 步后所有 body 在 bound 内', () {
      final p = ThreeBodyPhysics();
      for (int i = 0; i < 1000; i++) {
        p.step();
      }
      for (final b in p.bodies) {
        expect(b.x.abs(), lessThanOrEqualTo(1.2 + 0.01));
        expect(b.y.abs(), lessThanOrEqualTo(1.2 + 0.01));
      }
    });

    test('trail 长度不超过 maxTrail', () {
      final p = ThreeBodyPhysics();
      for (int i = 0; i < 50; i++) {
        p.step();
      }
      expect(p.trail.length, lessThanOrEqualTo(ThreeBodyPhysics.maxTrail));
    });

    test('trail 在 step 后增长', () {
      final p = ThreeBodyPhysics();
      expect(p.trail.length, 0);
      p.step();
      expect(p.trail.length, 1);
    });
  });
}
