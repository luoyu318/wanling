import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/mini_program_info.dart';

void main() {
  // List DTO 最小 fixture(GET /api/mini-programs 下发形状)
  final baseJson = <String, dynamic>{
    'id': 'mp1', 'appid': 'demo', 'owner_id': 'u1', 'name': '演示',
    'version': 3, 'status': 'published', 'sha256': 'x', 'size': 1,
  };

  group('MiniProgramInfo.iconUrlFor', () {
    final base = MiniProgramInfo(
      id: 'mp1', appid: 'demo', ownerId: 'u1', name: '演示',
      version: 3, status: 'published', sha256: 'x', size: 1,
      icon: '/api/mini-programs/mp1/icon?v=3',
    );
    test('有 icon 拼 baseUrl 与版本参数', () {
      expect(base.iconUrlFor('http://localhost:18008'),
          'http://localhost:18008/api/mini-programs/mp1/icon?v=3');
    });
    test('无 icon 返回空串(fallback 首字)', () {
      final bare = MiniProgramInfo(
        id: 'mp2', appid: 'bare', ownerId: 'u1', name: '裸',
        version: 1, status: 'private', sha256: 'x', size: 1,
      );
      expect(bare.iconUrlFor('http://localhost:18008'), '');
    });
  });

  group('MiniProgramInfo.collections', () {
    test('collections 解析与默认空', () {
      final withColls = MiniProgramInfo.fromJson({
        ...baseJson,
        'collections': [
          {'name': 'records', 'mode': 'private'},
          {'name': 'room', 'mode': 'shared_write'},
        ],
      });
      expect(withColls.collections.length, 2);
      expect(withColls.collections[0].name, 'records');
      expect(withColls.collections[1].mode, 'shared_write');
      final without = MiniProgramInfo.fromJson(baseJson);
      expect(without.collections, isEmpty);
    });
  });
}
