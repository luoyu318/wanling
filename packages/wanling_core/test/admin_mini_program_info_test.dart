import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/admin_mini_program_info.dart';

void main() {
  group('AdminMiniProgramInfo.fromJson', () {
    test('全字段解析', () {
      final info = AdminMiniProgramInfo.fromJson(const {
        'id': 'mp1',
        'appid': 'demo',
        'owner_username': 'alice',
        'name': '演示',
        'version': 3,
        'icon': '/api/admin/mini-programs/mp1/icon?v=3',
        'permissions': ['fs.read', 'net.fetch'],
        'status': 'published',
        'size': 1024,
      });
      expect(info.id, 'mp1');
      expect(info.appid, 'demo');
      expect(info.ownerUsername, 'alice');
      expect(info.name, '演示');
      expect(info.version, 3);
      expect(info.icon, '/api/admin/mini-programs/mp1/icon?v=3');
      expect(info.permissions, ['fs.read', 'net.fetch']);
      expect(info.status, 'published');
      expect(info.size, 1024);
    });

    test('缺省字段走 fallback', () {
      final info = AdminMiniProgramInfo.fromJson(const {
        'id': 'mp2',
        'appid': 'bare',
      });
      expect(info.id, 'mp2');
      expect(info.appid, 'bare');
      expect(info.ownerUsername, '');
      expect(info.name, '');
      expect(info.version, 0);
      expect(info.icon, '');
      expect(info.permissions, isEmpty);
      expect(info.status, 'private');
      expect(info.size, 0);
    });
  });
}
