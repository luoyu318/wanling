import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/agent.dart';
import 'package:app/models/conversation.dart';
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

/// Agent 测试用 fixture（字段对齐 server model.Agent json tag）。
Map<String, dynamic> _agentJson(String id, {String? secretKey}) => {
      'id': id,
      'name': 'agent-$id',
      'avatar_url': null,
      'bio': null,
      'status': 'offline',
      if (secretKey != null) 'secret_key': secretKey,
    };

/// Conversation 测试用 fixture（字段对齐 server ConversationListItem json tag）。
Map<String, dynamic> _convJson(String id) => {
      'id': id,
      'type': 'dm_user_agent',
      'title': null,
      'avatar_url': null,
      'last_message_content': null,
      'last_message_at': '2026-07-04T10:00:00Z',
      'created_at': '2026-07-04T09:00:00Z',
      'unread_count': 0,
      'participants': [],
    };

void main() {
  test('getAgents 返 List<Agent>', () async {
    final api = _api([_agentJson('a1'), _agentJson('a2')]);
    final result = await api.getAgents();
    expect(result, isA<List<Agent>>());
    expect(result.length, 2);
    expect(result.first.id, 'a1');
    expect(result.last.id, 'a2');
  });

  test('createAgent 返 Agent（含 secret_key）', () async {
    final api = _api(_agentJson('a1', secretKey: 'sk-xxx'));
    final agent = await api.createAgent('new-agent');
    expect(agent, isA<Agent>());
    expect(agent.id, 'a1');
    expect(agent.secretKey, 'sk-xxx');
  });

  test('Agent.fromJson 解析 type 字段(opencode)', () {
    final json = _agentJson('a1')..['type'] = 'opencode';
    final agent = Agent.fromJson(json);
    expect(agent.type, 'opencode');
  });

  test('Agent.fromJson type 缺失时回退空串', () {
    final agent = Agent.fromJson(_agentJson('a1'));
    expect(agent.type, '');
  });

  test('createAgent 带 type 发送 type 字段', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://test'));
    final api = ApiService.withDio(dio);
    final adapter = CapturingMockAdapter(
      200,
      {'ok': true, 'data': _agentJson('a1')..['type'] = 'opencode'},
    );
    dio.httpClientAdapter = adapter;
    final agent = await api.createAgent('oc-agent', type: 'opencode');
    expect(agent.type, 'opencode');
    // 验证 body 含 type
    final body = adapter.captured.data as Map<String, dynamic>;
    expect(body.containsKey('type'), isTrue);
    expect(body['type'], 'opencode');
  });

  test('updateAgent 返 Agent', () async {
    final api = _api(_agentJson('a1')..['name'] = 'renamed');
    final agent = await api.updateAgent('a1', name: 'renamed');
    expect(agent, isA<Agent>());
    expect(agent.id, 'a1');
    expect(agent.name, 'renamed');
  });

  test('getConversations 返 List<Conversation>', () async {
    final api = _api([_convJson('c1'), _convJson('c2')]);
    final result = await api.getConversations();
    expect(result, isA<List<Conversation>>());
    expect(result.length, 2);
    expect(result.first.id, 'c1');
    expect(result.last.id, 'c2');
  });

  test('findOrCreateConversation 返 Conversation', () async {
    final api = _api(_convJson('c1'));
    final conv = await api.findOrCreateConversation('agent-1');
    expect(conv, isA<Conversation>());
    expect(conv.id, 'c1');
  });

  test('createConversation 返 Conversation', () async {
    final api = _api(_convJson('c1'));
    final conv = await api.createConversation(
      type: 'dm_user_agent',
      memberIds: const ['a1'],
      memberTypes: const ['agent'],
    );
    expect(conv, isA<Conversation>());
    expect(conv.id, 'c1');
  });

  test('getConversation 返 Conversation', () async {
    final api = _api(_convJson('c1'));
    final conv = await api.getConversation('c1');
    expect(conv, isA<Conversation>());
    expect(conv.id, 'c1');
  });
}
