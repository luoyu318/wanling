import 'package:app/models/message.dart';
import 'package:app/models/msg_type.dart';
import 'package:app/utils/aggregate_card_state.dart';
import 'package:flutter_test/flutter_test.dart';

ChatMessage msg(String id, Map<String, dynamic> content) {
  return ChatMessage(
    id: id,
    conversationId: 'c1',
    senderType: 'agent',
    senderId: 'a1',
    content: content,
    createdAt: DateTime.now(),
  );
}

void main() {
  group('hasGeneratingAggregateCard', () {
    test('存在 generating 聚合卡 → true', () {
      final msgs = [
        msg('m1', {
          'msg_type': MsgType.aggregateCard.value,
          'data': {'state': 'generating', 'elements': const []},
        }),
      ];
      expect(hasGeneratingAggregateCard(msgs), isTrue);
    });

    test('聚合卡 done → false', () {
      final msgs = [
        msg('m1', {
          'msg_type': MsgType.aggregateCard.value,
          'data': {'state': 'done', 'elements': const []},
        }),
      ];
      expect(hasGeneratingAggregateCard(msgs), isFalse);
    });

    test('无聚合卡(普通消息)→ false', () {
      final msgs = [
        msg('m1', {'msg_type': MsgType.text.value, 'data': {'text': 'hi'}}),
      ];
      expect(hasGeneratingAggregateCard(msgs), isFalse);
    });

    test('聚合卡 state 缺失默认 generating → true', () {
      final msgs = [
        msg('m1', {
          'msg_type': MsgType.aggregateCard.value,
          'data': {'elements': const []},
        }),
      ];
      expect(hasGeneratingAggregateCard(msgs), isTrue);
    });
  });
}
