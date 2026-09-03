import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/login_result.dart';
import 'package:wanling_core/models/user.dart';

void main() {
  test('LoginResult 解析顶层 role,缺省 user', () {
    final r = LoginResult.fromJson({
      'token': 't',
      'refresh_token': 'r',
      'role': 'admin',
      'user': {
        'id': 'u1', 'username': 'kira', 'role': 'admin',
        'created_at': '2026-06-13T00:00:00Z',
      },
    });
    expect(r.role, 'admin');
    expect(r.user.role, 'admin');
  });

  test('旧 server 无 role 字段 → 缺省 user', () {
    final r = LoginResult.fromJson({
      'token': 't',
      'user': {'id': 'u1', 'username': 'kira', 'created_at': '2026-06-13T00:00:00Z'},
    });
    expect(r.role, 'user');
    expect(r.user.role, 'user');
  });

  test('User.role 缺省 user,toJson 携带', () {
    final u = User.fromJson({'id': 'u1', 'username': 'kira', 'created_at': '2026-06-13T00:00:00Z'});
    expect(u.role, 'user');
    expect(u.toJson()['role'], 'user');
  });
}
