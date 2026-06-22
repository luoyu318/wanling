import 'package:app/providers/agent_provider.dart';
import 'package:app/providers/auth_provider.dart' show apiProvider;
import 'package:app/providers/chat_provider.dart' show wsProvider;
import 'package:app/services/api_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

void main() {
  late MockApi api;

  setUp(() {
    api = MockApi();
    // AgentListNotifier 构造时会调用 load() → api.getAgents()
    when(() => api.getAgents()).thenAnswer((_) async => [
          {
            'id': 'a1',
            'name': 'Alpha',
            'avatar_url': null,
            'owner_id': 'u1',
            'status': 'online',
            'created_at': '2026-06-13T00:00:00Z',
          },
          {
            'id': 'a2',
            'name': 'Beta',
            'avatar_url': null,
            'owner_id': 'u1',
            'status': 'offline',
            'created_at': '2026-06-13T00:00:00Z',
          },
        ]);
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(FakeWS()),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  test('命中已知 agent 时返回对应 Agent', () async {
    final container = makeContainer();
    // 触发 agentListNotifier.load() 完成
    await container.read(agentListProvider.notifier).load();

    final agent = container.read(agentByIdProvider('a1'));
    expect(agent, isNotNull);
    expect(agent!.id, 'a1');
    expect(agent.name, 'Alpha');
  });

  test('未知 agent ID 返回 null（不抛异常）', () async {
    final container = makeContainer();
    await container.read(agentListProvider.notifier).load();

    final agent = container.read(agentByIdProvider('does-not-exist'));
    expect(agent, isNull);
  });

  test('不同 family arg 互不干扰', () async {
    final container = makeContainer();
    await container.read(agentListProvider.notifier).load();

    expect(container.read(agentByIdProvider('a1'))?.name, 'Alpha');
    expect(container.read(agentByIdProvider('a2'))?.name, 'Beta');
    expect(container.read(agentByIdProvider('a3')), isNull);
  });
}
