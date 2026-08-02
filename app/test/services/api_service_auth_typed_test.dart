import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/login_result.dart';
import 'package:app/models/register_result.dart';
import 'package:app/models/user.dart';
import 'package:app/services/api_service.dart';

import '../helpers/mock_adapter.dart';

/// 构造 ApiService，MockAdapter 用 envelope 包装 data，
/// 验证拦截器剥 envelope 后业务层拿到 data 部分。
ApiService _api(dynamic data) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'));
  final api = ApiService.withDio(dio);
  dio.httpClientAdapter = CapturingMockAdapter(
    200,
    {'ok': true, 'data': data},
  );
  return api;
}

void main() {
  test('login 返 LoginResult', () async {
    final api = _api({
      'token': 'jwt-xxx',
      'user': {
        'id': 'u1',
        'username': 'alice',
        'created_at': '2026-07-04T10:00:00Z',
      },
    });
    final result = await api.login('alice', 'pw');
    expect(result, isA<LoginResult>());
    expect(result.token, 'jwt-xxx');
    expect(result.user.id, 'u1');
  });

  test('register 返 RegisterResult', () async {
    final api = _api({'token': 'jwt-yyy'});
    final result = await api.register('bob', 'pw');
    expect(result, isA<RegisterResult>());
    expect(result.token, 'jwt-yyy');
  });

  test('getMe 返 User', () async {
    final api = _api({
      'id': 'u1',
      'username': 'alice',
      'created_at': '2026-07-04T10:00:00Z',
    });
    final user = await api.getMe();
    expect(user, isA<User>());
    expect(user.id, 'u1');
  });

  test('changePassword 返新 token pair', () async {
    final api = _api({
      'token': 'access-new',
      'refresh_token': 'rt-new',
    });
    final result = await api.changePassword('newpw');
    expect(result.token, 'access-new');
    expect(result.refreshToken, 'rt-new');
  });

  test('updateMe 返 User', () async {
    final api = _api({
      'id': 'u1',
      'username': 'alice',
      'nickname': 'Alice',
      'created_at': '2026-07-04T10:00:00Z',
    });
    final user = await api.updateMe(nickname: 'Alice');
    expect(user, isA<User>());
    expect(user.nickname, 'Alice');
  });
}
