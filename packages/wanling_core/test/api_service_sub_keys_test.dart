// ApiService 子密钥/配对扩展的契约测试:验证请求 path/body 与 envelope 解析。
// 用内联捕获 adapter 走真实 dio + 拦截器链路,与线上行为一致。
import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/agent_sub_key_info.dart';
import 'package:wanling_core/models/pairing.dart';
import 'package:wanling_core/services/api_service.dart';

/// 记录请求并按序返回固定响应的测试 adapter。
class _CapturingAdapter implements HttpClientAdapter {
  _CapturingAdapter(this.statusCode, this.data);

  final int statusCode;
  final dynamic data;
  final List<RequestRecord> requests = [];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(RequestRecord(
      method: options.method,
      path: options.path,
      body: options.data,
    ));
    return ResponseBody.fromBytes(
      utf8.encode(jsonEncode(data)),
      statusCode,
      headers: const <String, List<String>>{
        'content-type': ['application/json'],
      },
    );
  }
}

class RequestRecord {
  final String method;
  final String path;
  final Object? body;
  const RequestRecord({required this.method, required this.path, this.body});
}

ApiService _api(_CapturingAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test.local'));
  dio.httpClientAdapter = adapter;
  return ApiService.withDio(dio);
}

void main() {
  test('listSubKeys:GET subkeys 路径,解析 subkeys 数组', () async {
    final adapter = _CapturingAdapter(200, {
      'ok': true,
      'data': {
        'subkeys': [
          {
            'id': 'k1',
            'name': '技能授权',
            'agent_id': 'a1',
            'created_at': '2026-09-01T10:00:00Z',
          },
          {
            'id': 'k2',
            'name': 'n2',
            'agent_id': 'a1',
            'created_at': '2026-09-01T09:00:00Z',
            'last_used_at': '2026-09-01T11:00:00Z',
            'revoked_at': '2026-09-01T12:00:00Z',
          },
        ],
      },
    });
    final keys = await _api(adapter).listSubKeys('a1');
    expect(adapter.requests.single.method, 'GET');
    expect(adapter.requests.single.path, '/api/agents/a1/subkeys');
    expect(keys, hasLength(2));
    expect(keys[0], isA<AgentSubKeyInfo>());
    expect(keys[0].isRevoked, isFalse);
    expect(keys[1].isRevoked, isTrue);
  });

  test('revokeSubKey:DELETE 路径,幂等 200 正常返回', () async {
    final adapter = _CapturingAdapter(
        200, {'ok': true, 'data': {'message': '吊销成功'}});
    await _api(adapter).revokeSubKey('a1', 'k1');
    expect(adapter.requests.single.method, 'DELETE');
    expect(adapter.requests.single.path, '/api/agents/a1/subkeys/k1');
  });

  test('pairComplete:authorize 模式 body 带 action + note + agent_id', () async {
    final adapter = _CapturingAdapter(200, {
      'ok': true,
      'data': {'agent_id': 'a1', 'agent_name': 'A', 'owner_user_id': 'u1'},
    });
    final result = await _api(adapter).pairComplete(
      't1',
      agentId: 'a1',
      action: 'authorize',
      note: '技能授权',
    );
    expect(adapter.requests.single.path, '/api/pair/tickets/t1/complete');
    expect(adapter.requests.single.body, {
      'agent_id': 'a1',
      'action': 'authorize',
      'note': '技能授权',
    });
    expect(result, isA<PairCompleteResult>());
  });

  test('pairComplete:不传 action/note 时 body 不含这两个字段(兼容旧语义)', () async {
    final adapter = _CapturingAdapter(200, {
      'ok': true,
      'data': {'agent_id': 'a1', 'agent_name': 'A', 'owner_user_id': 'u1'},
    });
    await _api(adapter).pairComplete('t1', agentId: 'a1');
    expect(adapter.requests.single.body, {'agent_id': 'a1'});
  });
}
