import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/api_service.dart';
import '../helpers/mock_adapter.dart';

void main() {
  group('ApiService.getMe', () {
    test('GET /api/users/me 返回用户 map', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.dio.httpClientAdapter = CapturingMockAdapter(200, {
        'id': 'u1',
        'username': 'kira',
        'avatar_url': '',
        'created_at': '2026-06-13T00:00:00Z',
      });
      final me = await api.getMe();
      expect(me['id'], 'u1');
      expect(me['username'], 'kira');
    });
  });

  group('ApiService.updateAgent', () {
    test('PUT /api/agents/:id 携带 name body', () async {
      final api = ApiService(baseUrl: 'http://test');
      final adapter = CapturingMockAdapter(200, {'id': 'a1', 'name': 'NewName'});
      api.dio.httpClientAdapter = adapter;
      final res = await api.updateAgent('a1', name: 'NewName');
      expect(adapter.captured.path, '/api/agents/a1');
      expect(adapter.captured.data, {'name': 'NewName'});
      expect(res['name'], 'NewName');
    });
  });

  group('ApiService.withDio', () {
    test('使用注入的 dio 实例并继承 baseUrl', () {
      final dio = Dio(BaseOptions(baseUrl: 'http://provided'));
      final api = ApiService.withDio(dio);
      expect(api.dio, same(dio));
      expect(api.baseUrl, 'http://provided');
    });
  });

  group('changePassword', () {
    test('成功调用 PUT /api/users/me/password 并返回 ok', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.dio.httpClientAdapter = CapturingMockAdapter(200, {'ok': true});

      final result = await api.changePassword('newpw123');

      // 验证请求路径 + 方法 + body（captured 在 CapturingMockAdapter.fetch 里赋值）
      expect(api.dio.httpClientAdapter, isA<CapturingMockAdapter>());
      final adapter = api.dio.httpClientAdapter as CapturingMockAdapter;
      expect(adapter.captured.path, '/api/users/me/password');
      expect(adapter.captured.method, 'PUT');
      expect(adapter.captured.data, {'new_password': 'newpw123'});
      expect(result['ok'], true);
    });

    test('服务端返回 400 时抛出 DioException', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.dio.httpClientAdapter = MockHttpClientAdapter(
        400,
        {'error': '新密码至少 6 位'},
      );

      await expectLater(
        api.changePassword('123'),
        throwsA(
          isA<DioException>()
              .having((e) => e.response?.statusCode, 'statusCode', 400),
        ),
      );
    });
  });
}
