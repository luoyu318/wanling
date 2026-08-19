import 'package:wanling_core/providers/agent_status_provider.dart';
import 'package:wanling_core/providers/chat_provider.dart' show wsProvider;
import 'package:wanling_core/providers/typing_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_ws.dart';

void main() {
  late FakeWS ws;

  setUp(() {
    ws = FakeWS();
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(overrides: [
      wsProvider.overrideWithValue(ws),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  test('SESSION_STATUS busy → agentStatusProvider[convId] = busy', () async {
    final container = makeContainer();
    // 触发 provider 初始化
    container.read(agentStatusProvider);

    ws.emitSessionStatus({
      'conversation_id': 'c1',
      'status': 'busy',
    });
    await Future.delayed(Duration.zero);

    final status = container.read(agentStatusProvider)['c1'];
    expect(status, isNotNull);
    expect(status!.type, AgentStatusType.busy);
  });

  test('SESSION_STATUS retry → agentStatusProvider[convId] = retry + attempt', () async {
    final container = makeContainer();
    container.read(agentStatusProvider);

    ws.emitSessionStatus({
      'conversation_id': 'c1',
      'status': 'retry',
      'attempt': 3,
      'message': 'timeout',
    });
    await Future.delayed(Duration.zero);

    final status = container.read(agentStatusProvider)['c1'];
    expect(status!.type, AgentStatusType.retry);
    expect(status.attempt, 3);
    expect(status.message, 'timeout');
  });

  test('SESSION_STATUS idle → 清状态 + 清 typing', () async {
    final container = makeContainer();
    container.read(agentStatusProvider);
    container.read(typingProvider);

    // 先设 busy
    ws.emitSessionStatus({'conversation_id': 'c1', 'status': 'busy'});
    await Future.delayed(Duration.zero);
    expect(container.read(agentStatusProvider)['c1'], isNotNull);

    // 先设 typing(模拟 TYPING_START 已收到,直接经 notifier 设)
    container.read(typingProvider.notifier).startTyping('c1');
    expect(container.read(typingProvider)['c1'], isTrue);

    // 再设 idle —— 应同时清 agentStatus 和 typing
    ws.emitSessionStatus({'conversation_id': 'c1', 'status': 'idle'});
    await Future.delayed(Duration.zero);

    expect(container.read(agentStatusProvider)['c1'], isNull);
    // clearTyping 会移除 key,所以读出来是 null
    expect(container.read(typingProvider)['c1'], isNull);
  });
}
