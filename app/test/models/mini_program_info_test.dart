import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/mini_program_info.dart';

void main() {
  test('fromJson 完整字段', () {
    final m = MiniProgramInfo.fromJson(const {
      'id': 'id-1',
      'appid': 'hello-demo',
      'owner_id': 'u1',
      'name': 'Hello',
      'version': 3,
      'entry': 'index.html',
      'icon': 'icon.png',
      'permissions': ['wanling.api', 'wanling.chat.share'],
      'status': 'published',
      'sha256': 'abc',
      'size': 1024,
    });
    expect(m.appid, 'hello-demo');
    expect(m.version, 3);
    expect(m.entry, 'index.html');
    expect(m.permissions, ['wanling.api', 'wanling.chat.share']);
    expect(m.status, 'published');
    expect(m.size, 1024);
  });

  test('fromJson 缺省兜底(entry 默认 index.html,icon 空)', () {
    final m = MiniProgramInfo.fromJson(const {
      'id': 'id-1',
      'appid': 'hello-demo',
      'owner_id': 'u1',
      'name': 'Hello',
      'version': 1,
      'status': 'private',
      'sha256': 'abc',
      'size': 1,
    });
    expect(m.entry, 'index.html');
    expect(m.icon, '');
    expect(m.permissions, isEmpty);
  });
}
