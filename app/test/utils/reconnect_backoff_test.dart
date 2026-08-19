import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/utils/reconnect_backoff.dart';

void main() {
  group('ReconnectBackoff', () {
    test('首次 next() 返回值在 [1s, 1.5s] 区间（base ± 25% jitter）', () {
      final b = ReconnectBackoff();
      final d = b.next();
      expect(d.inMilliseconds, greaterThanOrEqualTo(750));   // 1000 * 0.75
      expect(d.inMilliseconds, lessThanOrEqualTo(1500));     // 1000 * 1.25
    });

    test('连续 next() 多次后仍不超过 30s 上限（jitter 上界 37.5s，clamp 在 30s）', () {
      final b = ReconnectBackoff();
      Duration maxSeen = Duration.zero;
      for (var i = 0; i < 30; i++) {
        final d = b.next();
        if (d > maxSeen) maxSeen = d;
      }
      expect(maxSeen.inMilliseconds, lessThanOrEqualTo(30000));
    });

    test('reset() 后下次 next() 回到 [1s, 1.5s] 区间', () {
      final b = ReconnectBackoff();
      for (var i = 0; i < 10; i++) {
        b.next();
      }
      b.reset();
      final d = b.next();
      expect(d.inMilliseconds, greaterThanOrEqualTo(750));
      expect(d.inMilliseconds, lessThanOrEqualTo(1500));
    });

    test('连续 next() 30 次不抛异常（防 overflow 验证）', () {
      final b = ReconnectBackoff();
      expect(() {
        for (var i = 0; i < 30; i++) {
          b.next();
        }
      }, returnsNormally);
    });

    test('首次 next() 多次采样能产生 < 1000ms 的值（验证 jitter 下界对称）', () {
      // 跑 200 次，至少有一个 < 1000ms 才说明 jitter 下界没被锁到 base
      var hasBelowBase = false;
      for (var i = 0; i < 200; i++) {
        final b = ReconnectBackoff();
        if (b.next().inMilliseconds < 1000) {
          hasBelowBase = true;
          break;
        }
      }
      expect(hasBelowBase, isTrue,
          reason: 'jitter ±25% 应允许首次 next() 落到 [750, 1000) 区间');
    });
  });
}
