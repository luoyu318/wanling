import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/services/api_response.dart';

/// 按 (path, attempt) 分发的状态化 mock adapter,用于 refresh 重试场景测试。
///
/// - 第 1 次拉取 (`/api/users/me`) 返 401 → 触发 refresh
/// - refresh 调用 (`/api/auth/refresh`) 返 200 + 新 token pair
/// - 第 2 次拉取 (`/api/users/me`) 返 200 + 数据
///
/// 通过 attempt 计数区分第 1/2 次同路径请求。
class SequenceByPathAdapter implements HttpClientAdapter {
  SequenceByPathAdapter(this._handlers);

  /// 按 path → 该 path 的响应序列(按 attempt 顺序消费)。
  final Map<String, List<({int statusCode, dynamic data})>> _handlers;

  /// 记录每个 path 已被请求的次数(用于取下一个响应)。
  final Map<String, int> _attempt = {};

  /// 捕获所有发出去的 RequestOptions(供测试断言 refresh token / header 等)。
  final List<RequestOptions> captured = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    captured.add(options);
    final path = options.path;
    final attempt = _attempt[path] ?? 0;
    _attempt[path] = attempt + 1;
    final list = _handlers[path];
    if (list == null || attempt >= list.length) {
      throw StateError('SequenceByPathAdapter: path=$path attempt=$attempt 无对应 stub');
    }
    final next = list[attempt];
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(next.data)),
      next.statusCode,
      headers: const <String, List<String>>{
        'content-type': ['application/json'],
      },
    );
  }
}

