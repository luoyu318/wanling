// agentTabUnreadProvider 单测:unreadCount 求和 + 未加载(null)返 0。
// 用 overrideWith 替换 family 的 build,注入不含 API 的轻量 fake notifier。
// 注:riverpod 2.6.1 的 family overrideWith 要求返回 AgentSessionsNotifier
// 具体类型,故 fake 以子类实现;load() 置空避免构造期触达 API,state 由
// 构造体直接赋值(等价于注入初始 state)。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:wanling_core/models/conversation.dart';
import 'package:wanling_core/providers/agent_sessions_provider.dart';
import 'package:wanling_core/services/api_service.dart';

import '../helpers/fake_local_message_store.dart';
import '../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

class _FakeSessionsNotifier extends AgentSessionsNotifier {
  _FakeSessionsNotifier(List<Conversation>? initial)
      : super(MockApi(), FakeWS(), '', '', FakeLocalMessageStore()) {
    if (initial != null) state = initial;
  }

  @override
  Future<void> load() async {}
}

Conversation _conv(String id, int unread) => Conversation(
      id: id,
      type: 'agent_session',
      participants: const [],
      lastMessageContent: null,
      lastMessageAt: DateTime.utc(2026),
      createdAt: DateTime.utc(2026),
      unreadCount: unread,
    );

void main() {
  test('求和所有 session 的 unreadCount', () {
    final container = ProviderContainer(overrides: [
      agentSessionsProvider.overrideWith((ref, agentId) =>
          _FakeSessionsNotifier([_conv('c1', 3), _conv('c2', 2)])),
    ]);
    addTearDown(container.dispose);
    expect(container.read(agentTabUnreadProvider('a1')), 5);
  });

  test('sessions 未加载(null)返回 0', () {
    final container = ProviderContainer(overrides: [
      agentSessionsProvider
          .overrideWith((ref, agentId) => _FakeSessionsNotifier(null)),
    ]);
    addTearDown(container.dispose);
    expect(container.read(agentTabUnreadProvider('a1')), 0);
  });

  test('sessions 为空列表返回 0(与未加载 null 同口径)', () {
    final container = ProviderContainer(overrides: [
      agentSessionsProvider.overrideWith(
          (ref, agentId) => _FakeSessionsNotifier(const <Conversation>[])),
    ]);
    addTearDown(container.dispose);
    expect(container.read(agentTabUnreadProvider('a1')), 0);
  });

  test('sessions state 变化后角标重算(markReadLocally 清零不残留旧徽章)', () {
    final container = ProviderContainer(overrides: [
      agentSessionsProvider.overrideWith((ref, agentId) =>
          _FakeSessionsNotifier([_conv('c1', 3), _conv('c2', 2)])),
    ]);
    addTearDown(container.dispose);
    expect(container.read(agentTabUnreadProvider('a1')), 5);
    // 经 notifier 改 sessions state → watch agentSessionsProvider 的角标必须重算
    container.read(agentSessionsProvider('a1').notifier).markReadLocally('c1');
    expect(container.read(agentTabUnreadProvider('a1')), 2);
  });
}
