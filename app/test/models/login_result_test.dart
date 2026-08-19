import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/login_result.dart';
import 'package:wanling_core/models/user.dart';

void main() {
  test('fromJson 解析 token + user', () {
    final result = LoginResult.fromJson({
      'token': 'jwt-xxx',
      'user': {
        'id': 'u1',
        'username': 'alice',
        'nickname': 'Alice',
        'avatar_url': '',
        'bio': '',
        'created_at': '2026-07-04T10:00:00Z',
      },
    });
    expect(result.token, 'jwt-xxx');
    expect(result.user, isA<User>());
    expect(result.user.id, 'u1');
    expect(result.user.username, 'alice');
  });

  test('缺少 token 抛异常（fail fast）', () {
    expect(
      () => LoginResult.fromJson({
        'user': {
          'id': 'u1',
          'username': 'alice',
          'created_at': '2026-07-04T10:00:00Z',
        },
      }),
      throwsA(isA<TypeError>()),
    );
  });

  test('缺少 user 抛异常（fail fast）', () {
    expect(
      () => LoginResult.fromJson({'token': 'jwt-xxx'}),
      throwsA(isA<TypeError>()),
    );
  });
}