void main() {
  group('ApiService 401 → refresh → retry', () {
    test('401 + refresh 成功 → 用新 token 重试原请求, 不触发 onUnauthorized', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.setRefreshToken('rt-old');
      final refreshedTokens = <(String, String, String)>[];
      api.setOnTokenRefreshed((access, refresh, role) {
        refreshedTokens.add((access, refresh, role));
      });
      var unauthorized = false;
      api.setOnUnauthorized(() => unauthorized = true);

      api.dio.httpClientAdapter = SequenceByPathAdapter({
        '/api/users/me': [
          (statusCode: 401, data: {'ok': false, 'error': {'code': 'unauthorized', 'message': '未授权'}}),
          (statusCode: 200, data: {
            'ok': true,
            'data': {'id': 'u1', 'username': 'kira', 'avatar_url': '', 'created_at': '2026-07-12T00:00:00Z'},
          }),
        ],
        '/api/auth/refresh': [
          (statusCode: 200, data: {'ok': true, 'data': {'token': 'access-new', 'refresh_token': 'rt-new'}}),
        ],
      });

      final user = await api.getMe();
      expect(user.id, 'u1');
      expect(user.username, 'kira');
      expect(unauthorized, false, reason: 'refresh 成功不应触发登出');
      expect(refreshedTokens.length, 1);
      expect(refreshedTokens.first.$1, 'access-new');
      expect(refreshedTokens.first.$2, 'rt-new');
      // refresh 响应无 role 字段 → 回调缺省 'user'
      expect(refreshedTokens.first.$3, 'user');

      // 验证 refresh 请求 body 携带原 refresh token
      final refreshReq = (api.dio.httpClientAdapter as SequenceByPathAdapter)
          .captured
          .firstWhere((r) => r.path == '/api/auth/refresh');
      expect(refreshReq.data, {'refresh_token': 'rt-old'});

      // 验证重试请求携带新 access token
      final retryReq = (api.dio.httpClientAdapter as SequenceByPathAdapter)
          .captured
          .where((r) => r.path == '/api/users/me')
          .toList();
      expect(retryReq.length, 2, reason: '应有 2 次 /me 请求(原 + 重试)');
      expect(retryReq[1].headers['Authorization'], 'Bearer access-new');
    });

    test('401 + 无 refresh_token → 直接登出, 不调 refresh endpoint', () async {
      final api = ApiService(baseUrl: 'http://test');
      // 不调 setRefreshToken → _refreshToken == null
      var unauthorized = false;
      api.setOnUnauthorized(() => unauthorized = true);

      final adapter = SequenceByPathAdapter({
        '/api/users/me': [
          (statusCode: 401, data: {'ok': false, 'error': {'code': 'unauthorized', 'message': '未授权'}}),
        ],
      });
      api.dio.httpClientAdapter = adapter;

      try {
        await api.getMe();
        fail('应抛 DioException');
      } on DioException catch (e) {
        expect((e.error as ApiException).code, 'unauthorized');
      }
      expect(unauthorized, true);
      // 不应发任何 refresh 请求
      expect(
        adapter.captured.where((r) => r.path == '/api/auth/refresh').length,
        0,
        reason: '无 refresh_token 时不应调 refresh endpoint',
      );
    });

    test('401 + refresh 失败(refresh endpoint 返 401) → 触发 onUnauthorized + 透传错误', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.setRefreshToken('rt-expired');
      var unauthorized = false;
      api.setOnUnauthorized(() => unauthorized = true);

      api.dio.httpClientAdapter = SequenceByPathAdapter({
        '/api/users/me': [
          (statusCode: 401, data: {'ok': false, 'error': {'code': 'unauthorized', 'message': '未授权'}}),
        ],
        '/api/auth/refresh': [
          (statusCode: 401, data: {'ok': false, 'error': {'code': 'invalid_refresh', 'message': 'refresh token 无效'}}),
        ],
      });

      try {
        await api.getMe();
        fail('应抛 DioException');
      } on DioException catch (e) {
        // 透传原始 401(unauthorized) 而非 refresh 的 401(invalid_refresh)
        expect((e.error as ApiException).code, 'unauthorized');
      }
      expect(unauthorized, true);
    });

    test('401 + refresh 成功 + 重试仍 401 → 单次重试后登出(不无限循环)', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.setRefreshToken('rt-old');
      var unauthorized = false;
      api.setOnUnauthorized(() => unauthorized = true);

      final adapter = SequenceByPathAdapter({
        // /me 持续返 401(refresh 后服务端仍拒绝,如新 token 也失效场景)
        '/api/users/me': [
          (statusCode: 401, data: {'ok': false, 'error': {'code': 'unauthorized', 'message': '未授权'}}),
          (statusCode: 401, data: {'ok': false, 'error': {'code': 'unauthorized', 'message': '未授权'}}),
          (statusCode: 401, data: {'ok': false, 'error': {'code': 'unauthorized', 'message': '未授权'}}),
        ],
        '/api/auth/refresh': [
          (statusCode: 200, data: {'ok': true, 'data': {'token': 'access-new', 'refresh_token': 'rt-new'}}),
        ],
      });
      api.dio.httpClientAdapter = adapter;

      try {
        await api.getMe();
        fail('应抛 DioException');
      } on DioException catch (_) {}

      expect(unauthorized, true);
      // 应该只发 2 次 /me 请求(原 + 1 次重试),不会无限循环
      final meRequests = adapter.captured.where((r) => r.path == '/api/users/me').length;
      expect(meRequests, 2, reason: '单次重试后必须停(retried 标记防无限循环)');
      // refresh 应该只调 1 次
      final refreshRequests = adapter.captured.where((r) => r.path == '/api/auth/refresh').length;
      expect(refreshRequests, 1);
    });

    test('并发 401 去重:同时多个请求收到 401,只发一次 refresh', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.setRefreshToken('rt-old');

      final adapter = SequenceByPathAdapter({
        // 两个不同接口都返 401(第 1 次),重试时都返 200
        '/api/users/me': [
          (statusCode: 401, data: {'ok': false, 'error': {'code': 'unauthorized', 'message': '未授权'}}),
          (statusCode: 200, data: {
            'ok': true,
            'data': {'id': 'u1', 'username': 'kira', 'avatar_url': '', 'created_at': '2026-07-12T00:00:00Z'},
          }),
        ],
        '/api/agents': [
          (statusCode: 401, data: {'ok': false, 'error': {'code': 'unauthorized', 'message': '未授权'}}),
          (statusCode: 200, data: {'ok': true, 'data': <Map<String, dynamic>>[]}),
        ],
        '/api/auth/refresh': [
          (statusCode: 200, data: {'ok': true, 'data': {'token': 'access-new', 'refresh_token': 'rt-new'}}),
        ],
      });
      api.dio.httpClientAdapter = adapter;

      // 并发发起两个请求(都会拿到 401)
      final meFuture = api.getMe();
      final agentsFuture = api.getAgents();
      final user = await meFuture;
      final agents = await agentsFuture;

      expect(user.id, 'u1');
      expect(agents, <Agent>[]);

      // refresh 应该只调一次(并发去重)
      final refreshCount = adapter.captured.where((r) => r.path == '/api/auth/refresh').length;
      expect(refreshCount, 1, reason: '并发 401 必须去重,只发一次 refresh');
    });
  });

  group('ApiService logout', () {
    test('logout 调 POST /api/auth/logout + body 携带当前 refresh_token', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.setRefreshToken('rt-current');

      final adapter = SequenceByPathAdapter({
        '/api/auth/logout': [
          (statusCode: 200, data: {'ok': true, 'data': null}),
        ],
      });
      api.dio.httpClientAdapter = adapter;

      await api.logout();

      final logoutReq = adapter.captured.singleWhere((r) => r.path == '/api/auth/logout');
      expect(logoutReq.data, {'refresh_token': 'rt-current'});
    });

    test('logout 失败(server 5xx) 不抛异常,本地清理仍可继续', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.setRefreshToken('rt-current');

      api.dio.httpClientAdapter = SequenceByPathAdapter({
        '/api/auth/logout': [
          (statusCode: 500, data: {'ok': false, 'error': {'code': 'internal_error', 'message': 'server'}}),
        ],
      });

      // 不应抛异常(吞掉错误,登出失败不阻塞本地清理)
      await api.logout();
    });

    test('logout 无 refresh_token 时 body 不含 refresh_token 字段', () async {
      final api = ApiService(baseUrl: 'http://test');
      // 不调 setRefreshToken

      final adapter = SequenceByPathAdapter({
        '/api/auth/logout': [
          (statusCode: 200, data: {'ok': true, 'data': null}),
        ],
      });
      api.dio.httpClientAdapter = adapter;

      await api.logout();

      final logoutReq = adapter.captured.singleWhere((r) => r.path == '/api/auth/logout');
      expect(logoutReq.data, isEmpty);
    });
  });
}
