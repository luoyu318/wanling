import 'package:app/models/ws_message.dart';
import 'package:app/providers/auth_provider.dart' show apiProvider;
import 'package:app/providers/chat_provider.dart';
import 'package:app/services/api_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

void main() {
  late MockApi api;
  late FakeWS ws;

  setUp(() {
    api = MockApi();
    ws = FakeWS();
    // getMessages 返回空(初始 history)
    when(() => api.getMessages(any(),
            limit: any(named: 'limit'), offset: any(named: 'offset')))
        .thenAnswer((_) async => []);
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  /// 通过 WS 推送 MESSAGE_CREATE 注入一条消息到 state(模拟实时消息到达)。
  void emitCreate(String id, String text, {String convId = 'c1'}) {
    ws.emit(WSMessage(
      op: 0,
      t: 'MESSAGE_CREATE',
      d: {
        'id': id,
        'conversation_id': convId,
        'sender_type': 'user',
        'sender_id': 'u1',
        'content': {'msg_type': 'text', 'data': {'text': text}},
        'created_at': '2026-06-20T10:00:00Z',
      },
    ));
  }

  test('deleteMessages 单条:乐观移除 + 调 deleteMessage API', () async {
    final container = makeContainer();
    final key = (convId: 'c1', agentId: 'a1');
    final notifier = container.read(chatProvider(key).notifier);

    emitCreate('m1', 'one');
    emitCreate('m2', 'two');
    await Future.delayed(Duration.zero); // 让 stream listener 处理
    expect(container.read(chatProvider(key)).length, 2);

    when(() => api.deleteMessage('m1')).thenAnswer((_) async {});

    await notifier.deleteMessages(['m1']);

    final state = container.read(chatProvider(key));
    expect(state.length, 1);
    expect(state.any((m) => m.id == 'm1'), isFalse);
    verify(() => api.deleteMessage('m1')).called(1);
  });

  test('deleteMessages 批量:调 batchDeleteMessages API', () async {
    final container = makeContainer();
    final key = (convId: 'c1', agentId: 'a1');
    final notifier = container.read(chatProvider(key).notifier);

    emitCreate('m1', '1');
    emitCreate('m2', '2');
    await Future.delayed(Duration.zero);

    when(() => api.batchDeleteMessages(['m1', 'm2'])).thenAnswer((_) async => 2);

    await notifier.deleteMessages(['m1', 'm2']);

    expect(container.read(chatProvider(key)), isEmpty);
    verify(() => api.batchDeleteMessages(['m1', 'm2'])).called(1);
  });

  test('MESSAGE_DELETE WS 事件移除对应消息(多端同步)', () async {
    final container = makeContainer();
    final key = (convId: 'c1', agentId: 'a1');
    container.read(chatProvider(key).notifier); // 触发订阅

    emitCreate('m1', '1');
    await Future.delayed(Duration.zero);
    expect(container.read(chatProvider(key)).length, 1);

    // 另一端删除,广播 MESSAGE_DELETE
    ws.emit(WSMessage(
      op: 0,
      t: 'MESSAGE_DELETE',
      d: {
        'ids': ['m1'],
        'conversation_id': 'c1',
      },
    ));
    await Future.delayed(Duration.zero);

    expect(container.read(chatProvider(key)), isEmpty);
  });

  test('MESSAGE_DELETE 不影响其他会话的消息', () async {
    final container = makeContainer();
    final key = (convId: 'c1', agentId: 'a1');
    container.read(chatProvider(key).notifier);

    emitCreate('m1', '1', convId: 'c1');
    await Future.delayed(Duration.zero);
    expect(container.read(chatProvider(key)).length, 1);

    // 其他会话的删除事件不应影响本会话
    ws.emit(WSMessage(
      op: 0,
      t: 'MESSAGE_DELETE',
      d: {
        'ids': ['other-msg'],
        'conversation_id': 'c2', // 不同会话
      },
    ));
    await Future.delayed(Duration.zero);

    expect(container.read(chatProvider(key)).length, 1);
  });
}
