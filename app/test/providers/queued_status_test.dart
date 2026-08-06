import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:app/models/message.dart';
import 'package:app/models/unread_info.dart';
import 'package:app/models/ws_message.dart';
import 'package:app/providers/auth_provider.dart' show apiProvider;
import 'package:app/providers/chat_provider.dart';
import 'package:app/services/api_service.dart';

import '../helpers/fake_ws.dart';

class MockApi extends Mock implements ApiService {}

void main() {
  late MockApi api;
  late FakeWS ws;

  setUp(() {
    api = MockApi();
    ws = FakeWS();
    when(() => api.getUnreadInfo(any()))
        .thenAnswer((_) async => const UnreadInfo(unreadCount: 0));
    when(() => api.getMessagesBefore(any(),
            limit: any(named: 'limit'), before: any(named: 'before')))
        .thenAnswer((_) async => <ChatMessage>[]);
    when(() => api.getMessages(any(),
            limit: any(named: 'limit'), offset: any(named: 'offset')))
        .thenAnswer((_) async => <ChatMessage>[]);
  });

  ProviderContainer makeContainer() {
    final container = ProviderContainer(overrides: [
      apiProvider.overrideWithValue(api),
      wsProvider.overrideWithValue(ws),
    ]);
    addTearDown(container.dispose);
    container.listen(chatProvider((convId: 'c1', agentId: 'a1')), (_, _) {});
    return container;
  }

  Future<void> pump([int ms = 50]) =>
      Future.delayed(Duration(milliseconds: ms));

  void emitUserMessage(String id, String text) {
    ws.emit(WSMessage(
      op: 0,
      t: 'MESSAGE_CREATE',
      d: {
        'id': id,
        'conversation_id': 'c1',
        'sender_type': 'user',
        'sender_id': 'u1',
        'content': {'msg_type': 'text', 'data': {'text': text}},
        'created_at': DateTime.now().toIso8601String(),
      },
    ));
  }

  void emitQueuedStatus(String messageId, bool queued) {
    ws.emit(WSMessage(
      op: 0,
      t: 'MESSAGE_CREATE',
      d: {
        'id': 'status-$messageId',
        'conversation_id': 'c1',
        'sender_type': 'agent',
        'sender_id': 'a1',
        'content': {
          'msg_type': 'queued_status',
          'data': {'message_id': messageId, 'queued': queued},
        },
        'created_at': DateTime.now().toIso8601String(),
      },
    ));
  }

  test('queued_status queued=true 标记消息排队', () async {
    final container = makeContainer();
    emitUserMessage('msg-1', 'hello');
    await pump();

    emitQueuedStatus('msg-1', true);
    await pump();

    final live = container.read(chatProvider((convId: 'c1', agentId: 'a1'))).liveMessages;
    final msg = live.firstWhere((m) => m.id == 'msg-1');
    expect(msg.queued, isTrue);
  });

  test('queued_status queued=false 解除排队', () async {
    final container = makeContainer();
    emitUserMessage('msg-1', 'hello');
    await pump();

    emitQueuedStatus('msg-1', true);
    await pump();
    emitQueuedStatus('msg-1', false);
    await pump();

    final live = container.read(chatProvider((convId: 'c1', agentId: 'a1'))).liveMessages;
    final msg = live.firstWhere((m) => m.id == 'msg-1');
    expect(msg.queued, isFalse);
  });
}
