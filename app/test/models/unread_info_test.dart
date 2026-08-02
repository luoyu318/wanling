import 'package:app/models/unread_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UnreadInfo.fromJson', () {
    test('有未读：正常解析 unread_count + id + createdAt', () {
      final json = {
        'unread_count': 47,
        'first_unread_message_id': 'msg-abc',
        'first_unread_created_at': '2026-06-29T12:34:56.789Z',
      };
      final info = UnreadInfo.fromJson(json);
      expect(info.unreadCount, 47);
      expect(info.firstUnreadMessageId, 'msg-abc');
      expect(info.firstUnreadCreatedAt, isNotNull);
      expect(info.firstUnreadCreatedAt!.toUtc().toIso8601String(),
          '2026-06-29T12:34:56.789Z');
    });

    test('无未读：id 空字符串 + createdAt 为 null 规范化', () {
      final json = {
        'unread_count': 0,
        'first_unread_message_id': '',
        'first_unread_created_at': null,
      };
      final info = UnreadInfo.fromJson(json);
      expect(info.unreadCount, 0);
      expect(info.firstUnreadMessageId, isNull);
      expect(info.firstUnreadCreatedAt, isNull);
    });

    test('字段缺失：默认 unreadCount=0 + null id/createdAt', () {
      final info = UnreadInfo.fromJson({});
      expect(info.unreadCount, 0);
      expect(info.firstUnreadMessageId, isNull);
      expect(info.firstUnreadCreatedAt, isNull);
    });

    test('createdAt 空字符串规范化为 null', () {
      final json = {
        'unread_count': 1,
        'first_unread_message_id': 'msg-x',
        'first_unread_created_at': '',
      };
      final info = UnreadInfo.fromJson(json);
      expect(info.firstUnreadCreatedAt, isNull);
    });
  });
}
