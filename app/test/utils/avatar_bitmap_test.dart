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
}
