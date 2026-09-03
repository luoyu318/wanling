import 'dart:convert';
import 'dart:typed_data';

import 'package:app/services/background_chat_service.dart';
import 'package:wanling_core/utils/notification_payload.dart';
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
    final loaderCalls = <({String agentId, String? avatarUrl})>[];
    final fakeAvatar = Uint8List.fromList([1, 2, 3]);

    String updateRaw({
      required bool silent,
      String state = 'generating',
      String? senderId,
      String? senderName,
      String? senderAvatarUrl,
    }) =>
        jsonEncode({
          'op': 0,
          't': 'MESSAGE_UPDATE',
          'd': {
            'message_id': 'm1',
            'conversation_id': 'c1',
            'sender_id': ?senderId,
            'sender_name': ?senderName,
            'sender_avatar_url': ?senderAvatarUrl,
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
            'conversation_type': 'agent_session',
            'conversation_title': '我的会话',
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
      loaderCalls.clear();
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
        avatarLoader: ({
          required agentId,
          required name,
          avatarUrl,
          required baseUrl,
          required httpHeaders,
          onUnauthorized,
        }) async {
          loaderCalls.add((agentId: agentId, avatarUrl: avatarUrl));
          return (fakeAvatar, avatarUrl != null && avatarUrl.isNotEmpty);
        },
      );
    });

    test('翻转(新 server 带 sender 三件套)→ 回查不依赖 CREATE 记录,直接消费 payload', () async {
      // 模拟 bg-service 回合中途重启:_convSenders 空(没见过 MESSAGE_CREATE),
      // 仅收到翻转 MESSAGE_UPDATE(新 server payload 带 sender 字段)。
      service.setConnectionForTest(baseUrl: 'http://localhost:18008', token: 't');
      await service.handleRawMessageForTest(
        updateRaw(
          silent: false,
          state: 'done',
          senderId: 'agent-9',
          senderName: '灵仔',
          senderAvatarUrl: '/api/files/abc',
          ),
      );

      expect(notified.length, 1);
      // loader 直接用 payload 的 senderId + avatarUrl 发起下载(非色块路径)
      expect(loaderCalls.single.agentId, 'agent-9');
      expect(loaderCalls.single.avatarUrl, '/api/files/abc');
      // 通知 avatarBytes 是 loader 返回的真头像(非空)
      // (title 因 agent_session 无 conv 字段走单聊分支 = senderName)
      expect(notified.first.title, '灵仔');
    });

    test('翻转(新 server 带 sender 字段)→ 回填 _convSenders + 真头像进内存缓存', () async {
      service.setConnectionForTest(baseUrl: 'http://localhost:18008', token: 't');
      await service.handleRawMessageForTest(
        updateRaw(
          silent: false,
          state: 'done',
          senderId: 'agent-9',
          senderName: '灵仔',
          senderAvatarUrl: '/api/files/abc',
          ),
      );
      await service.handleRawMessageForTest(
        updateRaw(
          silent: false,
          state: 'done',
          senderId: 'agent-9',
          senderName: '灵仔',
          senderAvatarUrl: '/api/files/abc',
          ),
      );

      expect(notified.length, 2);
      // 第二次通知头像走内存缓存,loader 仅首次调用
      expect(loaderCalls.length, 1);
      expect(loaderCalls.single.agentId, 'agent-9');
    });

    test('翻转(loader 返回色块 isReal=false)→ 色块不进内存缓存,下次重新加载', () async {
      var isReal = false;
      final blockLoaderCalls = <String>[];
      final blockService = BackgroundChatService(
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
        avatarLoader: ({
          required agentId,
          required name,
          avatarUrl,
          required baseUrl,
          required httpHeaders,
          onUnauthorized,
        }) async {
          blockLoaderCalls.add(agentId);
          return (fakeAvatar, isReal);
        },
      );
      blockService.setConnectionForTest(baseUrl: 'http://localhost:18008', token: 't');
      await blockService.handleRawMessageForTest(
        updateRaw(silent: false, state: 'done', senderId: 'agent-9', senderName: '灵仔'),
      );
      isReal = true; // 模拟弱网恢复:第二次加载拿到真头像
      await blockService.handleRawMessageForTest(
        updateRaw(silent: false, state: 'done', senderId: 'agent-9', senderName: '灵仔'),
      );

      // 色块那次没进缓存,第二次重新调 loader(下载重试机会)
      expect(blockLoaderCalls.length, 2);
      expect(notified.length, 2);
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

    test('set_silent 增量翻转 → 弹通知 + unread +1(通知 body 取 server 附带的 preview)', () async {
      // 先收到创建阶段的 silent MESSAGE_CREATE(bg-service 记录会话发送者)
      await service.handleRawMessageForTest(createRaw());

      await service.handleRawMessageForTest(jsonEncode({
        'op': 0,
        't': 'MESSAGE_UPDATE',
        'd': {
          'message_id': 'm1',
          'conversation_id': 'c1',
          'conversation_type': 'agent_session',
          'conversation_title': '我的会话',
          'content': {
            'msg_type': 'aggregate_card',
            'data': {
              'op': 'set_silent',
              'silent': false,
              'preview': '回合最终回复',
            },
          },
        },
      }));

      expect(service.unreadForTest('c1'), 1);
      expect(notified.length, 1);
      // delta 无 elements,通知 body 取 server 翻转广播附带的 preview
      expect(notified.first.body, '回合最终回复');
      // 翻转广播附带会话 type/title:agent_session 通知 title=会话标题(非 agent 名)
      expect(notified.first.title, '我的会话',
          reason: 'agent_session 翻转通知 title 应取会话标题');
    });

    test('set_silent 增量翻转 老 server 无 conv 字段 → title fallback 会话 sender 名',
        () async {
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
            'data': {
              'op': 'set_silent',
              'silent': false,
              'preview': '回合最终回复',
            },
          },
        },
      }));

      expect(service.unreadForTest('c1'), 1);
      expect(notified.length, 1);
      // 老 server 广播无 conversation_type:convType='' → 走单聊分支 title=senderName
      expect(notified.first.title, 'Agent');
    });

    test('set_silent 增量翻转 preview 缺失 → body 兜底聚合回复', () async {
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
      // 老 server / 无 preview 时退化兜底 '[聚合回复]'
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
