import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/unread_info.dart';
import 'package:wanling_core/models/ws_message.dart';
import 'package:app/providers/auth_provider.dart' show apiProvider;
import 'package:app/providers/chat_provider.dart';
import 'package:wanling_core/services/api_service.dart';

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
    when(() => api.sendMessage(any(), any())).thenAnswer((_) async =>
        (messageId: 'srv_1', createdAt: DateTime.utc(2026, 7, 7)));
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

  void emitAggregateCard(String id) {
    ws.emit(WSMessage(
      op: 0,
      t: 'MESSAGE_CREATE',
      d: {
        'id': id,
        'conversation_id': 'c1',
        'sender_type': 'agent',
        'sender_id': 'a1',
        'content': {
          'msg_type': 'aggregate_card',
          'data': {
            'schema_ver': 1,
            'state': 'generating',
            'elements': <Map<String, dynamic>>[],
          },
        },
        'created_at': DateTime.now().toIso8601String(),
      },
    ));
  }

  test('用户乐观消息按时序 append(在聚合卡下方)', () async {
    final container = makeContainer();
    // 先注入聚合卡(agent 对上一轮的回答,isStreaming=false 终态卡)
    emitAggregateCard('agg-1');
    await pump();

    // 用户发新消息:按实际时序 append 到末尾(聚合卡下方)
    final notifier =
        container.read(chatProvider((convId: 'c1', agentId: 'a1')).notifier);
    await notifier.sendText('新消息');
    await pump();

    final live =
        container.read(chatProvider((convId: 'c1', agentId: 'a1'))).liveMessages;
    expect(live.length, greaterThanOrEqualTo(2));
    final userIdx = live.indexWhere((m) =>
        m.content['msg_type'] == 'text' &&
        (m.content['data'] as Map?)?['text'] == '新消息');
    final aggIdx = live.indexWhere((m) => m.id == 'agg-1');
    expect(userIdx, greaterThanOrEqualTo(0));
    expect(aggIdx, greaterThanOrEqualTo(0));
    expect(userIdx, greaterThan(aggIdx), reason: '用户消息应按时序排在聚合卡下方');
  });
}
