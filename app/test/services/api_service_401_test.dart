import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/api_service.dart';
import '../helpers/mock_adapter.dart';

void main() {
  group('ApiService 401 Interceptor', () {
    test('401 响应触发 onUnauthorized 回调', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.dio.httpClientAdapter = MockHttpClientAdapter(401, {'error': 'unauthorized'});

      var triggered = false;
      api.setOnUnauthorized(() => triggered = true);

      try {
        await api.getMe();
        fail('应该抛出 401 异常');
      } on DioException catch (_) {
        // 期望异常
      }
      expect(triggered, true);
    });

    test('200 响应不触发 onUnauthorized 回调', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.dio.httpClientAdapter = MockHttpClientAdapter(200, {
        'id': 'u1',
        'username': 'kira',
        'avatar_url': '',
        'created_at': '2026-06-13T00:00:00Z',
      });

      var triggered = false;
      api.setOnUnauthorized(() => triggered = true);

      await api.getMe();
      expect(triggered, false);
    });

    test('500 响应不触发 onUnauthorized 回调', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.dio.httpClientAdapter = MockHttpClientAdapter(500, {'error': 'server'});

      var triggered = false;
      api.setOnUnauthorized(() => triggered = true);

      try {
        await api.getMe();
      } on DioException catch (_) {}
      expect(triggered, false);
    });

    test('setToken 设置 Authorization header', () async {
      final api = ApiService(baseUrl: 'http://test');
      // 使用 CapturingMockAdapter 直接捕获发出去的 RequestOptions，
      // 不再依赖额外拦截器。
      final adapter = CapturingMockAdapter(200, {
        'id': 'u1',
        'username': 'kira',
        'avatar_url': '',
        'created_at': '2026-06-13T00:00:00Z',
      });
      api.dio.httpClientAdapter = adapter;

      api.setToken('my-token');
      await api.getMe();

      expect(adapter.captured.headers['Authorization'], 'Bearer my-token');
    });

    test('withDio 构造也安装 Interceptor', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://test'));
      final api = ApiService.withDio(dio);
      api.dio.httpClientAdapter = MockHttpClientAdapter(401, {'error': 'unauthorized'});

      var triggered = false;
      api.setOnUnauthorized(() => triggered = true);

      try {
        await api.getMe();
      } on DioException catch (_) {}
      expect(triggered, true);
    });
  });
}
