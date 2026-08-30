import 'package:flutter_test/flutter_test.dart';
import 'package:wanling_core/models/message.dart';
import 'package:wanling_core/models/quote.dart';

void main() {
  group('Quote', () {
    test('JSON round-trip preserves all 6 fields', () {
      const q = Quote(
        messageId: 'm1',
        senderType: 'user',
        senderId: 'u1',
        senderName: '洛羽',
        msgType: 'text',
        preview: '原文预览',
      );
      final json = q.toJson();
      final q2 = Quote.fromJson(json);

      expect(q2.messageId, 'm1');
      expect(q2.senderType, 'user');
      expect(q2.senderId, 'u1');
      expect(q2.senderName, '洛羽');
      expect(q2.msgType, 'text');
      expect(q2.preview, '原文预览');
    });

    test('fromJson handles missing fields gracefully (defaults to empty)', () {
      final q = Quote.fromJson({});
      expect(q.messageId, '');
      expect(q.senderName, '');
    });
  });

  group('ChatMessage quote parsing', () {
    test('parses message with quote in content.data.quote', () {
      final json = {
        'id': 'm1',
        'conversation_id': 'c1',
        'sender_type': 'user',
        'sender_id': 'u1',
        'content': {
          'msg_type': 'text',
          'data': {
            'text': '回复正文',
            'quote': {
              'message_id': 'm_quoted',
              'sender_type': 'agent',
              'sender_id': 'a1',
              'sender_name': '小灵',
              'msg_type': 'text',
              'preview': '被引用原文',
            },
          },
        },
        'created_at': '2026-07-07T00:00:00Z',
      };
      final msg = ChatMessage.fromJson(json);

      expect(msg.quote, isNotNull);
      expect(msg.quote!.messageId, 'm_quoted');
      expect(msg.quote!.senderType, 'agent');
      expect(msg.quote!.senderName, '小灵');
      expect(msg.quote!.msgType, 'text');
      expect(msg.quote!.preview, '被引用原文');
    });

    test('parses message without quote (content.data.quote absent)', () {
      final json = {
        'id': 'm2',
        'conversation_id': 'c1',
        'sender_type': 'user',
        'sender_id': 'u1',
        'content': {'msg_type': 'text', 'data': {'text': '你好'}},
        'created_at': '2026-07-07T00:00:00Z',
      };
      final msg = ChatMessage.fromJson(json);

      expect(msg.quote, isNull);
    });

    test('parses message with quote=null in JSON', () {
      final json = {
        'id': 'm3',
        'conversation_id': 'c1',
        'sender_type': 'user',
        'sender_id': 'u1',
        'content': {
          'msg_type': 'text',
          'data': {'text': '你好', 'quote': null},
        },
        'created_at': '2026-07-07T00:00:00Z',
      };
      final msg = ChatMessage.fromJson(json);

      expect(msg.quote, isNull);
    });
  });

  group('ChatMessage.fromJson', () {
    test('解析 sender_name + sender_avatar_url', () {
      final json = {
        'id': 'm1',
        'conversation_id': 'c1',
        'sender_type': 'user',
        'sender_id': 'u1',
        'sender_role': 'owner',
        'sender_name': '小明',
        'sender_avatar_url': '/api/files/abc',
        'content': {
          'msg_type': 'text',
          'data': {'text': 'hi'},
        },
        'created_at': '2026-07-06T10:00:00Z',
      };
      final m = ChatMessage.fromJson(json);
      expect(m.senderName, '小明');
      expect(m.senderAvatarUrl, '/api/files/abc');
    });

    test('字段缺失时默认 null,不崩溃', () {
      final json = {
        'id': 'm1',
        'conversation_id': 'c1',
        'sender_type': 'user',
        'sender_id': 'u1',
        'content': {
          'msg_type': 'text',
          'data': {'text': 'hi'},
        },
        'created_at': '2026-07-06T10:00:00Z',
      };
      final m = ChatMessage.fromJson(json);
      expect(m.senderName, isNull);
      expect(m.senderAvatarUrl, isNull);
    });

    test('copyWith 保留 senderName + senderAvatarUrl', () {
      final m = ChatMessage(
        id: 'm1',
        conversationId: 'c1',
        senderType: 'user',
        senderId: 'u1',
        content: {'msg_type': 'text', 'data': {'text': 'hi'}},
        createdAt: DateTime.parse('2026-07-06T10:00:00Z'),
        senderName: '小明',
        senderAvatarUrl: '/api/files/abc',
      );
      final m2 = m.copyWith(status: MessageStatus.failed);
      expect(m2.senderName, '小明');
      expect(m2.senderAvatarUrl, '/api/files/abc');
      expect(m2.status, MessageStatus.failed);
    });
  });
}
