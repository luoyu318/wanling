import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/rpc_method.dart';
import 'package:wanling_core/models/user.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:wanling_core/services/api_response.dart';
import '../helpers/mock_adapter.dart';

void main() {
  group('ApiService.getMe', () {
    test('GET /api/users/me 返回 User', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.dio.httpClientAdapter = CapturingMockAdapter(200, {
        'ok': true,
        'data': {
          'id': 'u1',
          'username': 'kira',
          'avatar_url': '',
          'created_at': '2026-06-13T00:00:00Z',
        },
      });
      final me = await api.getMe();
      expect(me, isA<User>());
      expect(me.id, 'u1');
      expect(me.username, 'kira');
    });
  });

  group('ApiService.updateAgent', () {
    test('PUT /api/agents/:id 携带 name body 并返 Agent', () async {
      final api = ApiService(baseUrl: 'http://test');
      final adapter = CapturingMockAdapter(200, {
        'ok': true,
        'data': {
          'id': 'a1',
          'name': 'NewName',
          'status': 'active',
        },
      });
      api.dio.httpClientAdapter = adapter;
      final res = await api.updateAgent('a1', name: 'NewName');
      expect(adapter.captured.path, '/api/agents/a1');
      expect(adapter.captured.data, {'name': 'NewName'});
      expect(res, isA<Agent>());
      expect(res.name, 'NewName');
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
    test('成功调用 PUT /api/users/me/password 返新 token pair', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.dio.httpClientAdapter = CapturingMockAdapter(
        200,
        {
          'ok': true,
          'data': {'token': 'access-new', 'refresh_token': 'rt-new'},
        },
      );

      final result = await api.changePassword('newpw123');

      // 验证请求路径 + 方法 + body（captured 在 CapturingMockAdapter.fetch 里赋值）
      expect(api.dio.httpClientAdapter, isA<CapturingMockAdapter>());
      final adapter = api.dio.httpClientAdapter as CapturingMockAdapter;
      expect(adapter.captured.path, '/api/users/me/password');
      expect(adapter.captured.method, 'PUT');
      expect(adapter.captured.data, {'new_password': 'newpw123'});
      // 验证返回的 token pair
      expect(result.token, 'access-new');
      expect(result.refreshToken, 'rt-new');
    });

    test('服务端返回 400 envelope error 抛出 ApiException', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.dio.httpClientAdapter = MockHttpClientAdapter(
        400,
        {
          'ok': false,
          'error': {'code': 'invalid_password', 'message': '新密码至少 6 位'},
        },
      );

      await expectLater(
        api.changePassword('123'),
        throwsA(
          isA<DioException>()
              .having((e) => e.error, 'error', isA<ApiException>()
                  .having((ae) => ae.code, 'code', 'invalid_password')
                  .having((ae) => ae.message, 'message', '新密码至少 6 位')
                  .having((ae) => ae.statusCode, 'statusCode', 400)),
        ),
      );
    });
  });

  // RPC 端点 POST /api/agents/:id/rpc 走 JSON-RPC 2.0 envelope(非 wanling REST envelope):
  // 成功: {"result": <T>}(HTTP 200),失败: {"error": {"code": <int>, "message": "..."}}(503/504)。
  // 错误码 -32001/-32002/-32003 是 int,与 REST envelope 的 String code 不同,用 RpcException 承载。
  group('ApiService.rpc', () {
    test('成功:200 + {result: {...}} 返回 result map', () async {
      final api = ApiService(baseUrl: 'http://test');
      final adapter = CapturingMockAdapter(200, {
        'result': {'echo': 'hi'},
      });
      api.dio.httpClientAdapter = adapter;

      final result = await api.rpc('abc', 'echo', {'text': 'hi'},
          timeoutMs: 5000);

      expect(adapter.captured.path, '/api/agents/abc/rpc');
      expect(adapter.captured.method, 'POST');
      expect(adapter.captured.data, {
        'method': 'echo',
        'params': {'text': 'hi'},
        'timeout_ms': 5000,
      });
      expect(result, {'echo': 'hi'});
    });

    test('不传 timeoutMs 时 body 不含 timeout_ms 字段', () async {
      final api = ApiService(baseUrl: 'http://test');
      final adapter = CapturingMockAdapter(200, {
        'result': {'ok': 1},
      });
      api.dio.httpClientAdapter = adapter;

      await api.rpc('abc', 'echo', {});

      expect(adapter.captured.data, {
        'method': 'echo',
        'params': {},
      });
    });

    test('503 plugin_offline 抛 RpcException code=-32001', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.dio.httpClientAdapter = MockHttpClientAdapter(503, {
        'error': {'code': -32001, 'message': 'plugin offline'},
      });

      await expectLater(
        api.rpc('abc', 'echo', {}),
        throwsA(isA<RpcException>()
            .having((e) => e.code, 'code', -32001)
            .having((e) => e.message, 'message', 'plugin offline')
            .having((e) => e.statusCode, 'statusCode', 503)),
      );
    });

    test('504 plugin_timeout 抛 RpcException code=-32002', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.dio.httpClientAdapter = MockHttpClientAdapter(504, {
        'error': {'code': -32002, 'message': 'plugin timeout'},
      });

      await expectLater(
        api.rpc('abc', 'echo', {}),
        throwsA(isA<RpcException>()
            .having((e) => e.code, 'code', -32002)
            .having((e) => e.statusCode, 'statusCode', 504)),
      );
    });

    test('503 plugin_disconnected 抛 RpcException code=-32003', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.dio.httpClientAdapter = MockHttpClientAdapter(503, {
        'error': {'code': -32003, 'message': 'plugin disconnected'},
      });

      await expectLater(
        api.rpc('abc', 'echo', {}),
        throwsA(isA<RpcException>()
            .having((e) => e.code, 'code', -32003)
            .having((e) => e.statusCode, 'statusCode', 503)),
      );
    });

    test('error body 缺失字段时给默认值(code=0, message=rpc failed)', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.dio.httpClientAdapter = MockHttpClientAdapter(503, {
        'error': {},
      });

      await expectLater(
        api.rpc('abc', 'echo', {}),
        throwsA(isA<RpcException>()
            .having((e) => e.code, 'code', 0)
            .having((e) => e.message, 'message', 'rpc failed')),
      );
    });

    test('非 RPC 错误(如 500)走 _wrapError 透传 DioException', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.dio.httpClientAdapter = MockHttpClientAdapter(500, {
        'ok': false,
        'error': {'code': 'internal_error', 'message': '服务器错误'},
      });

      await expectLater(
        api.rpc('abc', 'echo', {}),
        throwsA(isA<DioException>()),
      );
    });
  });

  // GET /api/agents/:id/rpc-methods 拉 plugin capability 清单(对称 getAgentModels /
  // getAgentSlashCatalog)。envelope 拦截器剥 {ok:true, data:{agent_id, methods, updated_at}}
  // 后 res.data 是内层 map,业务层读 methods 数组。空清单是合法态(plugin 未上报)。
  group('ApiService.getRpcMethods', () {
    test('成功:200 + methods 数组返 RpcMethod 列表', () async {
      final api = ApiService(baseUrl: 'http://test');
      final adapter = CapturingMockAdapter(200, {
        'ok': true,
        'data': {
          'agent_id': 'agent-1',
          'methods': [
            {'name': 'echo', 'timeout_hint_ms': 3000},
            {'name': 'file.read', 'timeout_hint_ms': 5000},
          ],
          'updated_at': '2026-07-19T12:00:00.000Z',
        },
      });
      api.dio.httpClientAdapter = adapter;

      final methods = await api.getRpcMethods('agent-1');

      expect(adapter.captured.path, '/api/agents/agent-1/rpc-methods');
      expect(adapter.captured.method, 'GET');
      expect(methods, hasLength(2));
      expect(methods[0], isA<RpcMethod>());
      expect(methods[0].name, 'echo');
      expect(methods[0].timeoutHintMs, 3000);
      expect(methods[1].name, 'file.read');
      expect(methods[1].timeoutHintMs, 5000);
    });

    test('未上报(methods 空数组, updated_at=null)返空清单不抛错', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.dio.httpClientAdapter = CapturingMockAdapter(200, {
        'ok': true,
        'data': {
          'agent_id': 'agent-1',
          'methods': [],
          'updated_at': null,
        },
      });

      final methods = await api.getRpcMethods('agent-1');

      expect(methods, isEmpty);
    });

    test('403 forbidden 抛 DioException(ApiException code=forbidden)', () async {
      final api = ApiService(baseUrl: 'http://test');
      api.dio.httpClientAdapter = MockHttpClientAdapter(403, {
        'ok': false,
        'error': {'code': 'forbidden', 'message': '无权操作'},
      });

      await expectLater(
        api.getRpcMethods('agent-1'),
        throwsA(isA<DioException>().having(
          (e) => e.error,
          'error',
          isA<ApiException>()
              .having((ae) => ae.code, 'code', 'forbidden')
              .having((ae) => ae.statusCode, 'statusCode', 403),
        )),
      );
    });
  });
}
