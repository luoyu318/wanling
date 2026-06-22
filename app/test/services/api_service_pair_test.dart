import 'package:app/models/pairing.dart';
import 'package:app/services/api_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/mock_adapter.dart';

void main() {
  late ApiService api;

  setUp(() {
    final dio = Dio(BaseOptions(baseUrl: 'https://test.local'));
    api = ApiService.withDio(dio);
  });

  test('pairScan 解析 agents 列表', () async {
    final dio = api.dio;
    dio.httpClientAdapter = MockHttpClientAdapter(200, {
      'agents': [
        {'id': 'a1', 'name': 'Agent1', 'avatar_url': null, 'bio': null, 'status': 'online'},
        {'id': 'a2', 'name': 'Agent2', 'avatar_url': null, 'bio': 'x', 'status': 'offline'},
      ],
    });

    final result = await api.pairScan('ticket-001');
    expect(result.status, isNull);
    expect(result.agents.length, 2);
    expect(result.agents[0].name, 'Agent1');
    expect(result.agents[1].bio, 'x');
  });

  test('pairScan 票据过期返回 status=expired', () async {
    final dio = api.dio;
    dio.httpClientAdapter = MockHttpClientAdapter(200, {
      'status': 'expired',
    });

    final result = await api.pairScan('expired-ticket');
    expect(result.status, 'expired');
    expect(result.agents, isEmpty);
  });

  test('pairComplete 解析 agent_id + agent_name', () async {
    final dio = api.dio;
    dio.httpClientAdapter = MockHttpClientAdapter(200, {
      'agent_id': 'a-new-1',
      'agent_name': '我的 hermes',
    });

    final result = await api.pairComplete('ticket-001', newAgentName: '我的 hermes');
    expect(result.agentId, 'a-new-1');
    expect(result.agentName, '我的 hermes');
  });

  test('pairComplete 传 agent_id 走选已有分支', () async {
    final dio = api.dio;
    dio.httpClientAdapter = CapturingMockAdapter(200, {
      'agent_id': 'existing-1',
      'agent_name': 'Existing',
    });

    final result = await api.pairComplete('ticket-001', agentId: 'existing-1');
    expect(result.agentId, 'existing-1');
    // 验证请求体含 agent_id（CapturingMockAdapter 捕获）
    final adapter = dio.httpClientAdapter as CapturingMockAdapter;
    expect(adapter.captured.data, {'agent_id': 'existing-1'});
  });
}
