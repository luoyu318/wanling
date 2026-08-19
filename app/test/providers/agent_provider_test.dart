import 'package:wanling_core/models/agent.dart';
import 'package:wanling_core/models/ws_message.dart';
import 'package:app/providers/agent_provider.dart';
import 'package:wanling_core/services/api_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/fake_local_message_store.dart';
import '../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

void main() {
  late MockApi api;
  late FakeWS ws;
  late FakeLocalMessageStore store;

  setUp(() {
    api = MockApi();
    ws = FakeWS();
    store = FakeLocalMessageStore();
  });

  group('F5: agentListProvider cache-first', () {
    test('load 先返 cached, 后台 API 刷新', () async {
      final cached = Agent(
        id: 'a1',
        name: 'Old',
        avatarUrl: null,
        bio: null,
        status: AgentStatus.offline,
      );
      await store.putAgents('u1', [cached]);

      final fresh = Agent(
        id: 'a1',
        name: 'New',
        avatarUrl: 'http://a',
        bio: 'updated',
        status: AgentStatus.offline,
      );
      when(() => api.getAgents()).thenAnswer((_) async => [fresh]);

      final notifier = AgentListNotifier(api, ws, store: store, ownerId: 'u1');
      await Future.delayed(const Duration(milliseconds: 50));

      expect(notifier.state.first.name, 'New'); // fresh 覆盖
    });

    test('status 字段用 fresh 覆盖(server presence 实时算, 比 cached 老值可靠)', () async {
      // cached status=offline(上次 load 时 agent 离线落库的陈旧值)
      final cached = Agent(
        id: 'a1',
        name: 'Bot',
        status: AgentStatus.offline,
      );
      await store.putAgents('u1', [cached]);

      // fresh status=online(agent 重连后 server presence 实时返 online)
      final fresh = Agent(
        id: 'a1',
        name: 'Bot',
        status: AgentStatus.online,
      );
      when(() => api.getAgents()).thenAnswer((_) async => [fresh]);

      final notifier = AgentListNotifier(api, ws, store: store, ownerId: 'u1');
      await Future.delayed(const Duration(milliseconds: 50));

      // merged status=online(用 fresh 覆盖 cached 老 offline, 不再保留 local.status)
      expect(notifier.state.first.status, AgentStatus.online);
    });

    test('API 返空但 local 非空 → 不覆盖', () async {
      final cached =
          Agent(id: 'a1', name: 'Bot', status: AgentStatus.online);
      await store.putAgents('u1', [cached]);
      when(() => api.getAgents()).thenAnswer((_) async => []);

      final notifier = AgentListNotifier(api, ws, store: store, ownerId: 'u1');
      await Future.delayed(const Duration(milliseconds: 50));

      expect(notifier.state.length, 1);
      expect(notifier.state.first.id, 'a1');
    });

    test('WS AGENT_ONLINE 不落库(下次 load 自然刷新)', () async {
      final agent = Agent(
        id: 'a1',
        name: 'Bot',
        status: AgentStatus.offline,
      );
      when(() => api.getAgents()).thenAnswer((_) async => [agent]);

      final notifier = AgentListNotifier(api, ws, store: store, ownerId: 'u1');
      await Future.delayed(const Duration(milliseconds: 50));

      ws.emit(WSMessage(
        op: 0,
        t: 'AGENT_ONLINE',
        d: {'agent_id': 'a1'},
      ));
      await Future.delayed(const Duration(milliseconds: 50));

      // state 切 online
      expect(notifier.state.first.status, AgentStatus.online);
      // store 不变(瞬时状态不落)
      final stored = await store.getAgents('u1');
      expect(stored.first.status, AgentStatus.offline); // 仍是初始 offline
    });
  });
}
