import 'package:app/providers/auth_provider.dart';
import 'package:app/services/api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MockApi extends Mock implements ApiService {}

void main() {
  late MockApi api;

  setUp(() {
    api = MockApi();
    // mocktail 未 stub 的非空 String getter 会返回 null 触发 type error。
    // auth_provider 的 service IPC 调用会读 api.baseUrl。
    when(() => api.baseUrl).thenReturn('http://test.local');
  });

  group('AuthNotifier.restoreSession', () {
    test('有 token + /me 成功 → user 非空、isAuthenticated=true', () async {
      SharedPreferences.setMockInitialValues({'token': 'fake-token'});
      when(() => api.getMe()).thenAnswer((_) async => {
        'id': 'u1', 'username': 'kira', 'avatar_url': null,
        'created_at': '2026-06-13T00:00:00Z',
      });

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
      ]);
      addTearDown(container.dispose);

      await container.read(authProvider.notifier).restoreSession();
      final state = container.read(authProvider);
      expect(state.isAuthenticated, true);
      expect(state.user, isNotNull);
      expect(state.user!.username, 'kira');
    });

    test('有 token + /me 返回 401 → 清 token、isAuthenticated=false', () async {
      SharedPreferences.setMockInitialValues({'token': 'expired-token'});
      when(() => api.getMe()).thenThrow(DioException(
        requestOptions: RequestOptions(path: '/api/users/me'),
        response: Response(
          requestOptions: RequestOptions(path: '/api/users/me'),
          statusCode: 401,
        ),
        type: DioExceptionType.badResponse,
      ));

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
      ]);
      addTearDown(container.dispose);

      await container.read(authProvider.notifier).restoreSession();
      final state = container.read(authProvider);
      expect(state.isAuthenticated, false);
      expect(state.user, isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), isNull);
    });

    test('有 token + 网络错误（非 401）→ 保留 token，state 未登录', () async {
      // 网络瞬断/5xx 不应清 token，让用户下次再试
      SharedPreferences.setMockInitialValues({'token': 'valid-but-server-down'});
      when(() => api.getMe()).thenThrow(DioException(
        requestOptions: RequestOptions(path: '/api/users/me'),
        type: DioExceptionType.connectionTimeout,
      ));

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
      ]);
      addTearDown(container.dispose);

      await container.read(authProvider.notifier).restoreSession();
      final state = container.read(authProvider);
      expect(state.isAuthenticated, false);
      expect(state.user, isNull);

      // token 应保留（非 401）
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), 'valid-but-server-down');
    });

    test('无 token → 不调用 /me，state 保持默认', () async {
      SharedPreferences.setMockInitialValues({}); // 空 prefs

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
      ]);
      addTearDown(container.dispose);

      await container.read(authProvider.notifier).restoreSession();
      final state = container.read(authProvider);
      expect(state.isAuthenticated, false);
      expect(state.user, isNull);
      verifyNever(() => api.getMe());
    });
  });
}
