import 'package:flutter_test/flutter_test.dart';
import 'package:app/models/agent.dart';
import 'package:app/models/conversation.dart';

void main() {
  group('Conversation.fromJson', () {
    test('解析 IM 风格响应（含 agent + last_message_content）', () {
      final raw = {
        'id': 'c1',
        'agent': {
          'id': 'a1', 'name': 'Bot', 'avatar_url': null,
          'owner_id': 'u1', 'status': 'online', 'created_at': '2026-06-13T00:00:00Z',
        },
        'last_message_content': {'msg_type': 'text', 'data': {'text': 'hi'}},
        'last_message_at': '2026-06-13T14:32:00Z',
        'created_at': '2026-06-13T10:00:00Z',
      };
      final c = Conversation.fromJson(raw);
      expect(c.id, 'c1');
      expect(c.agent.name, 'Bot');
      expect(c.agent.status, AgentStatus.online);
      expect(c.lastMessagePreview, 'hi');
      expect(c.lastMessageAt.year, 2026);
    });

    test('lastMessagePreview 兼容 null last_message_content（返回空串）', () {
      final c = Conversation.fromJson({
        'id': 'c1',
        'agent': {'id':'a','name':'X','avatar_url':null,'owner_id':'u','status':'offline','created_at':'2026-06-13T00:00:00Z'},
        'last_message_content': null,
        'last_message_at': '2026-06-13T14:32:00Z',
        'created_at': '2026-06-13T10:00:00Z',
      });
      expect(c.lastMessagePreview, '');
    });

    test('lastMessagePreview 处理 image 类型', () {
      final c = Conversation.fromJson({
        'id': 'c1',
        'agent': {'id':'a','name':'X','avatar_url':null,'owner_id':'u','status':'online','created_at':'2026-06-13T00:00:00Z'},
        'last_message_content': {'msg_type': 'image', 'data': {'file_id': 'f1'}},
        'last_message_at': '2026-06-13T14:32:00Z',
        'created_at': '2026-06-13T10:00:00Z',
      });
      expect(c.lastMessagePreview, '[图片]');
    });

    test('lastMessagePreview 处理 file 类型', () {
      final c = Conversation.fromJson({
        'id': 'c1',
        'agent': {'id':'a','name':'X','avatar_url':null,'owner_id':'u','status':'online','created_at':'2026-06-13T00:00:00Z'},
        'last_message_content': {'msg_type': 'file', 'data': {'file_id': 'f1'}},
        'last_message_at': '2026-06-13T14:32:00Z',
        'created_at': '2026-06-13T10:00:00Z',
      });
      expect(c.lastMessagePreview, '[文件]');
    });

    test('lastMessagePreview 在字段缺失时返回空串', () {
      final c = Conversation.fromJson({
        'id': 'c1',
        'agent': {
          'id': 'a', 'name': 'X', 'avatar_url': null,
          'owner_id': 'u', 'status': 'offline',
          'created_at': '2026-06-13T00:00:00Z',
        },
        // 没有 last_message_content 键
        'last_message_at': '2026-06-13T14:32:00Z',
        'created_at': '2026-06-13T10:00:00Z',
      });
      expect(c.lastMessagePreview, '');
      expect(c.lastMessageContent, isNull);
    });

    test('lastMessageContent 类型异常时抛 FormatException', () {
      expect(
        () => Conversation.fromJson({
          'id': 'c1',
          'agent': {
            'id': 'a', 'name': 'X', 'avatar_url': null,
            'owner_id': 'u', 'status': 'offline',
            'created_at': '2026-06-13T00:00:00Z',
          },
          'last_message_content': 12345,  // 非 null/Map
          'last_message_at': '2026-06-13T14:32:00Z',
          'created_at': '2026-06-13T10:00:00Z',
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
