import 'dart:convert';

import 'package:app/models/login_result.dart';
import 'package:app/models/register_result.dart';
import 'package:app/models/user.dart';
import 'package:app/providers/auth_provider.dart';
import 'package:app/services/api_service.dart';
import 'package:app/services/secure_storage.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
    // logout 返回 Future<void>,mocktail 未 stub 时返 null 触发 type error。
    when(() => api.logout()).thenAnswer((_) async {});
    // flutter_secure_storage 是平台插件,flutter test 环境无原生通道,
    // 用 setMockInitialValues 注入内存实现。
    FlutterSecureStorage.setMockInitialValues({});
  });

  group('AuthNotifier.restoreSession', () {
    test('有 token + /me 成功 → user 非空、isAuthenticated=true', () async {
      SharedPreferences.setMockInitialValues({'token': 'fake-token'});
      when(() => api.getMe()).thenAnswer((_) async => User(
        id: 'u1',
        username: 'kira',
        avatarUrl: null,
        createdAt: DateTime.parse('2026-06-13T00:00:00Z'),
      ));

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

  group('F5: cached_user 离线兜底', () {
    test('login 成功后 prefs 应有 cached_user', () async {
      SharedPreferences.setMockInitialValues({});
      when(() => api.login('alice', 'pwd')).thenAnswer((_) async => LoginResult(
        token: 'tok-1',
        refreshToken: 'rt-1',
        user: User(
          id: 'u1',
          username: 'alice',
          nickname: 'Alice',
          createdAt: DateTime.utc(2026, 7, 5),
        ),
      ));

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
      ]);
      addTearDown(container.dispose);

      await container.read(authProvider.notifier).login('alice', 'pwd');

      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('cached_user');
      expect(cached, isNotNull);
      final decoded = jsonDecode(cached!) as Map<String, dynamic>;
      expect(decoded['id'], 'u1');
      expect(decoded['username'], 'alice');
    });

    test('restoreSession 网络错 + 有 cached_user → state.user=cachedUser, token 保留', () async {
      SharedPreferences.setMockInitialValues({
        'token': 'tok-old',
        'cached_user': jsonEncode({
          'id': 'u1',
          'username': 'alice',
          'nickname': 'Alice',
          'bio': null,
          'avatar_url': null,
          'created_at': DateTime.utc(2026, 7, 1).toIso8601String(),
        }),
      });
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
      expect(state.user, isNotNull);
      expect(state.user!.id, 'u1');
      expect(state.token, 'tok-old');
      expect(state.isAuthenticated, isTrue);
    });

    test('restoreSession 401 → 清 token + 清 cached_user', () async {
      SharedPreferences.setMockInitialValues({
        'token': 'tok-old',
        'cached_user': '{"id":"u1","username":"alice"}',
      });
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
      expect(state.user, isNull);
      expect(state.token, isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), isNull);
      expect(prefs.getString('cached_user'), isNull);
    });

    test('restoreSession 401 应保留 aes_key(saved_logins 加密密钥)', () async {
      // 防回归:401 清 aes_key 会让下次启动 saved_logins 密文无法解密,
      // 被 load() catch 后账号配置被静默清空。
      SharedPreferences.setMockInitialValues({
        'token': 'tok-old',
      });
      await TokenVault.saveAesKey('aes-base64');
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

      expect(await TokenVault.getAesKey(), 'aes-base64',
          reason: 'aes_key 是跨账号的 saved_logins 加密密钥,401 应保留');
    });

    test('restoreSession 网络错 + 无 cached_user → state.token=null, 跳登录', () async {
      SharedPreferences.setMockInitialValues({
        'token': 'tok-old',
        // 无 cached_user
      });
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
      expect(state.user, isNull);
      expect(state.token, isNull);  // 无 cached_user 时 token 也清
    });

    test('register 成功后 prefs 应有 cached_user', () async {
      SharedPreferences.setMockInitialValues({});
      when(() => api.register('bob', 'pwd')).thenAnswer((_) async => RegisterResult(
        token: 'tok-reg',
        refreshToken: 'rt-reg',
      ));
      when(() => api.getMe()).thenAnswer((_) async => User(
        id: 'u2',
        username: 'bob',
        nickname: 'Bob',
        createdAt: DateTime.utc(2026, 7, 5),
      ));

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
      ]);
      addTearDown(container.dispose);

      await container.read(authProvider.notifier).register('bob', 'pwd');

      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('cached_user');
      expect(cached, isNotNull);
      final decoded = jsonDecode(cached!) as Map<String, dynamic>;
      expect(decoded['id'], 'u2');
      expect(decoded['username'], 'bob');
    });

    test('restoreSession /me 成功 → 刷新 cached_user(防止旧缓存陈旧)', () async {
      SharedPreferences.setMockInitialValues({
        'token': 'tok-old',
        'cached_user': jsonEncode({
          'id': 'u1',
          'username': 'oldname',
          'nickname': 'OldNick',
          'bio': null,
          'avatar_url': null,
          'created_at': DateTime.utc(2026, 7, 1).toIso8601String(),
        }),
      });
      when(() => api.getMe()).thenAnswer((_) async => User(
        id: 'u1',
        username: 'newname',
        nickname: 'NewNick',
        createdAt: DateTime.utc(2026, 7, 1),
      ));

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
      ]);
      addTearDown(container.dispose);

      await container.read(authProvider.notifier).restoreSession();

      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString('cached_user');
      expect(cached, isNotNull);
      final decoded = jsonDecode(cached!) as Map<String, dynamic>;
      expect(decoded['username'], 'newname');  // 被刷新为新值
      expect(decoded['nickname'], 'NewNick');
    });

    test('restoreSession 网络错 + cached_user JSON 损坏 → 降级为无缓存路径', () async {
      SharedPreferences.setMockInitialValues({
        'token': 'tok-old',
        'cached_user': '<not a valid json>',  // 损坏的 JSON
      });
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
      expect(state.user, isNull);  // JSON 解析失败,cachedUser=null
      expect(state.token, isNull);  // cachedUser=null → token 也清
    });
  });

  group('logout / 切换账号 user_id 一致性', () {
    // bg-service isolate 用 prefs.user_id 判断「自己发的消息不弹通知」。
    // logout 不清 user_id → 多账号切换场景下残留旧账号 ID,自己 echo 被误判为对方消息。
    test('logout 应清 user_id(对齐 token + cached_user)', () async {
      SharedPreferences.setMockInitialValues({
        'token': 'tok-A',
        'user_id': 'user-A',
        'cached_user': '{"id":"user-A","username":"alice"}',
      });
      // login 后 state.isAuthenticated=true 才能调 logout
      when(() => api.getMe()).thenAnswer((_) async => User(
        id: 'user-A',
        username: 'alice',
        createdAt: DateTime.utc(2026, 7, 1),
      ));

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
      ]);
      addTearDown(container.dispose);

      await container.read(authProvider.notifier).restoreSession();
      await container.read(authProvider.notifier).logout();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('token'), isNull);
      expect(prefs.getString('cached_user'), isNull);
      expect(prefs.getString('user_id'), isNull,
          reason: 'logout 必须清 user_id,否则 bg-service 残留旧账号 ID '
              '会导致自己发的消息 echo 被误判为对方消息弹通知');
    });

    test('logout 应保留 aes_key(saved_logins 加密密钥)', () async {
      // 防回归:登出清 aes_key 会让下次启动 saved_logins 密文无法解密,
      // 被 load() catch 后导致账号配置被静默清空。
      SharedPreferences.setMockInitialValues({
        'token': 'tok-A',
        'user_id': 'user-A',
        'cached_user': '{"id":"user-A","username":"alice"}',
      });
      await TokenVault.saveAesKey('aes-base64');
      when(() => api.getMe()).thenAnswer((_) async => User(
        id: 'user-A',
        username: 'alice',
        createdAt: DateTime.utc(2026, 7, 1),
      ));

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
      ]);
      addTearDown(container.dispose);

      await container.read(authProvider.notifier).restoreSession();
      await container.read(authProvider.notifier).logout();

      expect(await TokenVault.getAesKey(), 'aes-base64',
          reason: 'aes_key 是跨账号的 saved_logins 加密密钥,登出应保留');
    });

    test('restoreSession 网络错兜底应同步刷 user_id(从 cached_user 解析)',
        () async {
      // 场景:用户上次登录账号 B,prefs.user_id=B,但 cached_user 是 A
      // (历史残留)。本次启动网络错,走 cached_user 兜底。
      // 期望:user_id 被刷新为 cached_user.id(A),保持跟 state.user 一致。
      SharedPreferences.setMockInitialValues({
        'token': 'tok-old',
        'user_id': 'stale-B-id',
        'cached_user': jsonEncode({
          'id': 'real-A-id',
          'username': 'alice',
          'nickname': 'Alice',
          'bio': null,
          'avatar_url': null,
          'created_at': DateTime.utc(2026, 7, 1).toIso8601String(),
        }),
      });
      when(() => api.getMe()).thenThrow(DioException(
        requestOptions: RequestOptions(path: '/api/users/me'),
        type: DioExceptionType.connectionTimeout,
      ));

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
      ]);
      addTearDown(container.dispose);

      await container.read(authProvider.notifier).restoreSession();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('user_id'), 'real-A-id',
          reason: '网络错兜底分支用 cached_user 设 state.user,应同步写 user_id '
              '保证 bg-service 的 senderId==myUserId 判断在当前账号生效');
    });

    test('login 后 prefs.user_id 与 cached_user.id 一致', () async {
      SharedPreferences.setMockInitialValues({
        'user_id': 'old-user-id', // 残留
      });
      when(() => api.login('alice', 'pwd')).thenAnswer((_) async => LoginResult(
        token: 'tok-new',
        refreshToken: 'rt-new',
        user: User(
          id: 'new-alice',
          username: 'alice',
          createdAt: DateTime.utc(2026, 7, 5),
        ),
      ));

      final container = ProviderContainer(overrides: [
        apiProvider.overrideWithValue(api),
      ]);
      addTearDown(container.dispose);

      await container.read(authProvider.notifier).login('alice', 'pwd');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('user_id'), 'new-alice');
      final cached =
          jsonDecode(prefs.getString('cached_user')!) as Map<String, dynamic>;
      expect(cached['id'], 'new-alice');
    });
  });
}
