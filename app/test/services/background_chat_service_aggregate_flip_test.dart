import 'dart:convert';
import 'dart:typed_data';

import 'package:app/services/background_chat_service.dart';
import 'package:app/utils/notification_payload.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockServiceInstance extends Mock implements ServiceInstance {}

void main() {
  setUp(() {
    // bg-service 处理消息时读 prefs(agent 名 / myUserId fallback),用 mock 兜底
    SharedPreferences.setMockInitialValues({});
  });

  group('isAggregateCardSilentFlip(聚合卡回合结束翻转识别)', () {
    test('aggregate_card + silent=false → true(回合结束翻转)', () {
      expect(
        BackgroundChatService.isAggregateCardSilentFlip({
          'msg_type': 'aggregate_card',
          'data': {'state': 'done'},
          'silent': false,
        }),
        isTrue,
      );
    });

    test('aggregate_card + silent=true(generating)→ false', () {
      expect(
        BackgroundChatService.isAggregateCardSilentFlip({
          'msg_type': 'aggregate_card',
          'data': {'state': 'generating'},
          'silent': true,
        }),
        isFalse,
      );
    });

    test('非聚合卡 silent=false → false', () {
      expect(
        BackgroundChatService.isAggregateCardSilentFlip({
          'msg_type': 'text',
          'data': {'text': 'hi'},
          'silent': false,
        }),
        isFalse,
      );
    });

    test('null / 缺 silent 字段 → false', () {
      expect(BackgroundChatService.isAggregateCardSilentFlip(null), isFalse);
      expect(
        BackgroundChatService.isAggregateCardSilentFlip({
          'msg_type': 'aggregate_card',
          'data': {'state': 'done'},
        }),
        isFalse,
      );
    });

    test('set_silent 增量 delta(silent 在 data 内)→ true(回合结束翻转)', () {
      expect(
        BackgroundChatService.isAggregateCardSilentFlip({
          'msg_type': 'aggregate_card',
          'data': {'op': 'set_silent', 'silent': false},
        }),
        isTrue,
      );
    });

    test('set_silent 增量 delta silent=true → false', () {
      expect(
        BackgroundChatService.isAggregateCardSilentFlip({
          'msg_type': 'aggregate_card',
          'data': {'op': 'set_silent', 'silent': true},
        }),
        isFalse,
      );
    });

    test('非 set_silent 的其他 op(如 set_state)→ false', () {
      expect(
        BackgroundChatService.isAggregateCardSilentFlip({
          'msg_type': 'aggregate_card',
          'data': {'op': 'set_state', 'state': 'done'},
        }),
        isFalse,
      );
    });
  });

  group('MESSAGE_UPDATE 聚合卡翻转处理', () {
    late BackgroundChatService service;
    late List<({NotificationPayload payload, String title, String body, int unreadCount})>
    notified;

    String updateRaw({required bool silent, String state = 'generating'}) =>
        jsonEncode({
          'op': 0,
          't': 'MESSAGE_UPDATE',
          'd': {
            'message_id': 'm1',
            'conversation_id': 'c1',
            'content': {
              'msg_type': 'aggregate_card',
              'data': {
                'state': state,
                'elements': [
                  {'type': 'markdown', 'data': {'text': '回合最终回复'}},
                ],
              },
              'silent': silent,
            },
          },
        });

    String createRaw() => jsonEncode({
          'op': 0,
          't': 'MESSAGE_CREATE',
          'd': {
            'id': 'm1',
            'conversation_id': 'c1',
            'sender_type': 'agent',
            'sender_id': 'agent-1',
            'content': {
              'msg_type': 'aggregate_card',
              'data': {'state': 'generating'},
              'silent': true,
            },
            'created_at': '2026-07-01T11:00:00Z',
          },
        });

    setUp(() {
      notified = [];
      service = BackgroundChatService(
        _MockServiceInstance(),
        showNotification: ({
          required NotificationPayload payload,
          required String title,
          required String body,
          required int unreadCount,
          Uint8List? avatarBytes,
        }) async {
          notified.add((
            payload: payload,
            title: title,
            body: body,
            unreadCount: unreadCount,
          ));
        },
      );
    });

    test('翻转(silent false)→ 弹通知 + unread +1', () async {
      // 先收到创建阶段的 silent MESSAGE_CREATE(bg-service 记录会话发送者)
      await service.handleRawMessageForTest(createRaw());

      await service.handleRawMessageForTest(
        updateRaw(silent: false, state: 'done'),
      );

      expect(service.unreadForTest('c1'), 1);
      expect(notified.length, 1);
      expect(notified.first.body, '回合最终回复',
          reason: '通知 body 应取聚合卡最后 markdown 元素文本');
      expect(notified.first.unreadCount, 1);
    });

    test('generating 阶段(silent 仍 true)→ 不弹通知 + unread 不变', () async {
      await service.handleRawMessageForTest(updateRaw(silent: true));

      expect(service.unreadForTest('c1'), 0);
      expect(notified, isEmpty,
          reason: 'generating 阶段的 MESSAGE_UPDATE 不应触发通知');
    });

    test('set_silent 增量翻转 → 弹通知 + unread +1(body 兜底聚合回复)', () async {
      // 先收到创建阶段的 silent MESSAGE_CREATE(bg-service 记录会话发送者)
      await service.handleRawMessageForTest(createRaw());

      await service.handleRawMessageForTest(jsonEncode({
        'op': 0,
        't': 'MESSAGE_UPDATE',
        'd': {
          'message_id': 'm1',
          'conversation_id': 'c1',
          'content': {
            'msg_type': 'aggregate_card',
            'data': {'op': 'set_silent', 'silent': false},
          },
        },
      }));

      expect(service.unreadForTest('c1'), 1);
      expect(notified.length, 1);
      // delta 无 elements,通知 body 退化兜底 '[聚合回复]'
      expect(notified.first.body, '[聚合回复]');
    });

    test('set_silent 增量 silent=true → 不弹通知 + unread 不变', () async {
      await service.handleRawMessageForTest(createRaw());

      await service.handleRawMessageForTest(jsonEncode({
        'op': 0,
        't': 'MESSAGE_UPDATE',
        'd': {
          'message_id': 'm1',
          'conversation_id': 'c1',
          'content': {
            'msg_type': 'aggregate_card',
            'data': {'op': 'set_silent', 'silent': true},
          },
        },
      }));

      expect(service.unreadForTest('c1'), 0);
      expect(notified, isEmpty);
    });
  });
}
