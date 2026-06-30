import 'package:app/providers/chat_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ChatState.shouldShowUnreadBadge', () {
    test('unreadCount > 5 → true', () {
      final s = ChatState(unreadCount: 6);
      expect(s.shouldShowUnreadBadge, isTrue);
    });

    test('unreadCount == 5 → false（边界不含）', () {
      final s = ChatState(unreadCount: 5);
      expect(s.shouldShowUnreadBadge, isFalse);
    });

    test('unreadCount == 0 → false', () {
      final s = ChatState(unreadCount: 0);
      expect(s.shouldShowUnreadBadge, isFalse);
    });
  });

  group('ChatState.shouldShowNewMessageBadge', () {
    test('newMessageCount > 0 → true（与历史未读允许共存）', () {
      final s = ChatState(newMessageCount: 3, unreadCount: 5);
      expect(s.shouldShowNewMessageBadge, isTrue);
    });

    test('newMessageCount == 0 → false', () {
      final s = ChatState(newMessageCount: 0, unreadCount: 0);
      expect(s.shouldShowNewMessageBadge, isFalse);
    });
  });

  group('ChatState.copyWith', () {
    test('clearFirstUnread: true 强制把 firstUnreadMessageId 置 null', () {
      final s = ChatState(firstUnreadMessageId: 'msg-1');
      final next = s.copyWith(clearFirstUnread: true);
      expect(next.firstUnreadMessageId, isNull);
    });

    test('clearFirstUnread: false（默认）保留 firstUnreadMessageId', () {
      final s = ChatState(firstUnreadMessageId: 'msg-1');
      final next = s.copyWith(messages: []);
      expect(next.firstUnreadMessageId, 'msg-1');
    });
  });
}
