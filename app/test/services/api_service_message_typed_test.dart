import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/message.dart';
import 'package:app/models/unread_info.dart';
import 'package:app/services/api_service.dart';

import '../helpers/mock_adapter.dart';

/// 构造 ApiService，MockAdapter 用 envelope 包装 data。
/// 拦截器剥 envelope 后业务层拿到 data 部分。
ApiService _api(dynamic data) {
  final dio = Dio(BaseOptions(baseUrl: 'http://test'));
  final api = ApiService.withDio(dio);
  dio.httpClientAdapter = CapturingMockAdapter(
    200,
    {'ok': true, 'data': data},
  );
  return api;
}

/// ChatMessage fixture（字段对齐 server model.Message json tag +
/// SanitizeForClient 后的 content 形态）。
Map<String, dynamic> _msgJson(String id, {String? senderRole}) {
  final msg = <String, dynamic>{
    'id': id,
    'conversation_id': 'c1',
    'sender_type': 'user',
    'sender_id': 'u1',
    'content': {'msg_type': 'text', 'data': {'text': 'hi'}},
    'created_at': '2026-07-04T10:00:00Z',
  };
  if (senderRole != null) msg['sender_role'] = senderRole;
  return msg;
}

void main() {
  group('message 6 method 类型化', () {
    test('markConversationRead 返 void', () async {
      final api = _api(null);
      await api.markConversationRead('c1');
      // 不抛即通过；额外校验 request path/method
      final captured =
          (api.dio.httpClientAdapter as CapturingMockAdapter).captured;
      expect(captured.path, '/api/conversations/c1/read');
      expect(captured.method, 'POST');
    });

    test('markMessagesRead 返 record (unreadCount)', () async {
      final api = _api({'unread_count': 3});
      final result = await api.markMessagesRead('c1', ['m1', 'm2']);
      expect(result, isA<({int unreadCount})>());
      expect(result.unreadCount, 3);
      // 校验 request body
      final captured =
          (api.dio.httpClientAdapter as CapturingMockAdapter).captured;
      expect(captured.path, '/api/conversations/c1/messages/read');
      expect(captured.data, {'message_ids': ['m1', 'm2']});
    });

    test('markMessagesRead server 返缺字段时兜底 0', () async {
      // server 实际总返 unread_count，但兜底防御测试
      final api = _api(<String, dynamic>{});
      final result = await api.markMessagesRead('c1', ['m1']);
      expect(result.unreadCount, 0);
    });

    test('getUnreadInfo 返 UnreadInfo', () async {
      final api = _api({
        'unread_count': 5,
        'first_unread_message_id': 'm9',
        'first_unread_created_at': '2026-07-04T09:00:00Z',
        'has_more_before_first_unread': true,
      });
      final info = await api.getUnreadInfo('c1');
      expect(info, isA<UnreadInfo>());
      expect(info.unreadCount, 5);
      expect(info.firstUnreadMessageId, 'm9');
      expect(info.firstUnreadCreatedAt, DateTime.utc(2026, 7, 4, 9));
      expect(info.hasMoreBeforeFirstUnread, true);
    });

    test('getUnreadInfo 无未读时空字段规范化', () async {
      // server 无未读时 first_unread_message_id/created_at 返空字符串
      final api = _api({
        'unread_count': 0,
        'first_unread_message_id': '',
        'first_unread_created_at': '',
        'has_more_before_first_unread': false,
      });
      final info = await api.getUnreadInfo('c1');
      expect(info.unreadCount, 0);
      expect(info.firstUnreadMessageId, isNull);
      expect(info.firstUnreadCreatedAt, isNull);
      expect(info.hasMoreBeforeFirstUnread, false);
    });

    test('getMessagesBefore 返 List<ChatMessage>', () async {
      final api = _api([_msgJson('m1'), _msgJson('m2')]);
      final result = await api.getMessagesBefore('c1', limit: 20);
      expect(result, isA<List<ChatMessage>>());
      expect(result.length, 2);
      expect(result.first.id, 'm1');
      expect(result.first.conversationId, 'c1');
      expect(result.first.content['msg_type'], 'text');
    });

    test('getMessagesBefore 带 before 游标写入 query', () async {
      final api = _api(<Map<String, dynamic>>[]);
      final before = DateTime.utc(2026, 7, 4, 10);
      await api.getMessagesBefore('c1', before: before, limit: 30);
      final captured =
          (api.dio.httpClientAdapter as CapturingMockAdapter).captured;
      expect(captured.path, '/api/conversations/c1/messages');
      expect(captured.queryParameters['limit'], 30);
      expect(captured.queryParameters['before'], before.toUtc().toIso8601String());
    });

    test('getMessagesAfter 返 List<ChatMessage>', () async {
      final api = _api([_msgJson('m1', senderRole: 'admin')]);
      final after = DateTime.utc(2026, 7, 4, 9);
      final result = await api.getMessagesAfter('c1', after: after, limit: 15);
      expect(result, isA<List<ChatMessage>>());
      expect(result.length, 1);
      expect(result.first.id, 'm1');
      expect(result.first.senderRole, 'admin');
      final captured =
          (api.dio.httpClientAdapter as CapturingMockAdapter).captured;
      expect(captured.queryParameters['after'], after.toUtc().toIso8601String());
      expect(captured.queryParameters['limit'], 15);
    });

    test('getMessages 返 List<ChatMessage>', () async {
      final api = _api([_msgJson('m1'), _msgJson('m2'), _msgJson('m3')]);
      final result = await api.getMessages('c1', limit: 50, offset: 10);
      expect(result, isA<List<ChatMessage>>());
      expect(result.length, 3);
      expect(result[1].id, 'm2');
      final captured =
          (api.dio.httpClientAdapter as CapturingMockAdapter).captured;
      expect(captured.queryParameters['limit'], 50);
      expect(captured.queryParameters['offset'], 10);
    });

    test('getMessages 空 list 返 []', () async {
      // server nil 切片时返 [] (handler 显式 msgs = [] 兜底)
      final api = _api(<Map<String, dynamic>>[]);
      final result = await api.getMessages('c1');
      expect(result, isEmpty);
      expect(result, isA<List<ChatMessage>>());
    });
  });
}
