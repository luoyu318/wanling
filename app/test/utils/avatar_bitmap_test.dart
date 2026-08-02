import 'package:app/utils/avatar_bitmap.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('loadAvatarBitmap', () {
    test('avatarUrl 为空时返回首字母色块 PNG bytes', () async {
      final bytes = await loadAvatarBitmap(
        agentId: 'agent-1',
        name: '白羽',
        avatarUrl: null,
        baseUrl: 'http://localhost:18008',
        httpHeaders: {},
      );
      // 返回非空 PNG(8 字节 PNG signature 开头)
      expect(bytes, isNotEmpty);
      // PNG 文件签名: 89 50 4E 47 0D 0A 1A 0A
      expect(bytes[0], 0x89);
      expect(bytes[1], 0x50); // 'P'
      expect(bytes[2], 0x4E); // 'N'
      expect(bytes[3], 0x47); // 'G'
    });

    test('同名 agent 多次调用色块颜色一致(hash 稳定)', () async {
      final b1 = await loadAvatarBitmap(
        agentId: 'a',
        name: '白羽',
        avatarUrl: null,
        baseUrl: '',
        httpHeaders: {},
      );
      final b2 = await loadAvatarBitmap(
        agentId: 'b',
        name: '白羽',
        avatarUrl: null,
        baseUrl: '',
        httpHeaders: {},
      );
      // 同名色块 bitmap 应完全一致(颜色相同,不画字母故内容一致)
      expect(b1, equals(b2));
    });

    test('avatarUrl 非空但下载失败(无效 host)时兜底色块,不抛异常', () async {
      final bytes = await loadAvatarBitmap(
        agentId: 'agent-2',
        name: '黑羽',
        avatarUrl: '/api/files/abc',
        baseUrl: 'http://invalid-host-that-does-not-exist:9999',
        httpHeaders: {'Authorization': 'Bearer x'},
      );
      expect(bytes, isNotEmpty);
      expect(bytes[0], 0x89); // PNG
    });
  });

  group('圆角判定 _isInsideRoundedRect', () {
    // 锁死圆角形状正确性(防回归:C1 bug 曾把圆角误判成方切角)
    test('48x48 r=9:角上像素透明,圆弧中段不透明,直边中点不透明', () {
      const w = 48, h = 48, r = 9;
      // 四个角的外角(应被切掉,透明)
      expect(isInsideRoundedRectForTest(0, 0, w, h, r), isFalse); // 左上外角
      expect(isInsideRoundedRectForTest(0, h - 1, w, h, r), isFalse); // 左下外角
      expect(isInsideRoundedRectForTest(w - 1, 0, w, h, r), isFalse); // 右上外角
      expect(isInsideRoundedRectForTest(w - 1, h - 1, w, h, r), isFalse); // 右下外角

      // 四条直边中点(应不透明,在中心十字区)
      expect(isInsideRoundedRectForTest(w ~/ 2, 0, w, h, r), isTrue); // 顶边中点
      expect(isInsideRoundedRectForTest(w ~/ 2, h - 1, w, h, r), isTrue); // 底边中点
      expect(isInsideRoundedRectForTest(0, h ~/ 2, w, h, r), isTrue); // 左边中点
      expect(isInsideRoundedRectForTest(w - 1, h ~/ 2, w, h, r), isTrue); // 右边中点

      // 正中心(恒不透明)
      expect(isInsideRoundedRectForTest(w ~/ 2, h ~/ 2, w, h, r), isTrue);

      // 圆心点(应不透明,距圆心 0)
      expect(isInsideRoundedRectForTest(r, r, w, h, r), isTrue); // 左上圆心
    });

    test('角方框内但距圆心<=r的点不透明(圆弧内)', () {
      const w = 48, h = 48, r = 9;
      // 左上角方框内,距圆心(r,r) 距离 = r 的点(圆弧上)
      // (r-1, r) 距离² = 1 <= r²,应不透明
      expect(isInsideRoundedRectForTest(r - 1, r, w, h, r), isTrue);
    });
  });
}

